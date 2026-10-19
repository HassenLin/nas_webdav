import Foundation

/// 遠端協定。新增協定＝這裡加一個 case、`RemoteStoreFactory` 加一條對應、`AccountEditor` 加該協定專屬欄位；
/// 掛載、worker、FUSE 橋接都只認 `RemoteStore`，不需變動。
public enum RemoteProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case webdav, ftp, sftp, pcloud

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .webdav: "WebDAV"
        case .ftp: "FTP"
        case .sftp: "SFTP"
        case .pcloud: "pCloud"
        }
    }

    /// `serverURL` 的 scheme；pCloud 不用 `serverURL`（API host 由地區決定）。
    public var scheme: String {
        switch self {
        case .webdav, .pcloud: "https"
        case .ftp: "ftp"
        case .sftp: "sftp"
        }
    }

    /// 需要 lftp（外部工具，`brew install lftp`）
    public var needsLftp: Bool { self == .ftp || self == .sftp }
}

/// FTP 的加密方式
public enum FTPSecurity: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 純 FTP：帳密與資料都是明文（允許，但 UI 顯示警告）
    case none
    /// FTPS explicit：連 21 埠後以 `AUTH TLS` 升級（最常見，Synology 預設）
    case explicit
    /// FTPS implicit：一連線就是 TLS（預設 990 埠）
    case implicit

    public var id: String { rawValue }
}

/// FTP 資料通道的建立方式
public enum FTPMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 被動（PASV／EPSV）：由用戶端連到伺服器，NAT 後的用戶端可用（預設）
    case passive
    /// 主動（PORT／EPRT）：由伺服器回連用戶端
    case active

    public var id: String { rawValue }
}

/// pCloud 資料中心。帳號建立時就固定在其中一區，API host 不同、互不相通（打錯區會回 2000 登入失敗）。
public enum PCloudRegion: String, Codable, CaseIterable, Identifiable, Sendable {
    /// 美國（locationid 1）
    case us
    /// 歐洲（盧森堡，locationid 2）
    case eu

    public var id: String { rawValue }

    public var apiHost: String { self == .us ? "api.pcloud.com" : "eapi.pcloud.com" }

}

