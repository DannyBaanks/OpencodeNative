import XCTest
@testable import IysCodeMovilCore

final class NativeCapabilityBrokerTests: XCTestCase {
    private let broker = NativeCapabilityBroker()

    func testDiscoveryDoesNotImplyAppleAuthorization() {
        let descriptor = capability(authorization: .notRequested)
        let result = broker.evaluate(.init(capabilityID: descriptor.id), catalog: [descriptor], modelPermitted: true, userApproved: true)
        XCTAssertEqual(result, .denied("Apple authorization is not granted"))
    }

    func testModelPermissionDoesNotBypassExternalEffectApproval() {
        let descriptor = capability(effect: .externalSideEffect)
        let result = broker.evaluate(.init(capabilityID: descriptor.id), catalog: [descriptor], modelPermitted: true, userApproved: false)
        XCTAssertEqual(result, .denied("Explicit user approval is required"))
    }

    func testUnknownCapabilityCannotBeFabricatedByModel() {
        let result = broker.evaluate(.init(capabilityID: "camera.capture"), catalog: [], modelPermitted: true, userApproved: true)
        XCTAssertEqual(result, .denied("Capability is not registered"))
    }

    func testModelPermissionIsRequiredSeparatelyFromUserApproval() {
        let descriptor = capability()
        let result = broker.evaluate(.init(capabilityID: descriptor.id), catalog: [descriptor], modelPermitted: false, userApproved: true)
        XCTAssertEqual(result, .denied("Local policy does not permit this action"))
    }

    func testUserPresenceRequirementAppliesEvenToPresentationEffect() {
        let descriptor = NativeCapabilityDescriptor(id: "system.share", title: "Share", detail: "Share sheet",
            availability: .available, authorization: .notApplicable, userPresenceRequired: true, effectClass: .presentUI)
        let result = broker.evaluate(.init(capabilityID: descriptor.id), catalog: [descriptor], modelPermitted: true, userApproved: false)
        XCTAssertEqual(result, .denied("Explicit user approval is required"))
    }

    func testProposalCannotAddInputOutsideCapabilitySchema() {
        let descriptor = NativeCapabilityDescriptor(id: "notification.schedule", title: "Schedule", detail: "Local notification",
            availability: .available, authorization: .authorized, effectClass: .deviceAction,
            inputSchema: ["title": "string"], requiredInput: ["title"])
        let result = broker.evaluate(.init(capabilityID: descriptor.id, input: ["title": "Done", "url": "evil://open"]),
            catalog: [descriptor], modelPermitted: true, userApproved: true)
        XCTAssertEqual(result, .denied("Proposal does not match the registered input schema"))
    }

    func testReceiptOmitsSecretsAndSensitivePayloadMetadata() {
        let receipt = NativeCapabilityReceipt(
            requestID: "r1", descriptor: capability(), approved: true, succeeded: true,
            safeMetadata: ["file_name": "notes.txt", "api_key": "must-not-leak", "message_body": "private", "count": "2", "status": "token=hidden"]
        )
        XCTAssertEqual(receipt.safeMetadata, ["file_name": "notes.txt", "count": "2"])
    }

    func testCatalogDoesNotCallUnconfiguredShortcutsAuthorized() {
        let shortcuts = NativeCapabilityCatalog.current(hasExternalFolderGrant: false)
            .first { $0.id == "shortcuts.configured" }
        XCTAssertEqual(shortcuts?.availability, .needsSetup)
        XCTAssertEqual(shortcuts?.authorization, .notApplicable)
        XCTAssertEqual(shortcuts?.displayState, "Needs setup")
    }

    func testConfiguredShortcutNameIsEncodedAsAppleSupportedURL() throws {
        let shortcut = ConfiguredShortcut(name: "Review & Build")
        let url = try XCTUnwrap(ShortcutURLBuilder.runURL(shortcut: shortcut, text: "check the patch"))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "shortcuts")
        XCTAssertEqual(components.host, "run-shortcut")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "name" })?.value, "Review & Build")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "text" })?.value, "check the patch")
    }

    func testEmptyShortcutNameCannotBeLaunched() {
        XCTAssertNil(ShortcutURLBuilder.runURL(shortcut: ConfiguredShortcut(name: "  ")))
    }

    func testRegistryProjectsOnlyTaskRelevantRegisteredCapabilities() async {
        let files = capability()
        let share = NativeCapabilityDescriptor(id: "system.share", title: "Share", detail: "Share sheet",
            availability: .available, authorization: .notApplicable, effectClass: .presentUI,
            implementationSurface: .systemUI)
        let registry = NativeCapabilityRegistry(modules: [FixtureCapabilityModule(descriptors: [files, share])])
        let result = await registry.snapshot(relevantCapabilityIDs: ["system.share"])
        XCTAssertEqual(result.map(\.id), ["system.share"])
        XCTAssertEqual(result.first?.implementationSurface, .systemUI)
    }

    private func capability(authorization: NativeAuthorizationState = .authorized,
                            effect: NativeEffectClass = .read) -> NativeCapabilityDescriptor {
        .init(id: "test.capability", title: "Test", detail: "Test", availability: .available,
              authorization: authorization, effectClass: effect)
    }
}

private struct FixtureCapabilityModule: NativeCapabilityModule {
    let descriptors: [NativeCapabilityDescriptor]
    var moduleID: String { "tests.fixture" }
    func discoverCapabilities() async -> [NativeCapabilityDescriptor] { descriptors }
}
