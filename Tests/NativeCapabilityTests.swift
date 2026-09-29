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

    func testNativeSurfaceInventoryLabelsCandidatesWithoutEnablingThemAsTools() {
        let catalog = NativeCapabilityCatalog.current(hasExternalFolderGrant: false)
        let photos = catalog.first { $0.id == "photos.select" }
        XCTAssertEqual(photos?.availability, .needsSetup)
        XCTAssertEqual(photos?.implementationSurface, .systemUI)
        XCTAssertFalse(NativeCapabilityToolProjection.relevantCapabilityIDs(for: [
            ModelMessage(role: .user, content: "Pick a photo")
        ]).contains("photos.select"))

        let notes = catalog.first { $0.id == "notes.create" }
        XCTAssertEqual(notes?.availability, .needsSetup)
        XCTAssertEqual(notes?.implementationSurface, .appIntentOrShortcut)
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

    func testNativeToolsAreProjectedOnlyForRelevantUserRequests() {
        let unrelated = [ModelMessage(role: .user, content: "List my project files")]
        XCTAssertTrue(NativeCapabilityToolProjection.relevantCapabilityIDs(for: unrelated).isEmpty)

        let reminder = [ModelMessage(role: .user, content: "Recuérdame llamar mañana")]
        XCTAssertEqual(NativeCapabilityToolProjection.relevantCapabilityIDs(for: reminder), ["notifications.schedule"])

        let cancel = [ModelMessage(role: .user, content: "Cancela este recordatorio")]
        XCTAssertEqual(NativeCapabilityToolProjection.relevantCapabilityIDs(for: cancel), ["notifications.schedule", "notifications.cancel"])

        let shortcut = [ModelMessage(role: .user, content: "Run my configured Shortcut")]
        XCTAssertEqual(NativeCapabilityToolProjection.relevantCapabilityIDs(for: shortcut), ["shortcuts.run"])
    }

    func testConfiguredShortcutRegistryRoundTripsInIsolatedDefaults() throws {
        let suite = "NativeCapabilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let shortcut = ConfiguredShortcut(name: "My reminder")

        ShortcutRegistry.save(shortcut, to: defaults)
        XCTAssertEqual(ShortcutRegistry.loadConfiguredShortcut(from: defaults), shortcut)
        ShortcutRegistry.remove(from: defaults)
        XCTAssertNil(ShortcutRegistry.loadConfiguredShortcut(from: defaults))
    }

    func testSandboxProviderDirectoryContainsOnlyConfiguredOpenAICompatibleAdapters() {
        XCTAssertEqual(SandboxModelProvider.all.map(\.id), ["nvidia", "xai", "openai", "gemini", "openrouter"])
        XCTAssertEqual(SandboxModelProvider.sandboxOptions.first?.id, "gus-local")
        XCTAssertEqual(SandboxModelProvider.provider(id: "gus-local")?.baseURL, "")
        XCTAssertTrue(SandboxModelProvider.provider(id: "gus-local")?.keyPlaceholder.isEmpty == true)
        XCTAssertEqual(SandboxModelProvider.provider(id: "nvidia")?.baseURL, "https://integrate.api.nvidia.com/v1")
        XCTAssertEqual(SandboxModelProvider.provider(id: "gemini")?.baseURL,
                       "https://generativelanguage.googleapis.com/v1beta/openai")
        XCTAssertTrue(SandboxModelProvider.provider(id: "gemini")?.supportsGoogleOAuth == true)
        XCTAssertNil(SandboxModelProvider.provider(id: "anthropic"))
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
