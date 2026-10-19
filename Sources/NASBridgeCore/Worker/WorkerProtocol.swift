import Foundation

/// 主 app ⇄ worker 子行程的通訊契約。
///
/// - 啟動：`<執行檔> --fuse-worker`
/// - 主 app → worker：stdin 寫入一份 `WorkerConfig` JSON 後關閉。
///   密碼／token 走 stdin 而非參數或環境變數：`ps` 看不到，且 worker 不必再碰鑰匙圈。
/// - worker → 主 app：stdout 逐行事件（`WorkerEvent`），其餘診斷訊息走 stderr / os.Logger。
/// - 結束：worker 行程結束＝已卸載。結束碼 0 為正常卸載。
public enum WorkerProtocol {
    public static let flag = "--fuse-worker"
}

public struct WorkerConfig: Codable, Sendable {
    public var account: Account
    public var mount: MountProfile
    /// 密碼（WebDAV／FTP／SFTP）或 auth token（pCloud）
    public var credential: String

    public init(account: Account, mount: MountProfile, credential: String) {
        self.account = account
        self.mount = mount
        self.credential = credential
    }
}

/// worker 回報的事件（一行一則）。
public enum WorkerEvent: Equatable, Sendable {
    /// 已連上伺服器，正在掛載；附帶探測到的寫入方式
    case connected(writeMethod: String)
    /// 掛載生效
    case ready
    /// 致命錯誤，worker 隨即結束
    case error(String)

    public var line: String {
        switch self {
        case .connected(let m): "CONNECTED \(m)"
        case .ready: "READY"
        case .error(let msg): "ERROR \(msg.replacingOccurrences(of: "\n", with: " "))"
        }
    }

    public init?(line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "CONNECTED": self = .connected(writeMethod: parts.count > 1 ? parts[1] : "")
        case "READY": self = .ready
        case "ERROR": self = .error(parts.count > 1 ? parts[1] : "unknown error")
        default: return nil
        }
    }
}
