import Foundation
import Network

/// pCloud OAuth2 登入（authorization code flow＋本機 loopback 回呼；移植自 SmartphoneFileManager，只在主 app 執行）。
///
/// 流程：
/// 1. 在 `127.0.0.1:<redirectPort>` 開一個只收一次請求的 HTTP listener。
/// 2. 開瀏覽器到 `https://my.pcloud.com/oauth2/authorize`（美國與歐洲帳號共用此頁），帶亂數 `state`。
/// 3. 使用者同意後，pCloud 轉址回 `http://127.0.0.1:<port>/?code=…&state=…&locationid=…&hostname=…`；
///    `state` 不符即拒絕（防 CSRF：別的網頁不能把它的 code 塞給我們）。
/// 4. **以回呼帶回的 `hostname` 換 token**（`/oauth2_token`）：歐洲帳號必須打 `eapi.pcloud.com`，
///    打美國區會換不到；並以 `locationid`／`hostname` 決定帳號地區，覆寫使用者事先選的地區。
///
/// 前提：使用者已在 pCloud 註冊 app（https://docs.pcloud.com/my_apps/），並把 `redirectURI` 加進允許的 redirect URI。
public enum PCloudOAuth {
    public static let redirectPort: UInt16 = 53682
    public static var redirectURI: String { "http://127.0.0.1:\(redirectPort)/" }
    public static let authorizeURL = URL(string: "https://my.pcloud.com/oauth2/authorize")!
    public static let appsPage = URL(string: "https://docs.pcloud.com/my_apps/")!

    public struct Result: Sendable, Equatable {
        public let token: String
        public let region: PCloudRegion
    }

    /// 回呼參數
    struct Callback: Equatable {
        let code: String
        let region: PCloudRegion?
        let hostname: String?
    }

    // MARK: 純函式（可單元測試）

    static func authorizationURL(clientID: String, state: String) -> URL {
        var comps = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
        ]
        return comps.url!
    }

    /// 解析回呼的 HTTP 請求行（`GET /?code=…&state=… HTTP/1.1`）並驗證 state
    static func parseCallback(requestLine: String, expectedState: String) throws -> Callback {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: "http://127.0.0.1" + parts[1]) else {
            throw DAVError.posix(EIO, "pCloud sign-in: malformed callback")
        }
        let items = Dictionary((comps.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        if let error = items["error"] { throw DAVError.posix(EACCES, error) }
        guard items["state"] == expectedState else {
            throw DAVError.posix(EACCES, "The sign-in response did not match this request.")
        }
        guard let code = items["code"], !code.isEmpty else { throw DAVError.posix(EACCES, "no code") }
        let hostname = items["hostname"]
        let region = items["locationid"].flatMap(PCloudRegion.init(locationID:)) ?? hostname.flatMap(PCloudRegion.init(apiHost:))
        return Callback(code: code, region: region, hostname: hostname)
    }

    /// 換 token 的 host：回呼帶回的 hostname 只接受兩個官方 API host（防止被導向任意主機送出 client secret）
    static func tokenHost(for callback: Callback, fallback: PCloudRegion) -> PCloudRegion {
        callback.hostname.flatMap(PCloudRegion.init(apiHost:)) ?? callback.region ?? fallback
    }

    // MARK: 流程

    /// 執行完整登入。`openBrowser` 由 App 層提供（`NSWorkspace.open`），core 不依賴 AppKit。
    /// `preferredRegion` 只在回呼沒帶地區時使用。
    public static func signIn(clientID: String, clientSecret: String, preferredRegion: PCloudRegion,
                              openBrowser: @Sendable (URL) -> Void) async throws -> Result {
        guard !clientID.isEmpty, !clientSecret.isEmpty else { throw DAVError.posix(EINVAL, "Enter the pCloud client ID and secret first.") }
        let state = UUID().uuidString
        let receiver = try LoopbackReceiver(port: redirectPort)
        defer { receiver.stop() }
        try await receiver.start()
        openBrowser(authorizationURL(clientID: clientID, state: state))
        let line = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await receiver.firstRequestLine() }
            // 使用者放棄（關掉瀏覽器）時不會有回呼：5 分鐘後放棄
            group.addTask { try await Task.sleep(for: .seconds(300)); throw DAVError.posix(EACCES, "timed out") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        let callback = try parseCallback(requestLine: line, expectedState: state)
        let region = tokenHost(for: callback, fallback: preferredRegion)
        let token = try await exchange(code: callback.code, clientID: clientID, clientSecret: clientSecret, region: region)
        return Result(token: token, region: callback.region ?? region)
    }

    private struct TokenResponse: Decodable {
        let result: Int
        let access_token: String?
        let error: String?
    }

    static func exchange(code: String, clientID: String, clientSecret: String, region: PCloudRegion) async throws -> String {
        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = region.apiHost
        comps.path = "/oauth2_token"
        comps.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                            URLQueryItem(name: "client_secret", value: clientSecret),
                            URLQueryItem(name: "code", value: code)]
        // POST：client secret 放在本文而非 URL
        var req = URLRequest(url: comps.url!.deletingQuery())
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data((comps.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: req)
        } catch {
            throw DAVError.transport(error, "pCloud oauth2_token")
        }
        guard let response = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw DAVError.posix(EIO, "pCloud oauth2_token: unexpected response")
        }
        guard response.result == 0, let token = response.access_token else {
            throw PCloudStore.error(response.result, response.error ?? "", method: "oauth2_token")
        }
        return token
    }
}

private extension URL {
    func deletingQuery() -> URL {
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        comps.query = nil
        return comps.url!
    }
}

/// 只收一次請求的 loopback HTTP listener（Network.framework）。
/// 收到第一個請求行後回一個「可以關閉此頁」的頁面並結束；只綁 127.0.0.1，區網內其他機器連不到。
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "idv.hassen.nasbridge.oauth")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String, Error>?
    private var received: Result<String, Error>?

    init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters)
    }

    /// 開始監聽；埠被佔用時丟錯
    func start() async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            let once = OnceFlag()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.take() { ready.resume() }
                case let .failed(error): if once.take() { ready.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }

    func firstRequestLine() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    if let received { continuation.resume(with: received) } else { self.continuation = continuation }
                }
            }
        } onCancel: {
            deliver(.failure(CancellationError()))
        }
    }

    private func deliver(_ result: Result<String, Error>) {
        let waiting: CheckedContinuation<String, Error>? = lock.withLock {
            guard received == nil else { return nil }
            received = result
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume(with: result)
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            let text = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            let line = text.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
            // 瀏覽器常順便要 /favicon.ico：只把帶查詢參數的請求當回呼
            guard line.hasPrefix("GET /"), line.contains("?") else {
                Self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            let body = "<html><body style=\"font-family:-apple-system;padding:40px\"><h2>NAS Bridge</h2>"
                + "<p>pCloud sign-in finished. You can close this tab.</p><p>pCloud 登入完成，可以關閉此分頁。</p></body></html>"
            Self.respond(connection, status: "200 OK", body: body)
            self?.deliver(.success(line))
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\n"
            + "Connection: close\r\n\r\n" + body
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// 只允許一次的旗標（NWListener 狀態可能多次回報 ready／failed）
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool { lock.withLock { defer { taken = true }; return !taken } }
}
