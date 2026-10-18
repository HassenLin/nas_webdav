import Foundation

/// 「測試連線」的結果，供設定畫面顯示。
public struct ConnectionReport: Sendable, Equatable {
    public var ok: Bool
    public var message: String
    /// 憑證不受信任時看到的指紋（WebDAV：SHA-256；FTPS：lftp 回報的指紋）；UI 可提供「信任此憑證」。
    public var untrustedFingerprint: String?
}

/// 對帳號（＋遠端路徑）做一次不掛載的連線檢查：認證、遠端路徑、配額、（選擇性）寫入方式。
/// 與 worker 走同一條 `RemoteStoreFactory.connect`，測試通過＝掛載時的連線步驟也會通過。
public enum ConnectionTester {
    /// - Parameter credential: 密碼（WebDAV／FTP／SFTP）或 access token（pCloud）。
    /// - Parameter probeWrites: 是否探測部分寫入（WebDAV 會在遠端建立並刪除一個隱藏檔）。
    public static func test(_ account: Account, remotePath: String = "/", credential: String,
                            probeWrites: Bool = false) async -> ConnectionReport {
        if let msg = account.validationError() { return ConnectionReport(ok: false, message: msg) }
        // RemoteStore 是阻塞式 API，離開 main actor 執行
        return await Task.detached { run(account, remotePath, credential, probeWrites) }.value
    }

    private static func run(_ account: Account, _ remotePath: String, _ credential: String, _ probeWrites: Bool) -> ConnectionReport {
        do {
            let store = try RemoteStoreFactory.connect(account, remotePath: remotePath, credential: credential,
                                                       probeWrites: probeWrites, timeout: 15)
            var lines = ["Connected."]
            if let q = try? store.quota(), let free = q.available {
                lines.append("Free: " + ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            }
            if !store.supportsRangeRead { lines.append("Read mode: whole file is downloaded on open") }
            else if account.protocol.needsLftp { lines.append("Read mode: offset reads (REST + RETR / SFTP offset)") }
            if probeWrites { lines.append("Write mode: " + describe(store.partialWrite)) }
            return ConnectionReport(ok: true, message: lines.joined(separator: "\n"))
        } catch let e as DAVError {
            return ConnectionReport(ok: false, message: e.message, untrustedFingerprint: e.untrustedFingerprint)
        } catch {
            return ConnectionReport(ok: false, message: error.localizedDescription)
        }
    }

    public static func describe(_ m: PartialWriteMethod) -> String {
        switch m {
        case .contentRange: "partial writes (Content-Range)"
        case .sabrePatch: "partial writes (SabreDAV PATCH)"
        case .append: "append writes (REST + STOR / SFTP offset); rewrites use whole-file upload"
        case .none: "whole-file upload on close"
        }
    }
}
