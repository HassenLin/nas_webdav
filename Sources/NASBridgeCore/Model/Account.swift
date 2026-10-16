import Foundation

/// 一個 NAS 帳號：伺服器＋使用者名稱（＋密碼，存鑰匙圈，見 `KeychainStore`）。
/// 多個掛載（`MountProfile`）可共用同一帳號，例如同一台 NAS 的 `/home` 與 `/photo`。
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    /// 顯示名稱；空字串時以主機名稱顯示（`displayName`）。
    public var name = ""
    /// 例如 `https://nas.local:5006`（Synology WebDAV HTTPS 預設埠 5006）。
    public var serverURL = "https://"
    public var username = ""
    /// 釘選的伺服器憑證 SHA-256（hex，小寫無冒號）。
    /// 設定後只接受此憑證（適用 Synology 自簽憑證）；空字串＝走系統信任鏈。
    public var pinnedCertSHA256 = ""

    public init() {}

    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (url?.host() ?? serverURL) : n
    }

    /// 解析後的伺服器 URL（不含路徑尾端的 `/`）。
    public var url: URL? {
        guard var comps = URLComponents(string: serverURL.trimmingCharacters(in: .whitespaces)),
              comps.host?.isEmpty == false else { return nil }
        while comps.path.hasSuffix("/") { comps.path.removeLast() }
        return comps.url
    }

    /// 回傳設定錯誤訊息；nil 表示可用。
    /// 只允許 HTTPS：帳密以 Basic/Digest 傳送，明文 HTTP 會外洩。
    public func validationError() -> String? {
        guard let url else { return "Server URL is invalid." }
        if url.scheme?.lowercased() != "https" { return "Only https:// is allowed." }
        if username.isEmpty { return "Username is required." }
        if !pinnedCertSHA256.isEmpty, Self.normalizeFingerprint(pinnedCertSHA256).count != 64 {
            return "Pinned SHA-256 must be 64 hex characters."
        }
        return nil
    }

    /// 接受 `AB:CD:...` 或含空白的寫法，正規化為小寫連續 hex。
    public static func normalizeFingerprint(_ s: String) -> String {
        s.lowercased().filter { $0.isHexDigit }
    }
}
