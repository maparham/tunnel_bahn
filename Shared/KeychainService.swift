import Foundation
import Security
import LocalAuthentication

enum KeychainServiceError: LocalizedError {
    case invalidData
    case operationFailed(status: OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Invalid keychain data."
        case let .operationFailed(status):
            return "Keychain operation failed with status: \(status)."
        }
    }
}

final class KeychainService {
    static let shared = KeychainService()

    private init() {}

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: account,
            // Required for the packet tunnel extension to read items saved by the app.
            kSecAttrAccessGroup as String: AppConstants.keychainAccessGroup,
        ]
    }

    @discardableResult
    func save(_ value: String, account: String) throws -> String {
        let data = Data(value.utf8)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data
        // Ensure the item is readable by a background extension without UI.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainServiceError.operationFailed(status: status)
        }
        return account
    }

    func read(account: String) throws -> String {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Never show UI prompts (packet tunnel can't interact with the user).
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw KeychainServiceError.operationFailed(status: status)
        }
        guard let data = result as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainServiceError.invalidData
        }
        return string
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainServiceError.operationFailed(status: status)
        }
    }
}