/// 一個遠端帳號：協定＋伺服器＋使用者名稱（＋密碼，存鑰匙圈，見 `KeychainStore`）。
/// 多個掛載（`MountProfile`）可共用同一帳號，例如同一台 NAS 的 `/home` 與 `/photo`。
///
/// 位址一律存在 `serverURL`（WebDAV `https://nas:5006/dav`、FTP `ftp://nas:21`、SFTP `sftp://nas`），
/// 協定專屬的選項（FTP 加密／主動被動、SFTP 私鑰、pCloud 地區）各自一欄，其他協定忽略。
public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    /// 顯示名稱；空字串時以主機名稱顯示（`displayName`）。
    public var name = ""
    public var `protocol`: RemoteProtocol = .webdav
    /// 例如 `https://nas.local:5006`（Synology WebDAV HTTPS 預設埠 5006）；pCloud 不使用。
    public var serverURL = "https://"
    /// pCloud 為登入用的 email
    public var username = ""
    /// WebDAV：釘選的伺服器憑證 SHA-256（hex，小寫無冒號）。設定後只接受此憑證；空字串＝走系統信任鏈。
    public var pinnedCertSHA256 = ""

    // MARK: 協定專屬

    public var ftpSecurity: FTPSecurity = .explicit
    public var ftpMode: FTPMode = .passive
    /// FTPS：信任的自簽憑證指紋（lftp 錯誤訊息中的 `AA:BB:…` 格式，餵給 `ssl:verify-certificate/<指紋>`）
    public var ftpsTrustedFingerprint = ""
    /// SFTP：私鑰檔路徑；空字串＝密碼登入。有密語的金鑰請先加入 ssh-agent。
    public var sftpKeyPath = ""
    /// pCloud：帳號所在資料中心（登入時先試這區，失敗再試另一區，以成功的那區覆寫）
    public var pcloudRegion: PCloudRegion = .us

    public init(protocol: RemoteProtocol = .webdav) {
        self.protocol = `protocol`
        serverURL = `protocol` == .pcloud ? "" : "\(`protocol`.scheme)://"
    }

    public var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { return n }
        if self.protocol == .pcloud { return username.isEmpty ? "pCloud" : "pCloud (\(username))" }
        return url?.host() ?? serverURL
    }

    /// 解析後的伺服器 URL（不含路徑尾端的 `/`）；pCloud 為地區的 API host。
    public var url: URL? {
        if self.protocol == .pcloud { return URL(string: "https://\(pcloudRegion.apiHost)") }
        guard var comps = URLComponents(string: serverURL.trimmingCharacters(in: .whitespaces)),
              comps.host?.isEmpty == false else { return nil }
        while comps.path.hasSuffix("/") { comps.path.removeLast() }
        return comps.url
    }

    /// FTP／SFTP 編輯器的「伺服器」欄：`主機[:埠]`，寫入時補上協定的 scheme。
    public var hostAndPort: String {
        get {
            let s = serverURL.trimmingCharacters(in: .whitespaces)
            return s.range(of: "://").map { String(s[$0.upperBound...]) } ?? s
        }
        set {
            var v = newValue.trimmingCharacters(in: .whitespaces)
            if let r = v.range(of: "://") { v = String(v[r.upperBound...]) }
            serverURL = "\(self.protocol.scheme)://" + v
        }
    }

    /// 切換協定：保留主機，換掉 scheme（WebDAV 的路徑前綴在 FTP／SFTP 沒意義，一併去掉）。
    public mutating func switchProtocol(to p: RemoteProtocol) {
        guard p != self.protocol else { return }
        // 埠是協定專屬的（5006 對 FTP 沒意義），只保留主機；pCloud 的 url 是 API host，不沿用
        let host = self.protocol == .pcloud ? "" : (url?.host() ?? "")
        self.protocol = p
        serverURL = p == .pcloud ? "" : "\(p.scheme)://\(host)"
    }

    public var defaultPort: Int {
        switch self.protocol {
        case .webdav, .pcloud: 443
        case .ftp: ftpSecurity == .implicit ? 990 : 21
        case .sftp: 22
        }
    }

    public var effectivePort: Int { url?.port ?? defaultPort }

    /// 帳密與資料是否加密傳送（UI 依此顯示「未加密」警告）
    public var isEncrypted: Bool { self.protocol != .ftp || ftpSecurity != .none }

    /// 清單「協定」欄：FTP 加密時顯示 FTPS、pCloud 帶地區
    public var protocolLabel: String {
        switch self.protocol {
        case .ftp where ftpSecurity != .none: "FTPS"
        case .pcloud: "pCloud \(pcloudRegion.rawValue.uppercased())"
        default: self.protocol.title
        }
    }

    /// 清單「伺服器」欄
    public var serverLabel: String { self.protocol == .pcloud ? pcloudRegion.apiHost : serverURL }

    /// SFTP 以私鑰登入（不需要密碼）
    public var usesKeyAuth: Bool { self.protocol == .sftp && !sftpKeyPath.isEmpty }

    /// 回傳設定錯誤訊息；nil 表示可用。
    /// WebDAV 只允許 HTTPS：帳密以 Basic/Digest 傳送，明文 HTTP 會外洩。
    /// FTP 允許明文（協定本身如此，許多舊 NAS 只有純 FTP），由 UI 顯示警告。
    public func validationError() -> String? {
        if self.protocol == .pcloud { return username.contains("@") ? nil : "Enter the pCloud email." }
        guard let url else { return "Server URL is invalid." }
        if url.scheme?.lowercased() != self.protocol.scheme {
            return self.protocol == .webdav ? "Only https:// is allowed." : "Server URL is invalid."
        }
        if username.isEmpty { return "Username is required." }
        if !pinnedCertSHA256.isEmpty, Self.normalizeFingerprint(pinnedCertSHA256).count != 64 {
            return "Pinned SHA-256 must be 64 hex characters."
        }
        if usesKeyAuth, !FileManager.default.fileExists(atPath: (sftpKeyPath as NSString).expandingTildeInPath) {
            return "The private key file does not exist."
        }
        return nil
    }

    /// 接受 `AB:CD:...` 或含空白的寫法，正規化為小寫連續 hex。
    public static func normalizeFingerprint(_ s: String) -> String {
        s.lowercased().filter { $0.isHexDigit }
    }
}

// 逐欄 decodeIfPresent：舊版 config.json（只有 WebDAV 欄位）仍可讀，缺的欄位用預設值
public extension Account {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = Account()
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? base.id
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? base.name
        self.protocol = try c.decodeIfPresent(RemoteProtocol.self, forKey: .protocol) ?? base.protocol
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? base.serverURL
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? base.username
        pinnedCertSHA256 = try c.decodeIfPresent(String.self, forKey: .pinnedCertSHA256) ?? base.pinnedCertSHA256
        ftpSecurity = try c.decodeIfPresent(FTPSecurity.self, forKey: .ftpSecurity) ?? base.ftpSecurity
        ftpMode = try c.decodeIfPresent(FTPMode.self, forKey: .ftpMode) ?? base.ftpMode
        ftpsTrustedFingerprint = try c.decodeIfPresent(String.self, forKey: .ftpsTrustedFingerprint) ?? base.ftpsTrustedFingerprint
        sftpKeyPath = try c.decodeIfPresent(String.self, forKey: .sftpKeyPath) ?? base.sftpKeyPath
        pcloudRegion = try c.decodeIfPresent(PCloudRegion.self, forKey: .pcloudRegion) ?? base.pcloudRegion
    }
}
