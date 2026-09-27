import Foundation

/// MCP-facing description of a native iOS tool.
///
/// This is only a protocol projection. A capability must also have a registered
/// executor before it can appear in `tools/list`, and effects still require the
/// on-device approval flow at execution time.
public struct NativeMCPTool: Codable, Sendable, Equatable, Identifiable {
    public struct Annotations: Codable, Sendable, Equatable {
        public let readOnlyHint: Bool
        public let destructiveHint: Bool
        public let idempotentHint: Bool
        public let openWorldHint: Bool
    }

    public let name: String
    public let capabilityID: String
    public let title: String
    public let description: String
    public let inputSchema: [String: MCPJSONValue]
    public let annotations: Annotations

    public var id: String { name }

    fileprivate init(descriptor: NativeCapabilityDescriptor) {
        capabilityID = descriptor.id
        name = "ios_" + descriptor.id.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_")
        title = descriptor.title
        let approval = descriptor.userPresenceRequired || NativeCapabilityBroker.requiresExplicitApproval(descriptor.effectClass)
        description = approval
            ? "\(descriptor.detail) Requires an explicit approval on the iPhone before execution."
            : descriptor.detail
        let properties = descriptor.inputSchema.mapValues { type in
            MCPJSONValue.object(["type": .string(Self.jsonType(for: type))])
        }
        inputSchema = [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(descriptor.requiredInput.map(MCPJSONValue.string)),
            "additionalProperties": .bool(false)
        ]
        let isReadOnly = descriptor.effectClass == .read
        let externalEffect = descriptor.effectClass == .externalSideEffect
        annotations = .init(
            readOnlyHint: isReadOnly,
            destructiveHint: Self.mayDestroyData(descriptor.effectClass),
            idempotentHint: isReadOnly,
            openWorldHint: externalEffect
        )
    }

    private static func jsonType(for value: String) -> String {
        switch value.lowercased() {
        case "integer", "number", "boolean", "array", "object": value.lowercased()
        default: "string"
        }
    }

    private static func mayDestroyData(_ effect: NativeEffectClass) -> Bool {
        switch effect {
        case .write, .sensitiveWrite, .deviceAction, .externalSideEffect: true
        case .read, .presentUI, .sensitiveRead: false
        }
    }
}

/// Small JSON value type used for MCP's JSON Schema input contract.
public indirect enum MCPJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([MCPJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: MCPJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// Validates an MCP `tools/call` payload against the exact catalog that was
/// advertised to the caller. This creates a proposal only; it never executes
/// the capability or treats ChatGPT-side confirmation as iPhone approval.
public enum NativeMCPToolRouter {
    public enum ValidationError: Error, LocalizedError, Equatable {
        case unknownTool
        case capabilityNotExecutable
        case invalidArguments(String)

        public var errorDescription: String? {
            switch self {
            case .unknownTool: "Unknown iPhone capability tool."
            case .capabilityNotExecutable: "This capability is not currently available on the iPhone."
            case .invalidArguments(let reason): reason
            }
        }
    }

    public static func proposal(
        toolName: String,
        arguments: [String: MCPJSONValue],
        requestID: String,
        descriptors: [NativeCapabilityDescriptor],
        executableCapabilityIDs: Set<String>
    ) throws -> NativeCapabilityProposal {
        let advertised = NativeMCPToolCatalog.project(
            descriptors: descriptors,
            executableCapabilityIDs: executableCapabilityIDs
        )
        guard let tool = advertised.first(where: { $0.name == toolName }) else {
            throw ValidationError.unknownTool
        }
        guard executableCapabilityIDs.contains(tool.capabilityID),
              let descriptor = descriptors.first(where: { $0.id == tool.capabilityID }),
              descriptor.availability == .available,
              descriptor.authorization == .authorized || descriptor.authorization == .notApplicable else {
            throw ValidationError.capabilityNotExecutable
        }

        guard arguments.keys.allSatisfy({ descriptor.inputSchema[$0] != nil }) else {
            throw ValidationError.invalidArguments("Arguments contain a field that this tool does not accept.")
        }
        guard descriptor.requiredInput.allSatisfy({
            guard let value = arguments[$0] else { return false }
            if case .string(let string) = value { return !string.isEmpty }
            return true
        }) else {
            throw ValidationError.invalidArguments("A required argument is missing or empty.")
        }

        var scalarArguments: [String: String] = [:]
        for (key, value) in arguments {
            guard let expectedType = descriptor.inputSchema[key]?.lowercased(),
                  let scalar = scalarValue(value, expectedType: expectedType) else {
                throw ValidationError.invalidArguments("Argument \(key) does not match the tool's input schema.")
            }
            scalarArguments[key] = scalar
        }
        return NativeCapabilityProposal(requestID: requestID, capabilityID: tool.capabilityID, input: scalarArguments)
    }

    private static func scalarValue(_ value: MCPJSONValue, expectedType: String) -> String? {
        switch (expectedType, value) {
        case ("string", .string(let value)):
            value
        case ("number", .number(let value)) where value.isFinite:
            String(value)
        case ("integer", .number(let value)) where value.isFinite && value.rounded() == value
            && value >= Double(Int.min) && value < Double(Int.max):
            String(Int(value))
        case ("boolean", .bool(let value)):
            String(value)
        default:
            nil
        }
    }
}

public enum NativeMCPToolCatalog {
    /// Return only tools for which both iOS reports usable authorization and an
    /// execution adapter has explicitly been registered. Discovery alone never
    /// grants MCP callers access to a capability.
    public static func project(
        descriptors: [NativeCapabilityDescriptor],
        executableCapabilityIDs: Set<String>
    ) -> [NativeMCPTool] {
        descriptors
            .filter { descriptor in
                executableCapabilityIDs.contains(descriptor.id)
                    && descriptor.availability == .available
                    && (descriptor.authorization == .authorized || descriptor.authorization == .notApplicable)
            }
            .sorted { $0.id < $1.id }
            .map(NativeMCPTool.init(descriptor:))
    }
}
