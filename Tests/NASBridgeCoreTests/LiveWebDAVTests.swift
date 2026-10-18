import Foundation
import Testing
@testable import NASBridgeCore

/// 對真實 WebDAV 伺服器的整合測試（預設略過）。
///
///   NB_LIVE_URL=https://host:port/share NB_LIVE_USER=… NB_LIVE_PASS=… swift test --filter Live
///
/// 只在伺服器上建立並清除一個 `nasbridge-test-<uuid>` 資料夾。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NB_LIVE_URL"] != nil))
struct LiveWebDAVTests {
    let client: WebDAVClient
    let root = "/nasbridge-test-\(UUID().uuidString.prefix(8))"

    init() {
        let env = ProcessInfo.processInfo.environment
        client = WebDAVClient(baseURL: URL(string: env["NB_LIVE_URL"]!)!,
                              username: env["NB_LIVE_USER"] ?? "", password: env["NB_LIVE_PASS"] ?? "")
    }

    @Test func probeAndFileSystemRoundTrip() throws {
        try client.mkcol(root)
        defer { try? client.delete(root) }
        let method = client.probePartialWrite(in: root)
        print("partial write method:", method)
        for m in Set([method, .none]) {
            let fs = RemoteFileSystem(store: WebDAVStore(client: client, partialWrite: m), readOnly: false)
            try FileSystemExercise.run(fs, dir: root + "/\(m.rawValue)")
        }
    }
}
