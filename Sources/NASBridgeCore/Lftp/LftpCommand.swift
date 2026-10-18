import Foundation

/// 組 lftp 指令：連線設定（`set …`）＋`open`＋操作指令的引號跳脫。純函式、可單元測試。
/// （移植自 SmartphoneFileManager，改為常駐 session 用：不設 `cmd:fail-exit`、關閉 lftp 自己的目錄快取。）
///
/// lftp 實測行為（4.9.3）：
/// - 預設 `net:max-retries 1000`、`net:timeout 5m`：連不上時會重試很久才失敗，所以一律覆寫。
/// - 訊息會依語系翻譯 → 執行時固定 `LC_ALL=C`，錯誤分類（`LftpError`）才比對得到。
/// - 密碼以 `open --env-password` 從環境變數 `LFTP_PASSWORD` 讀取，不會出現在行程參數（`ps` 看得到）與 log。
/// - 引號：lftp 自己解析指令列，雙引號內 `\"`、`\\` 為跳脫。
/// - `cls` 會展開萬用字元（`*?[]`），檔名含這些字元時要先以 `\` 跳脫；`get`／`put`／`rm`／`mv` 不展開。
struct LftpCommand: Sendable, Equatable {
    let account: Account
    let timeout: Int
    let knownHostsFile: String

    /// 雙引號字串（不展開萬用字元的指令用）。換行會讓一條指令斷成兩條，直接拒絕。
    static func quote(_ text: String) throws -> String {
        guard !text.contains(where: \.isNewline) else { throw DAVError.posix(EINVAL, "File names with line breaks are not supported.") }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// `cls` 用：先跳脫萬用字元再加引號
    static func quoteGlob(_ path: String) throws -> String {
        var escaped = ""
        for c in path {
            if "*?[]\\".contains(c) { escaped.append("\\") }
            escaped.append(c)
        }
        return try quote(escaped)
    }

    /// `open` 用的 URL（不含帳密）。FTPS implicit 用 `ftps://`；explicit 仍是 `ftp://` 加 `ftp:ssl-force`
    var url: String {
        let scheme = account.protocol == .sftp ? "sftp" : (account.ftpSecurity == .implicit ? "ftps" : "ftp")
        let host = account.url?.host() ?? ""
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host   // IPv6
        return "\(scheme)://\(hostPart):\(account.effectivePort)"
    }

    /// 連線設定（每行一條 `set`）
    var settings: [String] {
        var lines = [
            "set cmd:interactive no",
            // 常駐 session 中任一指令失敗不可結束整個 lftp（成敗改由 `&& echo OK || echo ERR` 判斷）
            "set cmd:fail-exit no",
            // 同一帳號有多個 session（連線池），lftp 自己的目錄快取會讓別的 session 寫入後看到舊資料；
            // 快取交給 RemoteFileSystem 的 MetadataCache 統一管理
            "set cache:enable no",
            "set net:timeout \(max(5, timeout))",
            "set net:max-retries 3",
            "set net:reconnect-interval-base 3",
            "set net:reconnect-interval-multiplier 1",
            "set net:idle 120",
            "set xfer:clobber yes",
        ]
        if account.protocol == .sftp {
            // 主機金鑰：首次連線自動記住（TOFU），之後變了就拒絕；記在 app 自己的 known_hosts，
            // 不動使用者的 ~/.ssh/known_hosts。ssh 把 UserKnownHostsFile 的值以空白切成多個檔案，
            // 路徑（Application Support）要再包一層雙引號
            var ssh = "ssh -a -x -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30"
                + " -o " + Self.shellQuote("UserKnownHostsFile=\"\(knownHostsFile)\"")
            if account.usesKeyAuth {
                ssh += " -o IdentitiesOnly=yes -o PasswordAuthentication=no -i "
                    + Self.shellQuote((account.sftpKeyPath as NSString).expandingTildeInPath)
            }
            lines.append("set sftp:connect-program " + Self.rawQuote(ssh))
            return lines
        }
        lines.append("set ftp:passive-mode \(account.ftpMode == .passive ? "on" : "off")")
        switch account.ftpSecurity {
        case .none:
            lines.append("set ftp:ssl-allow no")
        case .explicit:
            lines += ["set ftp:ssl-force yes", "set ftp:ssl-protect-data yes", "set ftp:ssl-protect-list yes"]
        case .implicit:
            lines += ["set ftp:ssl-protect-data yes", "set ftp:ssl-protect-list yes"]
        }
        // 自簽憑證：只信任使用者確認過的那一張（lftp 以指紋為 closure 的設定），其他憑證仍照常驗證
        let fp = account.ftpsTrustedFingerprint.trimmingCharacters(in: .whitespaces)
        if account.ftpSecurity != .none, !fp.isEmpty, fp.allSatisfy({ $0.isHexDigit || $0 == ":" }) {
            lines.append("set ssl:verify-certificate/\(fp) no")
        }
        return lines
    }

    /// `open` 指令：使用者名稱以 `-u` 傳，密碼走環境變數。
    /// SFTP 金鑰登入時給空密碼（`-u "user,"`），ssh 若仍要密碼會立刻失敗，而不是卡在等待輸入。
    var open: String {
        if account.usesKeyAuth {
            return "open -u " + Self.rawQuote(account.username + ",") + " " + Self.rawQuote(url)
        }
        return "open --env-password -u " + Self.rawQuote(account.username) + " " + Self.rawQuote(url)
    }

    /// session 開頭要送的指令（設定＋open；open 是延遲連線，第一個實際操作才會登入）
    var prelude: [String] { settings + [open] }

    /// 不會含換行的內部字串（設定值、帳號）用；帳號名稱含換行時 `Account.validationError` 之前就無法輸入
    static func rawQuote(_ text: String) -> String {
        (try? quote(text)) ?? "\"\""
    }

    /// sh 單引號跳脫（只用在 `sftp:connect-program`：那一串由 lftp 交給 sh 執行）
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 找外部工具（app 由 Finder 啟動時 PATH 只有系統目錄，Homebrew 路徑要自己找）。
public enum ToolLocator {
    public static func find(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + path.split(separator: ":").map(String.init)
        return dirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static var lftp: String? { find("lftp") }
}
