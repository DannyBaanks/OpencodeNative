import Foundation

public enum NativeNotificationError: Error, LocalizedError {
    case authorizationRequired
    case unsupported
    public var errorDescription: String? {
        switch self {
        case .authorizationRequired: return "Notification authorization and explicit approval are required."
        case .unsupported: return "Local notifications are unavailable on this platform."
        }
    }
}

#if canImport(UserNotifications)
import UserNotifications

public actor LocalNotificationCapability {
    public static let shared = LocalNotificationCapability()

    public func authorizationState() async -> NativeAuthorizationState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notRequested
        @unknown default: return .restricted
        }
    }

    /// Called only from a user-initiated Settings action, never at launch.
    public func requestAuthorizationFromUserAction() async throws -> NativeAuthorizationState {
        let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        return granted ? .authorized : .denied
    }

    @discardableResult
    public func schedule(id: String, title: String, body: String, after seconds: TimeInterval,
                        userApproved: Bool) async throws -> NativeCapabilityReceipt {
        let authorization = await authorizationState()
        let descriptor = NativeCapabilityCatalog.current(hasExternalFolderGrant: false,
            notificationAuthorization: authorization).first { $0.id == "notifications.local" }!
        let proposal = NativeCapabilityProposal(capabilityID: descriptor.id,
            input: ["title": title, "body": body, "delay_seconds": String(seconds)])
        guard NativeCapabilityBroker().evaluate(proposal, catalog: [descriptor], modelPermitted: true,
                                                userApproved: userApproved) == .allowed else {
            throw NativeNotificationError.authorizationRequired
        }
        let content = UNMutableNotificationContent()
        content.title = String(title.prefix(80))
        content.body = String(body.prefix(240))
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        return NativeCapabilityReceipt(requestID: proposal.requestID, descriptor: descriptor, approved: userApproved,
            succeeded: true, safeMetadata: ["status": "scheduled", "category": "local-notification"])
    }

    @discardableResult
    public func cancel(id: String, userApproved: Bool) async throws -> NativeCapabilityReceipt {
        let authorization = await authorizationState()
        let descriptor = NativeCapabilityCatalog.current(hasExternalFolderGrant: false,
            notificationAuthorization: authorization).first { $0.id == "notifications.local" }!
        let proposal = NativeCapabilityProposal(capabilityID: descriptor.id,
            input: ["title": "cancel", "body": "cancel", "delay_seconds": "0"])
        guard NativeCapabilityBroker().evaluate(proposal, catalog: [descriptor], modelPermitted: true,
                                                userApproved: userApproved) == .allowed else {
            throw NativeNotificationError.authorizationRequired
        }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        return NativeCapabilityReceipt(requestID: proposal.requestID, descriptor: descriptor, approved: userApproved,
            succeeded: true, safeMetadata: ["status": "cancelled", "category": "local-notification"])
    }
}

#else
public actor LocalNotificationCapability {
    public static let shared = LocalNotificationCapability()
    public func authorizationState() async -> NativeAuthorizationState { .notApplicable }
    public func requestAuthorizationFromUserAction() async throws -> NativeAuthorizationState { .notApplicable }
    public func schedule(id: String, title: String, body: String, after seconds: TimeInterval,
                        userApproved: Bool) async throws -> NativeCapabilityReceipt {
        throw NativeNotificationError.unsupported
    }
    public func cancel(id: String, userApproved: Bool) async throws -> NativeCapabilityReceipt {
        throw NativeNotificationError.unsupported
    }
}
#endif
