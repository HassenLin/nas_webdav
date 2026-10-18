import Foundation

/// 解析 `cls -l --time-style=+%s <絕對路徑>` 的輸出（移植自 SmartphoneFileManager）。
///
/// 實測格式（MLSD 伺服器、SFTP）：
///
///     ---------- 501      0         3145728 1792325773 /big.bin
///     d--------- 501      0              64 1792325754 /中文 資料夾/
///     lrwxrwxrwx 0        0               7 1792325754 /link -> a.txt     （LIST 伺服器的符號連結）
///
/// 欄位：權限、擁有者、群組、大小、epoch、完整路徑（資料夾帶結尾 `/`）。擁有者／群組可能缺漏或含數字，
/// 所以從右邊找「大小 epoch /路徑」：路徑一定以 `/` 開頭（我們傳的是絕對路徑），擁有者／群組不會含 `/`。
/// 舊式 LIST 伺服器的時間若不是 epoch（無法解析）則用 epoch 0，不影響其他欄位。
enum LftpListingParser {
    struct Item: Equatable {
        var path: String
        var isDirectory: Bool
        var size: Int64
        var modified: Date
    }

    // Regex 字面值建立後不可變，跨執行緒共用安全（型別未標 Sendable 只因可能含自訂閉包，這裡沒有）
    nonisolated(unsafe) private static let pattern = /^([-dlcbpsD][-rwxsStTlL+.@]*)\s+(?:.*?\s+)??(\d+)\s+(-?\d+|[A-Z][a-z]{2} +\d{1,2} +[\d:]+)\s(\/.*)$/

    static func parse(_ lines: [String]) -> [Item] { lines.compactMap(parseLine) }

    static func parseLine(_ line: String) -> Item? {
        guard let m = line.wholeMatch(of: pattern) else { return nil }
        let permissions = String(m.1)
        var path = String(m.4)
        if permissions.hasPrefix("l"), let arrow = path.range(of: " -> ") { path = String(path[..<arrow.lowerBound]) }
        let isDirectory = permissions.hasPrefix("d") || path.hasSuffix("/")
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let modified = Double(m.3).map { Date(timeIntervalSince1970: $0) } ?? Date(timeIntervalSince1970: 0)
        return Item(path: path.precomposedStringWithCanonicalMapping, isDirectory: isDirectory,
                    size: isDirectory ? 0 : (Int64(m.2) ?? 0), modified: modified)
    }
}

/// lftp 的錯誤輸出 → `DAVError`（執行時固定 `LC_ALL=C`，訊息為英文）。
enum LftpError {
    static func classify(_ output: String) -> DAVError {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        // 只取最後一行有意義的訊息（前面可能有重試的雜訊）
        let message = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? "lftp failed"
        if lower.contains("login failed") || lower.contains("login incorrect") || lower.contains(" 530 ")
            || lower.contains("permission denied (publickey") || lower.contains("authentication failed") {
            return DAVError(code: EACCES, message: "Authentication failed. (\(message))")
        }
        if lower.contains("certificate verification") || lower.contains("certificate") && lower.contains("not trusted") {
            return DAVError(code: EACCES, message: "The server certificate is not trusted. (\(message))",
                            untrustedFingerprint: fingerprint(in: text))
        }
        if lower.contains("host key verification failed") || lower.contains("remote host identification has changed") {
            return DAVError(code: EACCES, message: "The SFTP server's host key has changed. (\(message))")
        }
        if lower.contains("no such file") || lower.contains("file not found") || lower.contains("not found")
            || lower.contains(" 550 ") && lower.contains("no such") {
            return DAVError(code: ENOENT, message: message)
        }
        if lower.contains("file exists") || lower.contains("already exists") {
            return DAVError(code: EEXIST, message: message)
        }
        if lower.contains("not empty") {
            return DAVError(code: ENOTEMPTY, message: message)
        }
        if lower.contains("permission denied") || lower.contains(" 553 ") || lower.contains(" 550 ") && lower.contains("permission") {
            return DAVError(code: EACCES, message: message)
        }
        if lower.contains("max-retries exceeded") || lower.contains("connection refused") || lower.contains("timed out")
            || lower.contains("timeout") || lower.contains("not resolve") || lower.contains("name or service not known")
            || lower.contains("no route to host") || lower.contains("network is unreachable") {
            return DAVError(code: EHOSTUNREACH, message: message)
        }
        return DAVError(code: EIO, message: message)
    }

    /// `Certificate verification: self-signed certificate (60:96:A0:…)` 中的指紋
    static func fingerprint(in text: String) -> String? {
        guard let m = text.firstMatch(of: /\(([0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){15,})\)/) else { return nil }
        return String(m.1)
    }
}
