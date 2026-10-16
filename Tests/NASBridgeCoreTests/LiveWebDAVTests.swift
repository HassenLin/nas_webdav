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
            try exercise(WebDAVFileSystem(client: client, readOnly: false, writeMethod: m), dir: root + "/\(m.rawValue)")
        }
    }

    private func exercise(_ fs: WebDAVFileSystem, dir: String) throws {
        try fs.mkdir(dir)
        #expect(try fs.attributes(dir).isDirectory)

        // 建立並寫入 3 MiB（跨讀取區塊、觸發寫入合併）
        let payload = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let f = dir + "/檔案 #1.bin"
        let h = try fs.create(f)
        for off in stride(from: 0, to: payload.count, by: 64 << 10) {
            try fs.write(handle: h, offset: Int64(off), data: payload.subdata(in: off..<min(off + (64 << 10), payload.count)))
        }
        #expect(try fs.attributes(f).size == Int64(payload.count))     // 未上傳前以 handle 為準
        try fs.release(handle: h)
        #expect(try fs.attributes(f).size == Int64(payload.count))

        // 讀回（跨區塊邊界）
        let r = try fs.open(f, flags: O_RDONLY)
        let mid = try fs.read(handle: r, offset: (1 << 20) - 10, count: 100)
        #expect(mid == payload.subdata(in: (1 << 20) - 10..<(1 << 20) + 90))
        let tail = try fs.read(handle: r, offset: Int64(payload.count - 5), count: 100)
        #expect(tail.count == 5)
        #expect(try fs.read(handle: r, offset: Int64(payload.count + 10), count: 10).isEmpty)
        try fs.release(handle: r)

        // 中段覆寫
        let w = try fs.open(f, flags: O_RDWR)
        try fs.write(handle: w, offset: 100, data: Data("HELLO".utf8))
        try fs.release(handle: w)
        let r2 = try fs.open(f, flags: O_RDONLY)
        #expect(try fs.read(handle: r2, offset: 98, count: 9) == payload.subdata(in: 98..<100) + Data("HELLO".utf8) + payload.subdata(in: 105..<107))
        try fs.release(handle: r2)

        // 截斷、改名、列目錄、刪除
        try fs.truncate(f, size: 10)
        #expect(try fs.attributes(f).size == 10)
        let g = dir + "/renamed.bin"
        try fs.rename(f, to: g)
        #expect(try fs.list(dir).map(\.name) == ["renamed.bin"])
        #expect(throws: DAVError.self) { try fs.rmdir(dir) }             // 非空目錄
        try fs.unlink(g)
        #expect(throws: DAVError.self) { try fs.attributes(g) }
        try fs.rmdir(dir)
        let (total, free) = try fs.statfs()
        #expect(total >= free)
    }
}
