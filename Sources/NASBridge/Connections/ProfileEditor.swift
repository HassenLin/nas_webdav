import AppKit
import NASBridgeCore
import SwiftUI

/// 單一連線的編輯器：設定欄位、測試連線、儲存、掛載／卸載、刪除。
/// 編輯的是本地草稿，按「儲存」才寫入（變更在下次掛載時生效）。
struct ProfileEditor: View {
    let manager: MountManager
    let isNew: Bool
    let onSaved: () -> Void
    let onDeleted: () -> Void

    @State private var profile: MountProfile
    /// 空字串＝沿用鑰匙圈中的密碼
    @State private var password = ""
    @State private var testing = false
    @State private var report: ConnectionReport?
    @State private var saveError: String?
    @State private var confirmDelete = false

    init(manager: MountManager, initial: MountProfile, isNew: Bool,
         onSaved: @escaping () -> Void, onDeleted: @escaping () -> Void) {
        self.manager = manager
        self.isNew = isNew
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _profile = State(initialValue: initial)
    }

    private var instance: MountInstance { manager.instance(for: profile.id) }
    private var saved: MountProfile? { manager.profile(profile.id) }
    private var hasChanges: Bool { isNew || saved != profile || !password.isEmpty }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name", text: $profile.name)
                TextField("Server URL", text: $profile.serverURL, prompt: Text(verbatim: "https://nas.local:5006"))
                TextField("Remote Path", text: $profile.remotePath, prompt: Text(verbatim: "/home"))
                TextField("Username", text: $profile.username)
                SecureField("Password", text: $password,
                            prompt: Text(isNew ? "Required" : "Saved in Keychain — leave blank to keep"))
            }
            Section("Mount") {
                HStack {
                    TextField("Mount Point", text: $profile.mountPoint,
                              prompt: Text(verbatim: MountProfile.defaultMountPoint(name: profile.name, id: profile.id)))
                    Button("Choose…", action: chooseMountPoint)
                }
                Toggle("Read only", isOn: $profile.readOnly)
                Toggle("Mount automatically when NAS Bridge starts", isOn: $profile.autoMount)
            }
            Section {
                TextField("Pinned certificate SHA-256", text: $profile.pinnedCertSHA256,
                          prompt: Text("Empty — use system trust"))
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Security")
            } footer: {
                Text("HTTPS only. Pin the certificate fingerprint when the NAS uses a self-signed certificate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !isNew {
                Section("Status") { statusView }
            }
            if let report { Section("Connection Test") { reportView(report) } }
            if let saveError {
                Section { Label(saveError, systemImage: "xmark.octagon").foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .toolbar { toolbar }
        .confirmationDialog("Delete “\(profile.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task { await manager.delete(profile.id); onDeleted() }
            }
        } message: {
            Text("The connection is unmounted and its password is removed from the keychain. Files on the NAS are not affected.")
        }
    }

    // MARK: - 區塊

    @ViewBuilder private var statusView: some View {
        LabeledContent("State") {
            Label(StatusText.describe(instance.state), systemImage: StatusText.symbol(instance.state))
                .textSelection(.enabled)
        }
        if instance.state == .mounted {
            LabeledContent("Mounted at") {
                Button(instance.mountPoint) { NSWorkspace.shared.open(URL(fileURLWithPath: instance.mountPoint)) }
                    .buttonStyle(.link)
            }
            if let m = instance.writeMethod {
                LabeledContent("Write mode", value: ConnectionTester.describe(m))
            }
        }
        if let notice = instance.notice {
            Label(notice, systemImage: "info.circle").foregroundStyle(.orange)
        }
        if saved != nil, saved != profile, instance.state.isActive {
            Text("Saved changes take effect after remounting.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func reportView(_ r: ConnectionReport) -> some View {
        Label(r.message, systemImage: r.ok ? "checkmark.seal" : "xmark.octagon")
            .foregroundStyle(r.ok ? .green : .red)
            .textSelection(.enabled)
        if let fp = r.untrustedFingerprint {
            Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Button("Trust This Certificate") {
                profile.pinnedCertSHA256 = fp
                report = nil
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Test Connection", action: test).disabled(testing)
            Button("Save", action: save).disabled(!hasChanges).keyboardShortcut("s")
            if !isNew {
                switch instance.state {
                case .unmounted, .failed:
                    Button("Mount") { Task { await manager.mount(profile.id) } }
                        .disabled(hasChanges)
                        .help(hasChanges ? "Save changes before mounting" : "Mount")
                case .mounted:
                    Button("Unmount") { Task { await manager.unmount(profile.id) } }
                case .mounting, .unmounting:
                    ProgressView().controlSize(.small)
                }
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete")
            }
        }
    }

    // MARK: - 動作

    private func test() {
        testing = true
        report = nil
        let pw = password.isEmpty ? (KeychainStore.password(for: profile.id) ?? "") : password
        let p = profile
        Task {
            report = await ConnectionTester.test(p, password: pw)
            testing = false
        }
    }

    private func save() {
        saveError = nil
        if isNew && password.isEmpty { return saveError = String(localized: "Password is required.") }
        profile.pinnedCertSHA256 = MountProfile.normalizeFingerprint(profile.pinnedCertSHA256)
        do {
            try manager.save(profile, password: password.isEmpty ? nil : password)
            password = ""
            onSaved()
        } catch let e as DAVError {
            saveError = e.message
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func chooseMountPoint() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = String(localized: "Choose an empty folder to use as the mount point.")
        if panel.runModal() == .OK, let url = panel.url { profile.mountPoint = url.path }
    }
}
