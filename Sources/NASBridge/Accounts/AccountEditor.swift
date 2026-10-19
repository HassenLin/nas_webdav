import AppKit
import NASBridgeCore
import SwiftUI

/// 帳號編輯表單（sheet）：協定、伺服器、帳號、密碼（鑰匙圈）、協定專屬選項、測試連線。
///
/// 協定專屬欄位：
///   - WebDAV：伺服器網址（可含路徑前綴）、憑證釘選（SHA-256）
///   - FTP：加密（FTPS explicit／implicit／無）、資料通道（被動／主動）、FTPS 自簽憑證指紋
///   - SFTP：密碼或私鑰登入
///   - pCloud：地區、email＋密碼登入（兩步驟驗證時再輸入驗證碼）；鑰匙圈只存登入 token，不存密碼
struct AccountEditor: View {
    let manager: MountManager
    let isNew: Bool
    let onSaved: (Account) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var account: Account
    /// 空字串＝沿用鑰匙圈中的密碼（pCloud：只用來登入，不儲存）
    @State private var password = ""
    /// pCloud：這次登入取得、尚未存入鑰匙圈的 token
    @State private var pcloudToken: String?
    /// pCloud：等待輸入兩步驟驗證碼
    @State private var pendingTwoFactor: PCloudLogin.TwoFactorRequired?
    @State private var verificationCode = ""
    /// pCloud：鑰匙圈中已存 token 的實際狀態（見 `checkStoredToken`）
    @State private var storedToken: StoredTokenState = .none
    @State private var signingIn = false
    @State private var testing = false
    @State private var report: ConnectionReport?
    @State private var error: String?

    init(manager: MountManager, initial: Account, isNew: Bool, onSaved: @escaping (Account) -> Void = { _ in }) {
        self.manager = manager
        self.isNew = isNew
        self.onSaved = onSaved
        _account = State(initialValue: initial)
    }

    private var proto: RemoteProtocol { account.protocol }

