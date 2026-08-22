import Foundation
import Security

/// Keychain helper para almacenar secretos de forma segura
public actor KeychainHelper {
    public static let shared = KeychainHelper()
    
    private let service = "com.opencode.native"
    private let accessGroup: String? = nil
    
    private init() {}
    
    /// Guarda un secreto en el Keychain
    public func save(key: String, value: String) throws {
        let data = value.data(using: .utf8)!
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Eliminar item existente si existe
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }
    
    /// Recupera un secreto del Keychain
    public func load(key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound {
                return nil
            }
            throw KeychainError.loadFailed(status)
        }
        
        return string
    }
    
    /// Elimina un secreto del Keychain
    public func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
    
    /// Guarda múltiples secretos (para apiKeys dictionary)
    public func saveAll(_ dict: [String: String]) throws {
        for (key, value) in dict {
            try save(key: key, value: value)
        }
    }
    
    /// Recupera múltiples secretos
    public func loadAll(keys: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in keys {
            if let value = try load(key: key) {
                result[key] = value
            }
        }
        return result
    }
    
    /// Elimina todos los secretos conocidos
    public func deleteAll(keys: [String]) throws {
        for key in keys {
            try delete(key: key)
        }
    }
}

public enum KeychainError: Error, LocalizedError, Sendable {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    
    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status): return "Keychain save failed: \(status)"
        case .loadFailed(let status): return "Keychain load failed: \(status)"
        case .deleteFailed(let status): return "Keychain delete failed: \(status)"
        }
    }
}