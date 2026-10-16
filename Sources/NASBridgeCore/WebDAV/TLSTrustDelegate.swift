import CryptoKit
import Foundation
import Security

/// URLSession 的認證／TLS 委派。
///
/// - 伺服器信任：有釘選指紋 → 只比對葉憑證 SHA-256（Synology 自簽憑證用）；
///   否則走系統預設信任鏈。無論成敗都記下看到的指紋，讓 UI 可提示「信任此憑證」。
/// - HTTP 認證：一般請求已預先帶 Basic header；若伺服器改要 Digest，這裡補上帳密。
///   同一 protection space 失敗過一次就取消，避免帳密錯誤時無限重試。
final class TLSTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let pinnedSHA256: String
    private let credential: URLCredential
    private let lock = NSLock()
    private var _lastSeenFingerprint: String?

    /// 最近一次 TLS 交握看到的葉憑證指紋（hex 小寫）。
    var lastSeenFingerprint: String? { lock.withLock { _lastSeenFingerprint } }
    private var _trustRejected = false
    /// 最近一次交握是否因憑證不受信任（或指紋不符）而被拒。
    var trustRejected: Bool { lock.withLock { _trustRejected } }

    init(pinnedSHA256: String, username: String, password: String) {
        self.pinnedSHA256 = MountProfile.normalizeFingerprint(pinnedSHA256)
        self.credential = URLCredential(user: username, password: password, persistence: .forSession)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            guard let trust = space.serverTrust else { return completionHandler(.cancelAuthenticationChallenge, nil) }
            let seen = Self.leafFingerprint(trust)
            lock.withLock { _lastSeenFingerprint = seen }
            // 自行評估（而非 performDefaultHandling），才知道失敗原因是「憑證不受信任」
            let trusted = pinnedSHA256.isEmpty ? SecTrustEvaluateWithError(trust, nil) : seen == pinnedSHA256
            lock.withLock { _trustRejected = !trusted }
            if trusted {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault:
            if challenge.previousFailureCount > 0 {
                completionHandler(.cancelAuthenticationChallenge, nil)
            } else {
                completionHandler(.useCredential, credential)
            }
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    static func leafFingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}
