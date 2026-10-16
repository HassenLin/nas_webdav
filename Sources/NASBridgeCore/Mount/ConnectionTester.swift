import Foundation

/// 「測試連線」的結果，供設定畫面顯示。
public struct ConnectionReport: Sendable, Equatable {
    public var ok: Bool
    public var message: String
    /// 憑證不受信任時，伺服器憑證的 SHA-256；UI 可提供「信任此憑證」把它釘選起來。
    public var untrustedFingerprint: String?
}

/// 對一組設定做一次不掛載的連線檢查：認證、遠端路徑、配額、部分寫入能力。
public enum ConnectionTester {
    public static func test(_ profile: MountProfile, password: String) async -> ConnectionReport {
        if let msg = profile.validationError() { return ConnectionReport(ok: false, message: msg) }
        // WebDAVClient 是阻塞式 API，離開 main actor 執行
        return await Task.detached { run(profile, password) }.value
    }

    private static func run(_ profile: MountProfile, _ password: String) -> ConnectionReport {
        guard let client = WebDAVClient(profile: profile, password: password, timeout: 15) else {
            return ConnectionReport(ok: false, message: "Server URL is invalid.")
        }
        do {
            guard let root = try client.propfind("/", depth: 0).first, root.isDirectory else {
                return ConnectionReport(ok: false, message: "Remote path is not a folder.")
            }
            var lines = ["Connected."]
            if let q = try? client.quota(), let free = q.available {
                lines.append("Free: " + ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            }
            if !profile.readOnly {
                lines.append("Write mode: " + describe(client.probePartialWrite(in: "/")))
            }
            return ConnectionReport(ok: true, message: lines.joined(separator: "\n"))
        } catch let e as DAVError {
            if client.trustRejected {
                return ConnectionReport(ok: false, message: "The server certificate is not trusted.",
                                        untrustedFingerprint: client.lastSeenFingerprint)
            }
            return ConnectionReport(ok: false, message: e.code == EACCES ? "Authentication failed. (\(e.message))" : e.message)
        } catch {
            return ConnectionReport(ok: false, message: error.localizedDescription)
        }
    }

    public static func describe(_ m: PartialWriteMethod) -> String {
        switch m {
        case .contentRange: "partial writes (Content-Range)"
        case .sabrePatch: "partial writes (SabreDAV PATCH)"
        case .none: "whole-file upload on close"
        }
    }
}
