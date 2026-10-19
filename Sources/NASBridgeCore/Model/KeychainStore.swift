import Foundation
import Security

/// 帳號密碼存於登入鑰匙圈的「網際網路密碼」（kSecClassInternetPassword），以 伺服器＋埠＋協定＋使用者名稱 為鍵：
/// 在「鑰匙圈存取」中會以該伺服器顯示，也能沿用使用者先前（例如 Finder 連接伺服器時）已存的同一組密碼。
/// pCloud 存的是登入取得的 auth token（不存密碼），以 `pcloud.com`＋email 為鍵（不含地區）。
///
/// 只有主 app 會存取鑰匙圈；worker 子行程的祕密由主 app 經 stdin 傳入，避免第二次授權提示。
/// 存取權限綁在 app 的簽章上：`make-app.sh` 以固定的 Apple Development 憑證簽章，重新 build 不必再允許。
public enum KeychainStore {
    /// 鑰匙圈項目的查詢鍵；設定不完整（無主機或帳號）時為 nil。
    static func query(_ account: Account) -> [String: Any]? {
        guard !account.username.isEmpty else { return nil }
        if account.protocol == .pcloud {
            return [kSecClass as String: kSecClassInternetPassword,
                    kSecAttrServer as String: "pcloud.com",
                    kSecAttrProtocol as String: kSecAttrProtocolHTTPS,
                    kSecAttrAccount as String: account.username]
        }
        guard let url = account.url, let host = url.host() else { return nil }
        let proto: CFString = switch account.protocol {
        case .webdav, .pcloud: kSecAttrProtocolHTTPS
        case .ftp: account.ftpSecurity == .none ? kSecAttrProtocolFTP : kSecAttrProtocolFTPS
        case .sftp: kSecAttrProtocolSSH
        }
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: host,
            kSecAttrProtocol as String: proto,
            kSecAttrAccount as String: account.username,
        ]
        // 只在網址寫了埠時才帶：與舊版（WebDAV）存的項目一致
        if let port = url.port { q[kSecAttrPort as String] = port }
        return q
    }

    /// 兩個帳號是否對應同一個鑰匙圈項目（改網址／帳號時判斷要不要搬移、刪除時判斷是否還有人共用）。
    public static func sameItem(_ a: Account, _ b: Account) -> Bool {
        guard let qa = query(a), let qb = query(b) else { return false }
        return NSDictionary(dictionary: qa).isEqual(to: qb)
    }

    // MARK: 帳號祕密

    public static func secret(for account: Account) -> String? { query(account).flatMap(read) }

    @discardableResult
    public static func setSecret(_ secret: String, for account: Account) -> Bool {
        guard let q = query(account) else { return false }
        let host = account.protocol == .pcloud ? "pCloud" : account.url?.host() ?? ""
        return write(Data(secret.utf8), query: q, label: "\(host) (NAS Bridge)")
    }

    public static func delete(for account: Account) {
        if let q = query(account) { SecItemDelete(q as CFDictionary) }
    }

    // MARK: 共用

    private static func read(_ query: [String: Any]) -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func write(_ data: Data, query: [String: Any], label: String) -> Bool {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}
