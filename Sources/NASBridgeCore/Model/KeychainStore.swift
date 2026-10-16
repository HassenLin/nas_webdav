import Foundation
import Security

/// 以 profile id 為帳號鍵，把密碼存進登入鑰匙圈（Generic Password）。
/// 只有主 app 會存取 Keychain；worker 子行程的密碼由主 app 經 stdin 傳入，
/// 避免子行程觸發第二次鑰匙圈授權提示。
public enum KeychainStore {
    private static let service = "NASBridge.WebDAV"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    public static func password(for id: UUID) -> String? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setPassword(_ password: String, for id: UUID) -> Bool {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(id)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    public static func delete(for id: UUID) {
        SecItemDelete(query(id) as CFDictionary)
    }
}
