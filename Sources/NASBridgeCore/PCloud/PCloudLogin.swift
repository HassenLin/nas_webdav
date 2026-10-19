import CryptoKit
import Foundation

/// pCloud 帳號密碼登入——**不需要**事先註冊 pCloud App（OAuth 需要 client ID／secret 且要等 pCloud 審核，自用工具不值得）。
/// 做法對齊 SmartphoneFileManager 的 `PCloudLogin`（該專案另保留 OAuth；這裡只有帳號密碼一種）。
///
/// 流程（https://docs.pcloud.com/methods/intro/authentication.html）：
/// 1. `getdigest` 取一次性 digest。
/// 2. `passworddigest = sha1(密碼 + sha1(小寫 email) + digest)`——密碼本身不送出，digest 用過即失效，攔到也無法重放。
/// 3. `login?getauth=1` 換回長效 auth token。帳號啟用兩步驟驗證時回 2297＋暫時 token，
///    須再以 `tfa_login`＋6 位數驗證碼換 auth（`verify`）。
///    （官方文件未記載 2FA；作法依 pcloudcom/console-client PR #94 與 seborama/pcloud SDK，SmartphoneFileManager 實機驗證：
///    **要用 `login` 而非 `userinfo`，並帶 `os`／`deviceid`**——用 `userinfo` 時開了 2FA 的帳號不會回 2297；
///    `trustdevice=1` 讓之後此裝置不必再輸入驗證碼。）
/// 4. 地區：帳號只存在一區。在錯的區登入回 **2321**（This user is on another location），有時也回 2000 →
///    先試帳號設定的區，失敗再試另一區，成功的那區就是帳號地區。
///
/// 只存 auth token（鑰匙圈），不存密碼；刪除帳號時呼叫 `logout` 讓 token 在伺服器端失效。
/// 只在主 app（帳號編輯器）使用；worker 拿到的是 token。
public enum PCloudLogin {
    /// 登入結果：token 與帳號實際所在地區
    public struct Session: Sendable, Equatable {
        public let token: String
        public let region: PCloudRegion
    }

    /// 帳號啟用兩步驟驗證：UI 向使用者要驗證碼後呼叫 `verify`
    public struct TwoFactorRequired: Error, Sendable, Equatable {
        public let token: String
        public let region: PCloudRegion
    }

    private struct Response: Decodable {
        let result: Int
        let error: String?
        let digest: String?
        let auth: String?
        let token: String?
        let email: String?
    }

    /// 2297：需要兩步驟驗證
    static let twoFactorCode = 2297
    /// 2321：「This user is on another location」——帳號在另一個資料中心，換另一區重試
    static let wrongLocationCode = 2321
    private struct WrongLocation: Error {}

    public static func signIn(email: String, password: String, preferredRegion: PCloudRegion) async throws -> Session {
        let email = email.trimmingCharacters(in: .whitespaces)
        guard !email.isEmpty, !password.isEmpty else { throw DAVError.posix(EACCES, "Enter the pCloud email and password.") }
        // 兩區都失敗時優先回報「帳密錯誤」（來自帳號所在的那區），而不是另一區的「不在此區」
        var authError: DAVError?
        for region in [preferredRegion] + PCloudRegion.allCases.filter({ $0 != preferredRegion }) {
            do {
                return try await signIn(email: email, password: password, region: region)
            } catch is WrongLocation {
                continue   // 帳號不在這區（2321）→ 換另一區
            } catch let e as DAVError where e.code == EACCES {
                authError = e   // 帳密錯誤（有時在錯的區也回這個）→ 也試另一區；其他錯誤（連不上等）直接回報
            }
        }
        throw authError ?? DAVError.posix(EACCES, "pCloud: account not found in either region.")
    }

    private static func signIn(email: String, password: String, region: PCloudRegion) async throws -> Session {
        let digest = try await call("getdigest", [:], region: region)
        guard let nonce = digest.digest else { throw DAVError.posix(EIO, "pCloud getdigest: unexpected response") }
        let response = try await call("login", deviceParameters.merging([
            "username": email, "digest": nonce,
            "passworddigest": passwordDigest(email: email, password: password, digest: nonce),
        ]) { $1 }, region: region, allowTwoFactor: true)
        if response.result == twoFactorCode {
            guard let token = response.token else { throw DAVError.posix(EIO, "pCloud login: two-factor token missing") }
            throw TwoFactorRequired(token: token, region: region)
        }
        guard let auth = response.auth else { throw DAVError.posix(EIO, "pCloud login: no auth token") }
        return Session(token: auth, region: region)
    }

    /// 兩步驟驗證：以登入時拿到的暫時 token＋驗證碼（驗證 App 或簡訊）換 auth token
    public static func verify(_ pending: TwoFactorRequired, code: String) async throws -> Session {
        let response = try await call("tfa_login", deviceParameters.merging([
            "token": pending.token, "code": code.filter(\.isNumber), "trustdevice": "1",
        ]) { $1 }, region: pending.region)
        guard let auth = response.auth else { throw DAVError.posix(EIO, "pCloud tfa_login: no auth token") }
        return Session(token: auth, region: pending.region)
    }

    /// 檢查已存的 token 是否仍有效（`userinfo`）。回傳帳號 email；token 失效時拋出 EACCES。
    /// 「鑰匙圈裡有 token」不等於已登入：token 會因登出、過期、改密碼而失效。
    public static func validate(token: String, region: PCloudRegion) async throws -> String? {
        try await call("userinfo", ["auth": token], region: region).email
    }

    /// 登出：讓 auth token 在伺服器端失效（盡力而為，失敗不影響刪除帳號）
    public static func signOut(token: String, region: PCloudRegion) async {
        _ = try? await call("logout", ["auth": token], region: region)
    }

    /// 登入與 2FA 共用：取得 auth、`os`＝6（macOS）、穩定的裝置 id（「信任此裝置」以它辨識）
    private static var deviceParameters: [String: String] {
        ["getauth": "1", "logout": "1", "os": "6", "device": "NAS Bridge", "deviceid": deviceID]
    }

    /// 以主機名稱雜湊出固定的裝置 id：同一台 Mac 每次登入都相同，不另存狀態。
    /// 用 `gethostname` 而非 `ProcessInfo.hostName`：後者可能做反向 DNS 查詢而卡住數秒。
    static var deviceID: String {
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return String(sha1("NAS Bridge/" + host).prefix(32))
    }

    static func passwordDigest(email: String, password: String, digest: String) -> String {
        sha1(password + sha1(email.lowercased()) + digest)
    }

    private static func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// POST form：帳號與密碼摘要放本文，不出現在 URL
    private static func call(_ method: String, _ parameters: [String: String], region: PCloudRegion,
                             allowTwoFactor: Bool = false) async throws -> Response {
        var comps = URLComponents()
        comps.queryItems = parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: URL(string: "https://\(region.apiHost)/\(method)")!, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // URLQueryItem 不編碼 `+`，伺服器會當成空白（email 常含 +）
        req.httpBody = Data((comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            throw DAVError.transport(error, "pCloud \(method)")
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw DAVError.posix(EIO, "pCloud \(method): unexpected response")
        }
        if response.result == 0 || (allowTwoFactor && response.result == twoFactorCode) { return response }
        if response.result == wrongLocationCode { throw WrongLocation() }
        throw PCloudStore.error(response.result, response.error ?? "", method: method)
    }
}
