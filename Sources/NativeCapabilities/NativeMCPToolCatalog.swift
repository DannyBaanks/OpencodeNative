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
    public let title: String
    public let description: String
    public let inputSchema: [String: MCPJSONValue]
    public let annotations: Annotations

    public var id: String { name }

    fileprivate init(descriptor: NativeCapabilityDescriptor) {
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
            destructiveHint: !isReadOnly,
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
}

/// Small JSON value type used for MCP's JSON Schema input contract.
public indirect enum MCPJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case array([MCPJSONValue])
    case object([String: MCPJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([MCPJSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: MCPJSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
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
