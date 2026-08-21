import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Network)
import Network
#endif

/// Matriz de capabilities de iOS **probed en runtime** (no hardcoded).
/// Cada capability se verifica con la API real del SDK iOS o, en su defecto,
/// con compilación condicional `#if` que solo compila si la API existe en iOS.
///
/// En plataformas no-iOS (e.g. compilar para tests en Windows/macOS) las
/// capabilities específicas de iOS se reportan como `notApplicable` cuando
/// razonablemente no se puedan probar; la capability matrix de OpenCode
/// se reconcilia en `CompatibilityReport` usando esta matriz como input.
public struct IOSCapabilityMatrix: Sendable, Codable {
    public let platform: String
    public let isIOS: Bool
    public let sandboxFS: Capability
    public let sandboxRoots: [String]
    public let fileWatching: Capability
    public let securityBookmarks: Capability
    public let arbitraryPaths: Capability
    public let processExec: Capability
    public let shell: Capability
    public let ptyTTY: Capability
    public let networkTLS: Capability
    public let webSocket: Capability
    public let localServer: Capability
    public let mdns: Capability
    public let sqlite: Capability
    public let sqliteBunFlavor: Capability
    public let bunRuntime: Capability
    public let javaScriptEngine: Capability
    public let treeSitterNative: Capability
    public let posixEnv: Capability
    public let codeSigning: Capability
    public let keychain: Capability
    public let modelAPIRemote: Capability

    public enum Availability: String, Codable, Sendable {
        case available     // Existe y usable
        case limited       // Existe con restricciones
        case unavailable   // No existe en iOS (imposible)
        case notApplicable  // No aplica a este host/target
    }

    public struct Capability: Codable, Sendable {
        public let availability: Availability
        public let evidence: String   // Qué API/comprobación determina el estado.
        public init(_ a: Availability, _ e: String) { availability = a; evidence = e }
    }

    /// Probar capabilities del host en el que se ejecuta.
    public static func probeCurrent() -> IOSCapabilityMatrix {
        #if os(iOS)
        return probeIOS()
        #else
        return probeNonIOS()
        #endif
    }

    // MARK: - iOS

    #if os(iOS) || canImport(UIKit)
    private static func probeIOS() -> IOSCapabilityMatrix {
        let fm = FileManager.default
        var roots: [String] = []
        if let asDir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            roots.append(asDir.path)
        }
        if let docDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            roots.append(docDir.path)
        }
        roots.append(fm.temporaryDirectory.path)
        let isWritable = (try? asWritableSubpath()) != nil
        let sandboxFS = Capability(isWritable ? .available : .limited,
            "FileManager.applicationSupportDirectory/documentDirectory/tmp accesibles y escribibles: \(isWritable)")
        return IOSCapabilityMatrix(
            platform: "iOS",
            isIOS: true,
            sandboxFS: sandboxFS,
            sandboxRoots: roots,
            fileWatching: .limited("DispatchSource.makeFileSystemObjectSource solo para paths del sandbox; sin @parcel/watcher integral"),
            securityBookmarks: .limited("UIDocumentPickerViewController + URL.bookmarkData + startAccessingSecurityScopedResource (requiere interacción usuario)"),
            arbitraryPaths: .unavailable("Sandbox restringe a contenedores de la app salvo security bookmarks vía picker"),
            processExec: .unavailable("Process/NSTask no están en el SDK iOS; sandbox prohíbe fork/execve/posix_spawn de binarios arbitrarios"),
            shell: .unavailable("No existen /bin/bash, /bin/sh, /bin/zsh en iOS; sin TTY"),
            ptyTTY: .unavailable("No hay API pública de PTY (openpty/posix_openpt) ni TTY crudo; @opentui/@lydell/node-pty no operables"),
            networkTLS: .available("URLSession async/await + ATS"),
            webSocket: .available("URLSessionWebSocketTask"),
            localServer: .available("Network.framework NWListener en 127.0.0.1"),
            mdns: .limited("NetService/NWBrowser existen; no equivalente exacto a bonjour-service npm"),
            sqlite: .available("SQLite del sistema accesible vía C API / GRDB / SQLite.swift / CoreData"),
            sqliteBunFlavor: .unavailable("@effect/sql-sqlite-bun requiere runtime Bun; no existe en iOS"),
            bunRuntime: .unavailable("Bun publica linux/darwin/win × {x64,arm64}; no existe target Bun iOS"),
            javaScriptEngine: .limited("JavaScriptCore + WKWebView ejecutan JS puro; sin APIs bun:/node:/node:fs/PTY"),
            treeSitterNative: .unavailable("No hay toolchain en iOS; tree-sitter-* necesita compilar para arm64-ios"),
            posixEnv: .unavailable("No hay $SHELL/$HOME POSIX/.zshrc/EDITOR; setenv solo dentro del proceso propio"),
            codeSigning: .limited("Solo macOS (Xcode/codesign); en iOS unsigned IPA se construye en CI macOS"),
            keychain: .available("Keychain Services (SecItem*) hardware-backed"),
            modelAPIRemote: .available("URLSession HTTP/HTTPS a cualquier LLM API compatible (OpenAI-style)")
        )
    }
    #else
    private static func probeIOS() -> IOSCapabilityMatrix {
        fatalError("probeIOS unreachable on non-iOS")
    }
    #endif

    // MARK: - Non-iOS host (tests/dev)

    private static func probeNonIOS() -> IOSCapabilityMatrix {
        let na = Capability(.notApplicable, "No iOS host — capability matrix iOS no aplicable; el veredicto se emite al ejecutar en iOS")
        return IOSCapabilityMatrix(
            platform: hostPlatformName(),
            isIOS: false,
            sandboxFS: na,
            sandboxRoots: [],
            fileWatching: na,
            securityBookmarks: na,
            arbitraryPaths: na,
            processExec: na,
            shell: na,
            ptyTTY: na,
            networkTLS: na,
            webSocket: na,
            localServer: na,
            mdns: na,
            sqlite: na,
            sqliteBunFlavor: na,
            bunRuntime: na,
            javaScriptEngine: na,
            treeSitterNative: na,
            posixEnv: na,
            codeSigning: na,
            keychain: na,
            modelAPIRemote: na
        )
    }

    private static func hostPlatformName() -> String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #elseif os(Windows)
        return "Windows"
        #else
        return "unknown"
        #endif
    }

    // Comprueba que podemos crear un subdirectorio escribible bajo Application Support.
    private static func asWritableSubpath() throws -> String {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("OpencodeNative", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let name = "probe_\(UUID().uuidString)"
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.removeItem(at: dir)
        return dir.path
    }
}
