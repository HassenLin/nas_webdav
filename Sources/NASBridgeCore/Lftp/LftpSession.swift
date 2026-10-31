import Foundation

/// 一個常駐的 lftp 行程（一條 FTP 控制連線或一條 SSH 連線）。
///
/// 為什麼常駐：FUSE 的每個 getattr／readdir 都是一次遠端操作，每次 `lftp -c` 重新登入要 0.1～1 秒，
/// Finder 開一個資料夾就會卡很久。常駐 lftp 只登入一次，閒置斷線時 lftp 自己重連。
///
/// 協定：stdin 逐條寫入 `<指令> && echo <標記>OK || echo <標記>ERR`，讀 stdout＋stderr（同一條 pipe，
/// 順序與 lftp 寫出的順序一致）直到看到標記行：標記之前的輸出即該指令的結果或錯誤訊息。
/// 標記含亂數，不會與檔名或伺服器訊息撞在一起。
///
/// 併發契約：一個 session 同時只執行一條指令——由 `LftpStore` 的連線池保證，本類別不再加鎖序列化 `run`；
/// 內部只有「讀取執行緒 ↔ 呼叫者」之間的緩衝區以 `cond` 保護。
/// 失效處理：逾時或行程結束時整個行程丟棄，下一次 `run` 自動重新啟動（重新登入）。
final class LftpSession: @unchecked Sendable {
    private let executable: String
    private let prelude: [String]
    private let environment: [String: String]
    /// 與 lftp 之間的位元組編碼（見 `FTPEncoding`）：指令以它編碼寫入、輸出以它解碼
    private let encoding: String.Encoding
    private let marker = "@@NB-\(UUID().uuidString)@@"

    private var process: Process?
    private var input: FileHandle?
    private let cond = NSCondition()
    // 以下由 cond 保護
    private var buffer = Data()
    private var eof = false

    init(executable: String, prelude: [String], environment: [String: String], encoding: String.Encoding = .utf8) {
        self.executable = executable
        self.prelude = prelude
        self.environment = environment
        self.encoding = encoding
    }

    /// 指令列 → 位元組。非 UTF-8 時逐字轉換，並處理 Big5／GBK 的「第二位元組是 `\`」問題（許、功、蓋…）：
    /// lftp 以位元組解析指令列，這個位元組會被當成跳脫字元吞掉 → 前面再補一個 `\`，lftp 解析後還原成原本的位元組。
    /// - Throws: EILSEQ：檔名含所選編碼無法表示的字元（例如 emoji）。
    static func encode(_ line: String, _ encoding: String.Encoding) throws -> Data {
        if encoding == .utf8 { return Data(line.utf8) }
        var out = Data()
        for ch in line {
            guard let bytes = String(ch).data(using: encoding) else {
                throw DAVError.posix(EILSEQ, "The file name contains characters the server encoding cannot represent.")
            }
            if bytes.count > 1 {
                for (i, b) in bytes.enumerated() {
                    if i > 0, b == UInt8(ascii: "\\") { out.append(b) }
                    out.append(b)
                }
            } else {
                out.append(bytes)
            }
        }
        return out
    }

    private func decode<D: DataProtocol>(_ bytes: D) -> String {
        let data = Data(bytes)
        if encoding != .utf8, let s = String(data: data, encoding: encoding) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    deinit { stop() }

    /// 執行一條指令；成功回傳輸出行，失敗丟出分類後的 `DAVError`。
    /// - Parameter timeout: nil＝不設總時限（大檔傳輸），斷線由 lftp 的 `net:timeout` 偵測。
    func run(_ command: String, timeout: TimeInterval?) throws -> [String] {
        try startIfNeeded()
        cond.withLock { buffer.removeAll() }
        let line = "\(command) && echo \(marker)OK || echo \(marker)ERR\n"
        let data = try Self.encode(line, encoding)
        do {
            try input?.write(contentsOf: data)
        } catch {
            stop()
            throw DAVError.posix(EIO, "lftp is not running")
        }
        let (output, ok) = try waitForMarker(deadline: timeout.map { Date().addingTimeInterval($0) })
        let lines = ProcessText.lines(output)
        guard ok else { throw LftpError.classify(output) }
        return lines
    }

    private func waitForMarker(deadline: Date?) throws -> (String, Bool) {
        let tag = Data(marker.utf8)
        cond.lock()
        defer { cond.unlock() }
        var scanned = 0
        while true {
            // 只從上次掃過的位置往後找（大目錄列表會分很多次到達，不重掃整個緩衝）
            if let r = buffer.range(of: tag, in: max(0, scanned - tag.count)..<buffer.count),
               let nl = buffer[r.upperBound...].firstIndex(of: UInt8(ascii: "\n")) {
                let status = String(decoding: buffer[r.upperBound..<nl], as: UTF8.self)
                let output = decode(buffer[..<r.lowerBound])
                buffer = Data(buffer[(nl + 1)...])   // 重建：讓索引回到 0（Data 切片保留原索引）
                return (output, status == "OK")
            }
            scanned = buffer.count
            if eof {
                let output = decode(buffer)
                cond.unlock(); stop(); cond.lock()
                let e = LftpError.classify(output)
                throw e.code == EIO ? DAVError.posix(EIO, "lftp exited: \(e.message)") : e
            }
            if let deadline {
                if !cond.wait(until: deadline) {
                    cond.unlock(); stop(); cond.lock()
                    throw DAVError.posix(ETIMEDOUT, "The server did not respond in time.")
                }
            } else {
                cond.wait()
            }
        }
    }

    private func startIfNeeded() throws {
        if let p = process, p.isRunning { return }
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = []
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { _, new in new }
        p.environment = env
        let stdin = Pipe(), out = Pipe()
        p.standardInput = stdin
        p.standardOutput = out
        p.standardError = out
        cond.withLock { buffer.removeAll(); eof = false }
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self else { return }
            self.cond.withLock {
                if data.isEmpty { self.eof = true; h.readabilityHandler = nil } else { self.buffer.append(data) }
                self.cond.broadcast()
            }
        }
        do {
            try p.run()
        } catch {
            throw DAVError.posix(EIO, "Cannot start lftp: \(error.localizedDescription)")
        }
        process = p
        input = stdin.fileHandleForWriting
        try? input?.write(contentsOf: Self.encode(prelude.joined(separator: "\n") + "\n", encoding))
    }

    func stop() {
        if let p = process, p.isRunning { p.terminate() }
        try? input?.close()
        process = nil
        input = nil
    }
}

enum ProcessText {
    /// 逐行切開；去掉 `\r`，最後一個空行不算。
    static func lines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
