import Foundation

/// 一組「NAS WebDAV → 本機掛載點」的連線設定。
///
/// 密碼不在此結構內（存 Keychain，見 `KeychainStore`），因此本結構可安全序列化到磁碟，
/// 也可原樣透過 stdin 交給 worker 子行程（再附上密碼，見 `WorkerConfig`）。
public struct MountProfile: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()

    public init() {}
    public var name = "Synology"
    /// 例如 `https://nas.local:5006`（Synology WebDAV HTTPS 預設埠 5006）。
    public var serverURL = "https://"
    /// 伺服器上的根路徑，例如 `/home` 或 `/photo`；`/` 代表整個 WebDAV 根。
    public var remotePath = "/"
    public var username = ""
    /// 本機掛載點；留空時使用 `~/Volumes/<name>`。
    public var mountPoint = ""
    public var readOnly = false
    public var autoMount = false
    /// 釘選的伺服器憑證 SHA-256（hex，小寫無冒號）。
    /// 設定後只接受此憑證（適用 Synology 自簽憑證）；空字串＝走系統信任鏈。
    public var pinnedCertSHA256 = ""

    /// 解析後的實際掛載點。
    public var resolvedMountPoint: String {
        if !mountPoint.isEmpty { return (mountPoint as NSString).expandingTildeInPath }
        let safe = name.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes/\(safe.isEmpty ? id.uuidString : safe)").path
    }

    /// WebDAV 基底 URL（server + remotePath，結尾不含 `/`）。
    public var baseURL: URL? {
        guard var comps = URLComponents(string: serverURL.trimmingCharacters(in: .whitespaces)),
              comps.host?.isEmpty == false else { return nil }
        let root = "/" + remotePath.split(separator: "/").joined(separator: "/")
        comps.path = (comps.path + root).replacingOccurrences(of: "//", with: "/")
        if comps.path.hasSuffix("/") { comps.path.removeLast() }
        return comps.url
    }

    /// 回傳設定錯誤訊息；nil 表示可用。
    /// 只允許 HTTPS：帳密以 Basic/Digest 傳送，明文 HTTP 會外洩。
    public func validationError() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name is required." }
        guard let url = baseURL else { return "Server URL is invalid." }
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
