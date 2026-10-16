import Foundation
import Security

/// 帳號密碼存於登入鑰匙圈的「網際網路密碼」（kSecClassInternetPassword）。
///
/// 以 伺服器＋埠＋https＋使用者名稱 為鍵：在「鑰匙圈存取」中會以該伺服器顯示，
/// 也能沿用使用者先前（例如 Finder 連接伺服器時）已存的同一組密碼。
/// 只有主 app 會存取鑰匙圈；worker 子行程的密碼由主 app 經 stdin 傳入，避免第二次授權提示。
public enum KeychainStore {
    private static func query(_ account: Account) -> [String: Any]? {
        guard let url = account.url, let host = url.host(), !account.username.isEmpty else { return nil }
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
            kSecAttrAccount as String: account.username,
        ]
        if let port = url.port { q[kSecAttrPort as String] = port }
        return q
    }

    public static func password(for account: Account) -> String? {
        guard var q = query(account) else { return nil }
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func setPassword(_ password: String, for account: Account) -> Bool {
        guard let q = query(account) else { return false }
        let data = Data(password.utf8)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = q
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "\(account.url?.host() ?? "") (NAS Bridge)"
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func delete(for account: Account) {
        if let q = query(account) { SecItemDelete(q as CFDictionary) }
    }
}