    /// pCloud 登入進行中（正在輸入密碼或驗證碼）：Return 要觸發「登入」／「驗證」而不是「儲存」——
    /// 儲存會關閉表單，進行到一半的兩步驟驗證狀態就會遺失、回到輸入密碼（SmartphoneFileManager 實機踩到）
    private var pcloudSigningIn: Bool { proto == .pcloud && (pendingTwoFactor != nil || !password.isEmpty) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(isNew ? "New Account" : "Account") {
                    Picker("Protocol", selection: Binding(get: { account.protocol }, set: { switchProtocol($0) })) {
                        ForEach(RemoteProtocol.allCases) { Text(verbatim: $0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    serverFields
                    TextField("Name", text: $account.name, prompt: Text(verbatim: account.displayName))
                }
                if proto == .pcloud { pcloudSections }
                securitySection
                if proto.needsLftp, ToolLocator.lftp == nil {
                    Section {
                        Label("FTP and SFTP need lftp: brew install lftp", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
                if let report { Section("Connection Test") { reportView(report) } }
                if let error {
                    Section { Label(error, systemImage: "xmark.octagon").foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Test Connection", action: test).disabled(testing || signingIn)
                if testing { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(pcloudSigningIn ? nil : .defaultAction)
                    .disabled(signingIn)
            }
            .padding()
        }
        .frame(width: 560, height: 600)
    }

    // MARK: - 區塊

    @ViewBuilder private var serverFields: some View {
        switch proto {
        case .webdav:
            TextField("Server URL", text: $account.serverURL, prompt: Text(verbatim: "https://nas.local:5006"))
        case .ftp, .sftp:
            TextField("Server", text: $account.hostAndPort,
                      prompt: Text(verbatim: proto == .ftp ? "nas.local  (nas.local:2121)" : "nas.local  (nas.local:2222)"))
        case .pcloud:
            Picker("Region", selection: $account.pcloudRegion) {
                Text("United States").tag(PCloudRegion.us)
                Text("Europe").tag(PCloudRegion.eu)
            }
        }
        if proto == .ftp {
            Picker("Encryption", selection: $account.ftpSecurity) {
                Text("FTPS — explicit TLS").tag(FTPSecurity.explicit)
                Text("FTPS — implicit TLS").tag(FTPSecurity.implicit)
                Text("None (unencrypted)").tag(FTPSecurity.none)
            }
            Picker("Data connection", selection: $account.ftpMode) {
                Text("Passive").tag(FTPMode.passive)
                Text("Active").tag(FTPMode.active)
            }
            .pickerStyle(.segmented)
        }
        if proto == .pcloud {
            TextField("Email", text: $account.username)
        } else {
            TextField("Username", text: $account.username)
        }
        if proto == .sftp {
            Picker("Sign in with", selection: Binding(get: { account.sftpKeyPath.isEmpty ? 0 : 1 },
                                                      set: { account.sftpKeyPath = $0 == 0 ? "" : defaultKeyPath })) {
                Text("Password").tag(0)
                Text("Private key").tag(1)
            }
            .pickerStyle(.segmented)
            if account.usesKeyAuth {
                HStack {
                    TextField("Private key", text: $account.sftpKeyPath, prompt: Text(verbatim: "~/.ssh/id_ed25519"))
                    Button("Choose…", action: chooseKey)
                }
            }
        }
        if proto == .pcloud {
            SecureField("Password", text: $password, prompt: Text("Used only to sign in — not stored"))
        } else if !account.usesKeyAuth {
            SecureField("Password", text: $password,
                        prompt: Text(isNew ? "Stored in the keychain" : "Saved in Keychain — leave blank to keep"))
        }
    }

    @ViewBuilder private var pcloudSections: some View {
        Section {
            LabeledContent("Status") {
                if pcloudToken != nil {
                    Text("Signed in")
                } else {
                    switch storedToken {
                    case .none: Text("Not signed in").foregroundStyle(.orange)
                    case .checking: Text("Checking…").foregroundStyle(.secondary)
                    case .valid: Text("Signed in")
                    case .expired: Text("Sign-in expired — enter the password and sign in again").foregroundStyle(.red)
                    case .unverified: Text("Signed in (cannot reach pCloud to verify)").foregroundStyle(.orange)
                    }
                }
            }
            if pendingTwoFactor != nil {
                HStack {
                    TextField("Verification code", text: $verificationCode, prompt: Text(verbatim: "123456"))
                    Button("Verify", action: verify)
                        .keyboardShortcut(.defaultAction)
                        .disabled(signingIn || verificationCode.filter(\.isNumber).isEmpty)
                    Button("Cancel") { pendingTwoFactor = nil; verificationCode = "" }
                }
            } else {
                Button("Sign In", action: signIn)
                    .keyboardShortcut(pcloudSigningIn ? .defaultAction : nil)
                    .disabled(signingIn || password.isEmpty || !account.username.contains("@"))
            }
            if signingIn { ProgressView().controlSize(.small) }
        } header: {
            Text("pCloud Sign-in")
        } footer: {
            Text("The password is sent only as a one-time digest to get a sign-in token; only the token is stored in the keychain. The region is detected automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        // email 改變時重新檢查（先等 0.5 秒：連續輸入時前一次會被取消，不會每個字都打一次 API）
        .task(id: account.username) { await checkStoredToken() }
    }

    /// 鑰匙圈中已存 token 的狀態。「有 token」不等於已登入：token 會因登出、過期、改密碼而失效，
    /// 所以開啟表單時實際向 pCloud 確認一次。停留狀態：
    /// none（無 token）／checking／valid／expired（需重新登入）／unverified（連不上 pCloud，無法確認）
    enum StoredTokenState { case none, checking, valid, expired, unverified }

    private func checkStoredToken() async {
        guard proto == .pcloud, let token = KeychainStore.secret(for: account) else { return storedToken = .none }
        storedToken = .checking
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        do {
            _ = try await PCloudLogin.validate(token: token, region: account.pcloudRegion)
            storedToken = .valid
        } catch {
            // 被取消（email 又改了）時 URLSession 回 cancelled，也會對應成 EACCES——不可當成失效
            guard !Task.isCancelled else { return }
            storedToken = (error as? DAVError)?.code == EACCES ? .expired : .unverified
        }
    }

    @ViewBuilder private var securitySection: some View {
        switch proto {
        case .webdav:
            Section {
                TextField("Pinned certificate SHA-256", text: $account.pinnedCertSHA256,
                          prompt: Text("Empty — use system trust"))
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Security")
            } footer: {
                Text("HTTPS only. Pin the certificate fingerprint when the NAS uses a self-signed certificate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .ftp where account.ftpSecurity == .none:
            Section("Security") {
                Label("Unencrypted: the password and files are sent in plain text. Use FTPS when the server supports it.",
                      systemImage: "exclamationmark.shield")
                    .foregroundStyle(.orange)
            }
        case .ftp:
            Section {
                TextField("Trusted certificate fingerprint", text: $account.ftpsTrustedFingerprint,
                          prompt: Text("Empty — use system trust"))
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Security")
            } footer: {
                Text("Filled in by “Trust This Certificate” when the server uses a self-signed certificate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .sftp:
            Section {
                LabeledContent("Host key") { Text("Remembered on first connection") }
            } header: {
                Text("Security")
            } footer: {
                Text("If the server's host key changes later, the connection is refused.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .pcloud:
            EmptyView()
        }
    }

    @ViewBuilder private func reportView(_ r: ConnectionReport) -> some View {
        Label(r.message, systemImage: r.ok ? "checkmark.seal" : "xmark.octagon")
            .foregroundStyle(r.ok ? .green : .red)
            .textSelection(.enabled)
        if let fp = r.untrustedFingerprint, proto == .webdav || proto == .ftp {
            Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Trust This Certificate") {
                if proto == .webdav { account.pinnedCertSHA256 = fp } else { account.ftpsTrustedFingerprint = fp }
                report = nil
            }
        }
    }

    // MARK: - 動作

    private var defaultKeyPath: String {
        let ssh = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        return ["id_ed25519", "id_ecdsa", "id_rsa"].map { ssh.appendingPathComponent($0).path }
            .first { FileManager.default.fileExists(atPath: $0) }.map { ($0 as NSString).abbreviatingWithTildeInPath }
            ?? "~/.ssh/id_ed25519"
    }

    private func switchProtocol(_ p: RemoteProtocol) {
        account.switchProtocol(to: p)
        report = nil
        error = nil
    }

    /// 測試用祕密：有輸入就用輸入的，否則用鑰匙圈（含使用者先前在別處存的同伺服器密碼）。
    private var effectiveSecret: String {
        if proto == .pcloud { return pcloudToken ?? KeychainStore.secret(for: account) ?? "" }
        if account.usesKeyAuth { return "" }
        return password.isEmpty ? (KeychainStore.secret(for: account) ?? "") : password
    }

    private func test() {
        testing = true
        report = nil
        let (a, secret) = (account, effectiveSecret)
        Task {
            report = await ConnectionTester.test(a, credential: secret)
            testing = false
        }
    }

    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        panel.message = String(localized: "Choose the SSH private key.")
        if panel.runModal() == .OK, let url = panel.url {
            account.sftpKeyPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// pCloud 帳號密碼登入：成功拿 token；帳號開了兩步驟驗證則先顯示驗證碼欄位（`verify`）。
    private func signIn() {
        let (email, pw, region) = (account.username, password, account.pcloudRegion)
        runSignIn { try await PCloudLogin.signIn(email: email, password: pw, preferredRegion: region) }
    }

    private func verify() {
        guard let pending = pendingTwoFactor else { return }
        let code = verificationCode
        runSignIn { try await PCloudLogin.verify(pending, code: code) }
    }

    private func runSignIn(_ attempt: @escaping @Sendable () async throws -> PCloudLogin.Session) {
        error = nil
        report = nil
        signingIn = true
        Task {
            defer { signingIn = false }
            do {
                let session = try await attempt()
                pcloudToken = session.token
                account.pcloudRegion = session.region   // 以實際登入成功的地區為準
                password = ""
                pendingTwoFactor = nil
                verificationCode = ""
            } catch let tfa as PCloudLogin.TwoFactorRequired {
                pendingTwoFactor = tfa
            } catch let e as DAVError {
                error = e.message
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func save() {
        error = nil
        account.pinnedCertSHA256 = Account.normalizeFingerprint(account.pinnedCertSHA256)
        let secret: String?
        switch proto {
        case .pcloud:
            if pcloudToken == nil, KeychainStore.secret(for: account) == nil {
                return error = String(localized: "Sign in to pCloud first.")
            }
            secret = pcloudToken
        default:
            if password.isEmpty, isNew, !account.usesKeyAuth, KeychainStore.secret(for: account) == nil {
                return error = String(localized: "Password is required.")
            }
            secret = password.isEmpty ? nil : password
        }
        do {
            try manager.saveAccount(account, secret: secret)
            onSaved(account)
            dismiss()
        } catch let e as DAVError {
            error = e.message
        } catch {
            self.error = error.localizedDescription
        }
    }
}
