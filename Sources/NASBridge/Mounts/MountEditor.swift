import AppKit
import NASBridgeCore
import SwiftUI

/// 單一掛載的編輯器：帳號、遠端路徑、掛載點與選項；測試、儲存、掛載／卸載、刪除。
/// 編輯的是本地草稿，按「儲存」才寫入（變更在下次掛載時生效）。
struct MountEditor: View {
    let manager: MountManager
    let isNew: Bool
    let onSaved: () -> Void
    let onDeleted: () -> Void

    @State private var mount: MountProfile
    @State private var testing = false
    @State private var report: ConnectionReport?
    @State private var saveError: String?
    @State private var confirmDelete = false
    @State private var newAccount: AccountDraft?

    init(manager: MountManager, initial: MountProfile, isNew: Bool,
         onSaved: @escaping () -> Void, onDeleted: @escaping () -> Void) {
        self.manager = manager
        self.isNew = isNew
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        _mount = State(initialValue: initial)
    }

    private var instance: MountInstance { manager.instance(for: mount.id) }
    private var saved: MountProfile? { manager.mountProfile(mount.id) }
    private var hasChanges: Bool { isNew || saved != mount }
    private var account: Account? { manager.account(mount.accountID) }

    var body: some View {
        Form {
            Section("Source") {
                HStack {
                    Picker("Account", selection: $mount.accountID) {
                        if account == nil { Text("Choose…").tag(mount.accountID) }
                        ForEach(manager.accounts) { a in
                            Text(verbatim: "\(a.displayName) — \(a.username)").tag(a.id)
                        }
                    }
                    Button("New Account…") { newAccount = AccountDraft(account: Account(), isNew: true) }
                }
                TextField("Remote Path", text: $mount.remotePath, prompt: Text(verbatim: "/home"))
            }
            Section("Mount") {
                TextField("Name", text: $mount.name)
                HStack {
                    TextField("Mount Point", text: $mount.mountPoint,
                              prompt: Text(verbatim: MountProfile.defaultMountPoint(name: mount.name, id: mount.id)))
                    Button("Choose…", action: chooseMountPoint)
                }
                Toggle("Read only", isOn: $mount.readOnly)
                Toggle("Mount automatically when NAS Bridge starts", isOn: $mount.autoMount)
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
        .sheet(item: $newAccount) { draft in
            AccountEditor(manager: manager, initial: draft.account, isNew: true) { saved in
                mount.accountID = saved.id
            }
        }
        .confirmationDialog("Delete “\(mount.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task { await manager.deleteMount(mount.id); onDeleted() }
            }
        } message: {
            Text("The volume is unmounted. Files on the NAS are not affected.")
        }
    }

    // MARK: - 區塊

    @ViewBuilder private var statusView: some View {
        LabeledContent("State") {
            Label(StatusText.describe(instance.state), systemImage: StatusText.symbol(instance.state))
                .foregroundStyle(StatusText.color(instance.state))
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
        if saved != nil, saved != mount, instance.state.isActive {
            Text("Saved changes take effect after remounting.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func reportView(_ r: ConnectionReport) -> some View {
        Label(r.message, systemImage: r.ok ? "checkmark.seal" : "xmark.octagon")
            .foregroundStyle(r.ok ? .green : .red)
            .textSelection(.enabled)
        if r.untrustedFingerprint != nil {
            Text("Trust the certificate in the account settings.").font(.caption)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button("Test Connection", action: test).disabled(testing || account == nil)
            Button("Save", action: save).disabled(!hasChanges).keyboardShortcut("s")
            if !isNew {
                switch instance.state {
                case .unmounted, .failed:
                    Button("Mount") { Task { await manager.mountOrPromptInstall(mount.id) } }
                        .disabled(hasChanges)
                        .help(hasChanges ? "Save changes before mounting" : "Mount")
                case .mounted:
                    Button("Unmount") { Task { await manager.unmount(mount.id) } }
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
        guard let account else { return }
        testing = true
        report = nil
        let (path, probe) = (mount.remotePath, !mount.readOnly)
        let pw = KeychainStore.password(for: account) ?? ""
        Task {
            report = await ConnectionTester.test(account, remotePath: path, password: pw, probeWrites: probe)
            testing = false
        }
    }

    private func save() {
        saveError = nil
        do {
            try manager.saveMount(mount)
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
        if panel.runModal() == .OK, let url = panel.url { mount.mountPoint = url.path }
    }
}
