import Foundation

/// 「測試連線」的結果，供設定畫面顯示。
public struct ConnectionReport: Sendable, Equatable {
    public var ok: Bool
    public var message: String
    /// 憑證不受信任時，伺服器憑證的 SHA-256；UI 可提供「信任此憑證」把它釘選起來。
    public var untrustedFingerprint: String?
}

/// 對帳號（＋遠端路徑）做一次不掛載的連線檢查：認證、遠端路徑、配額、（選擇性）部分寫入能力。
public enum ConnectionTester {
    /// - Parameter probeWrites: 是否探測部分寫入（會在遠端建立並刪除一個隱藏檔）。
    public static func test(_ account: Account, remotePath: String = "/", password: String,
                            probeWrites: Bool = false) async -> ConnectionReport {
        if let msg = account.validationError() { return ConnectionReport(ok: false, message: msg) }
        // WebDAVClient 是阻塞式 API，離開 main actor 執行
        return await Task.detached { run(account, remotePath, password, probeWrites) }.value
    }

    private static func run(_ account: Account, _ remotePath: String, _ password: String, _ probeWrites: Bool) -> ConnectionReport {
        guard let client = WebDAVClient(account: account, remotePath: remotePath, password: password, timeout: 15) else {
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
            if probeWrites {
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
