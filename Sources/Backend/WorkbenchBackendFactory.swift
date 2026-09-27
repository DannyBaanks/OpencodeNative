import Foundation

/// Fábrica para crear backends según el tipo de pairing/runtime.
/// Centraliza la lógica de instanciación y permite añadir nuevos backends
/// sin tocar el resto de la app.
public enum WorkbenchBackendFactory {
    
    /// Errores de la fábrica
    public enum FactoryError: Error, LocalizedError, Sendable {
        case unsupportedBackendType(String)
        case invalidPairingLink(String)
        case missingConfiguration(String)
        
        public var errorDescription: String? {
            switch self {
            case .unsupportedBackendType(let type): return "Unsupported backend type: \(type)"
            case .invalidPairingLink(let reason): return "Invalid pairing link: \(reason)"
            case .missingConfiguration(let detail): return "Missing configuration: \(detail)"
            }
        }
    }
    
    /// Crea un backend a partir de una pairing link parseada.
    /// - Parameter pairing: Pairing genérico con tipo de backend incluido
    /// - Returns: Backend configurado y listo para connectRemote
    @MainActor
    public static func makeBackend(from pairing: RemotePairing) throws -> WorkbenchBackend {
        switch pairing.type {
        case .opencode:
            let opencodePairing = OpenCodePairing(
                scheme: pairing.scheme,
                host: pairing.host,
                port: pairing.port,
                username: pairing.username,
                password: pairing.password,
                directory: pairing.directory
            )
            return OpenCodeRemoteBackend(pairing: opencodePairing)
            
        case .openisy:
            let opencodePairing = OpenCodePairing(
                scheme: pairing.scheme,
                host: pairing.host,
                port: pairing.port,
                username: pairing.username,
                password: pairing.password,
                directory: pairing.directory
            )
            return OpenCodeRemoteBackend(pairing: opencodePairing)
            
        case .crush:
            return CrushRemoteBackend()

        case .codex:
            return CodexRemoteBackend()

        case .claudeCode:
            return ClaudeCodeRemoteBackend()

        case .gemini:
            return GeminiRemoteBackend()
        }
    }
    
    /// Crea un backend nativo (sandbox local)
    @MainActor
    public static func makeNativeBackend() -> WorkbenchBackend {
        NativeSwiftBackend()
    }
    
    /// Crea un backend demo/fixture para testing
    @MainActor
    public static func makeDemoBackend() -> WorkbenchBackend {
        NativeSwiftBackend() // usa sandbox local
    }
    
    /// Parsea una URL de pairing y devuelve el tipo de backend y la pairing genérica
    public static func parsePairingURL(_ url: String) throws -> (RemoteBackendType, RemotePairing) {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              components.scheme != nil else {
            throw FactoryError.invalidPairingLink("Invalid URL format")
        }
        
        let scheme = components.scheme ?? ""
        let host = components.host ?? ""
        
        // Determinar tipo por scheme
        let backendType: RemoteBackendType
        switch scheme {
        case "iyscodemovil":
            // iyscodemovil://pair?... -> OpenCode
            backendType = .opencode
        case "opencodenative":
            // legacy
            backendType = .opencode
        case "openisy":
            backendType = .openisy
        case "crush":
            backendType = .crush
        case "codex":
            backendType = .codex
        case "claude-code":
            backendType = .claudeCode
        case "gemini":
            backendType = .gemini
        default:
            // Default a opencode para compatibilidad
            backendType = .opencode
        }
        
        // Parsear query items
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        })
        
        let remoteScheme = items["scheme"] ?? "http"
        guard let host = items["host"], !host.isEmpty,
              let portText = items["port"], let port = Int(portText),
              let password = items["password"], !password.isEmpty else {
            throw FactoryError.invalidPairingLink("Missing required fields: host, port, password")
        }
        
        let pairing = RemotePairing(
            type: backendType,
            scheme: remoteScheme,
            host: host,
            port: port,
            username: items["username"] ?? "user",
            password: password,
            directory: items["directory"] ?? ""
        )
        
        return (backendType, pairing)
    }
    
    /// Tipos de backend soportados (backends que existen y se conectan)
    public static var supportedBackendTypes: [RemoteBackendType] {
        [.opencode, .openisy]
    }

    /// Tipos de backend con stub compilado pero sin transporte implementado
    public static var stubbedBackendTypes: [RemoteBackendType] {
        [.crush, .codex, .claudeCode, .gemini]
    }

    /// Tipos de backend planificados (no implementados)
    public static var plannedBackendTypes: [RemoteBackendType] {
        stubbedBackendTypes
    }

    /// Verifica si un tipo de backend está implementado (conecta de verdad)
    public static func isImplemented(_ type: RemoteBackendType) -> Bool {
        supportedBackendTypes.contains(type)
    }
}