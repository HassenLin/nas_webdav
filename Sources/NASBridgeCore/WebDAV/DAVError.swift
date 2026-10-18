import Foundation

/// 遠端層（各協定的 `RemoteStore`）與檔案系統層唯一的錯誤型別：
/// 同時攜帶 POSIX errno（給 FUSE）與人類可讀訊息（給 UI / log）。名稱沿用最初只有 WebDAV 時的命名。
public struct DAVError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    /// 伺服器憑證不受信任時看到的指紋；UI 可提供「信任此憑證」。
    /// WebDAV 為葉憑證 SHA-256（hex）；FTPS 為 lftp 回報的 `AA:BB:…` 指紋。
    public var untrustedFingerprint: String?

    public init(code: Int32, message: String, untrustedFingerprint: String? = nil) {
        self.code = code
        self.message = message
        self.untrustedFingerprint = untrustedFingerprint
    }

    public var description: String { message }

    public static func http(_ status: Int, _ what: String) -> DAVError {
        let errno: Int32 = switch status {
        case 401, 403: EACCES
        case 404, 409: ENOENT        // 409：父目錄不存在
        case 405, 412: EEXIST        // MKCOL 已存在 / Overwrite: F 衝突
        case 423: EBUSY              // Locked
        case 413, 507: ENOSPC
        case 501: ENOTSUP
        default: EIO
        }
        return DAVError(code: errno, message: "\(what): HTTP \(status)")
    }

    public static func transport(_ error: Error, _ what: String) -> DAVError {
        let ns = error as NSError
        let errno: Int32 = switch ns.code {
        case NSURLErrorTimedOut: ETIMEDOUT
        case NSURLErrorCancelled, NSURLErrorUserCancelledAuthentication: EACCES
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost: EHOSTUNREACH
        default: EIO
        }
        return DAVError(code: errno, message: "\(what): \(ns.localizedDescription)")
    }

    public static func posix(_ code: Int32, _ message: String = "") -> DAVError {
        DAVError(code: code, message: message.isEmpty ? String(cString: strerror(code)) : message)
    }
}
