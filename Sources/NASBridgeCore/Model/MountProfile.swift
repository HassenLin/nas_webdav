import Foundation

/// 一個掛載：「某帳號的某個遠端資料夾 → 本機掛載點」。
/// 不含任何帳密（在 `Account` 與鑰匙圈），可安全序列化到磁碟。
public struct MountProfile: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var accountID: UUID
    public var name = "Synology"
    /// 伺服器上的根路徑，例如 `/home` 或 `/photo`；`/` 代表整個 WebDAV 根。
    public var remotePath = "/"
    /// 本機掛載點；留空時使用 `~/Volumes/<name>`。
    public var mountPoint = ""
    public var readOnly = false
    public var autoMount = false

    public init(accountID: UUID) {
        self.accountID = accountID
    }

    /// 解析後的實際掛載點。
    public var resolvedMountPoint: String {
        mountPoint.isEmpty ? Self.defaultMountPoint(name: name, id: id) : (mountPoint as NSString).expandingTildeInPath
    }

    /// 預設掛載點 `~/Volumes/<name>`（不用 /Volumes：一般使用者無權在那裡建立資料夾）。
    public static func defaultMountPoint(name: String, id: UUID) -> String {
        let safe = name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Volumes/\(safe.isEmpty ? id.uuidString : safe)").path
    }

    /// WebDAV 基底 URL＝帳號的伺服器 URL＋remotePath（結尾不含 `/`）。
    public func baseURL(on account: Account) -> URL? {
        guard let server = account.url, var comps = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            return nil
        }
        let root = remotePath.split(separator: "/").joined(separator: "/")
        if !root.isEmpty { comps.path += "/" + root }
        return comps.url
    }

    public func validationError() -> String? {
        name.trimmingCharacters(in: .whitespaces).isEmpty ? "Name is required." : nil
    }
}
