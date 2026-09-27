import Foundation

public enum NativeCapabilityAvailability: String, Codable, Sendable, CaseIterable {
    case available, needsSetup, unsupported
}

public enum NativeAuthorizationState: String, Codable, Sendable, CaseIterable {
    case authorized, denied, restricted, notRequested, notApplicable
}

public enum NativeEffectClass: String, Codable, Sendable, CaseIterable {
    case read = "READ"
    case write = "WRITE"
    case presentUI = "PRESENT_UI"
    case sensitiveRead = "SENSITIVE_READ"
    case sensitiveWrite = "SENSITIVE_WRITE"
    case deviceAction = "DEVICE_ACTION"
    case externalSideEffect = "EXTERNAL_SIDE_EFFECT"
}

public struct NativeCapabilityDescriptor: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let availability: NativeCapabilityAvailability
    public let authorization: NativeAuthorizationState
    public let entitlementRequired: Bool
    public let userPresenceRequired: Bool
    public let effectClass: NativeEffectClass
    public let inputSchema: [String: String]
    public let requiredInput: [String]
    public let outputSchema: [String: String]

    public init(id: String, title: String, detail: String, availability: NativeCapabilityAvailability,
                authorization: NativeAuthorizationState, entitlementRequired: Bool = false,
                userPresenceRequired: Bool = false, effectClass: NativeEffectClass,
                inputSchema: [String: String] = [:], requiredInput: [String] = [], outputSchema: [String: String] = [:]) {
        self.id = id
        self.title = title
        self.detail = detail
        self.availability = availability
        self.authorization = authorization
        self.entitlementRequired = entitlementRequired
        self.userPresenceRequired = userPresenceRequired
        self.effectClass = effectClass
        self.inputSchema = inputSchema
        self.requiredInput = requiredInput
        self.outputSchema = outputSchema
    }

    public var displayState: String {
        switch availability {
        case .unsupported: return "Unsupported"
        case .needsSetup: return "Needs setup"
        case .available:
            switch authorization {
            case .authorized, .notApplicable: return "Authorized"
            case .denied: return "Denied"
            case .restricted: return "Restricted"
            case .notRequested: return "Available · not requested"
            }
        }
    }
}

public struct NativeCapabilityProposal: Codable, Sendable {
    public let requestID: String
    public let capabilityID: String
    public let input: [String: String]

    public init(requestID: String = UUID().uuidString, capabilityID: String, input: [String: String] = [:]) {
        self.requestID = requestID
        self.capabilityID = capabilityID
        self.input = input
    }
}

public struct NativeCapabilityReceipt: Codable, Sendable {
    public let requestID: String
    public let capabilityID: String
    public let authorization: NativeAuthorizationState
    public let effectClass: NativeEffectClass
    public let approved: Bool
    public let succeeded: Bool
    public let safeMetadata: [String: String]
    public let timestamp: Date

    public init(requestID: String, descriptor: NativeCapabilityDescriptor, approved: Bool,
                succeeded: Bool, safeMetadata: [String: String] = [:], timestamp: Date = Date()) {
        self.requestID = requestID
        self.capabilityID = descriptor.id
        self.authorization = descriptor.authorization
        self.effectClass = descriptor.effectClass
        self.approved = approved
        self.succeeded = succeeded
        self.safeMetadata = Self.redacted(safeMetadata)
        self.timestamp = timestamp
    }

    private static let allowedMetadataKeys: Set<String> = ["file_name", "count", "status", "category", "duration_ms", "item_count"]

    private static func redacted(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { result, item in
            let (key, value) = item
            let normalized = value.lowercased()
            let sensitiveMarkers = ["bearer ", "token=", "secret=", "api_key", "oauth", "sk-"]
            guard allowedMetadataKeys.contains(key.lowercased()), value.count <= 128,
                  !sensitiveMarkers.contains(where: { normalized.contains($0) }) else { return }
            result[key] = value
        }
    }
}

public enum NativeCapabilityDecision: Sendable, Equatable {
    case allowed
    case denied(String)
}

/// Central policy gate. Discovery, OS permission and local/model approval are separate inputs.
public struct NativeCapabilityBroker: Sendable {
    public init() {}

    public func evaluate(_ proposal: NativeCapabilityProposal,
                         catalog: [NativeCapabilityDescriptor],
                         modelPermitted: Bool,
                         userApproved: Bool) -> NativeCapabilityDecision {
        guard let descriptor = catalog.first(where: { $0.id == proposal.capabilityID }) else {
            return .denied("Capability is not registered")
        }
        guard proposal.input.keys.allSatisfy({ descriptor.inputSchema[$0] != nil }),
              descriptor.requiredInput.allSatisfy({ !(proposal.input[$0] ?? "").isEmpty }) else {
            return .denied("Proposal does not match the registered input schema")
        }
        guard descriptor.availability == .available else {
            return .denied("Capability is unavailable or needs setup")
        }
        guard descriptor.authorization == .authorized || descriptor.authorization == .notApplicable else {
            return .denied("Apple authorization is not granted")
        }
        guard modelPermitted else { return .denied("Local policy does not permit this action") }
        if (Self.requiresExplicitApproval(descriptor.effectClass) || descriptor.userPresenceRequired), !userApproved {
            return .denied("Explicit user approval is required")
        }
        return .allowed
    }

    public static func requiresExplicitApproval(_ effect: NativeEffectClass) -> Bool {
        switch effect {
        case .write, .sensitiveRead, .sensitiveWrite, .deviceAction, .externalSideEffect: return true
        case .read, .presentUI: return false
        }
    }
}

public enum NativeCapabilityCatalog {
    public static func current(hasExternalFolderGrant: Bool,
                               hasConfiguredShortcut: Bool = false,
                               notificationAuthorization: NativeAuthorizationState = .notRequested) -> [NativeCapabilityDescriptor] {
        [
            .init(id: "files.sandbox", title: "Files sandbox", detail: "Private iSyCode workspace", availability: .available, authorization: .authorized, effectClass: .read),
            .init(id: "files.external-folder", title: "Selected folder", detail: hasExternalFolderGrant ? "User-selected folder grant" : "Choose a folder in Files to enable", availability: hasExternalFolderGrant ? .available : .needsSetup, authorization: hasExternalFolderGrant ? .authorized : .notRequested, effectClass: .write),
            .init(id: "keychain.app-secrets", title: "Keychain", detail: "App-owned credentials; values hidden from the model", availability: .available, authorization: .authorized, effectClass: .sensitiveWrite),
            .init(id: "shortcuts.configured", title: "Apple Shortcuts", detail: "Only shortcuts explicitly configured by you", availability: hasConfiguredShortcut ? .available : .needsSetup, authorization: .notApplicable, userPresenceRequired: true, effectClass: .externalSideEffect, inputSchema: ["shortcut_id": "string"], requiredInput: ["shortcut_id"]),
            .init(id: "notifications.local", title: "Notifications", detail: "Local task and approval notifications", availability: .available, authorization: notificationAuthorization, userPresenceRequired: true, effectClass: .deviceAction, inputSchema: ["title": "string", "body": "string", "delay_seconds": "string"], requiredInput: ["title", "body", "delay_seconds"])
        ]
    }
}
