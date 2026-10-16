import Foundation
import Observation
import os

/// 單一掛載的狀態。
///
/// 停留狀態（無外部事件就不會改變）：`unmounted`、`mounted`、`failed`
/// 過渡狀態（等待 worker 或 umount 完成）：`mounting`、`unmounting`
///
/// ```
///              mount()                READY
///  unmounted ─────────► mounting ───────────► mounted
///     ▲  ▲                 │  │ ERROR/exit≠0     │ │ worker 結束(0)：Finder 退出
///     │  │   unmount()     │  ▼                  │ └───────────────► unmounted
///     │  │  (SIGTERM)      │ failed ◄────────────┘ worker 結束(≠0)：崩潰
///     │  │                 ▼   │ mount()
///     │  └──────────── unmounting ◄── unmount()（自 mounted）
///     │   worker 結束      │ umount 失敗（使用中）→ 回到 mounted 並附 notice
///     └── failed 也可再 mount()
/// ```
public enum MountState: Equatable, Sendable {
    case unmounted
    case mounting
    case mounted
    case unmounting
    case failed(String)

    public var isActive: Bool { self == .mounted || self == .mounting || self == .unmounting }
}

/// 一個 profile 的掛載執行體：管理 worker 子行程並驅動 `MountState`。
/// 所有狀態轉移都在 main actor 上、集中於 `handle(_:)`，轉移表即上方的圖。
@MainActor @Observable
public final class MountInstance: Identifiable {
    public let id: UUID
    public private(set) var state: MountState = .unmounted
    /// worker 探測到的寫入方式（掛載後顯示用）。
    public private(set) var writeMethod: PartialWriteMethod?
    /// 非致命的提示（例如卸載時磁碟使用中），下一次狀態轉移時清除。
    public private(set) var notice: String?
    /// 目前（或最後一次）的掛載點。
    public private(set) var mountPoint = ""

    @ObservationIgnored private let workerURL: URL
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var pendingError: String?
    private static let log = Logger(subsystem: "idv.hassen.nasbridge", category: "mount")

    init(id: UUID, workerURL: URL) {
        self.id = id
        self.workerURL = workerURL
    }

    // MARK: - 事件與轉移表

    enum Event {
        case workerConnected(PartialWriteMethod?)
        case workerReady
        case workerError(String)
        case workerExited(Int32)
    }

    private func handle(_ event: Event) {
        switch (state, event) {
        case (.mounting, .workerConnected(let m)):
            writeMethod = m
        case (.mounting, .workerReady):
            transition(to: .mounted)
        case (.mounting, .workerError(let msg)), (.mounted, .workerError(let msg)):
            pendingError = msg                       // 等 worker 結束時一併轉移
        case (.mounting, .workerExited(let code)):
            transition(to: .failed(pendingError ?? "Mount failed (worker exit code \(code))."))
        case (.mounted, .workerExited(let code)):
            transition(to: code == 0 ? .unmounted : .failed(pendingError ?? "Mount stopped unexpectedly (code \(code))."))
        case (.unmounting, .workerExited):
            transition(to: .unmounted)
        default:
            Self.log.debug("ignored event \(String(describing: event)) in state \(String(describing: self.state))")
        }
        if case .workerExited = event { process = nil }
    }

    private func transition(to new: MountState) {
        Self.log.info("\(self.id) \(String(describing: self.state)) → \(String(describing: new))")
        state = new
        notice = nil
        if new != .mounted && new != .mounting { writeMethod = nil }
    }

    // MARK: - 指令

    /// 啟動 worker 掛載。只在 `unmounted` / `failed` 有效。
    func mount(_ profile: MountProfile, password: String) async {
        switch state {
        case .unmounted, .failed: break
        default: return
        }
        mountPoint = profile.resolvedMountPoint
        pendingError = nil
        transition(to: .mounting)

        // 前一次 worker 被強制結束可能留下失效的掛載，先清掉，否則新掛載會失敗
        if MountTable.isMountPoint(mountPoint) {
            let (ok, out) = await MountTable.unmount(mountPoint, force: true)
            if !ok { return transition(to: .failed("\(mountPoint) is already in use: \(out)")) }
        }

        let p = Process()
        p.executableURL = workerURL
        p.arguments = [WorkerProtocol.flag]
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        let lines = LineSplitter { [weak self] line in
            guard let event = WorkerEvent(line: line) else { return }
            Task { @MainActor in self?.receive(event) }
        }
        stdout.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil } else { lines.feed(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            Task { @MainActor in self?.handle(.workerExited(code)) }
        }
        do {
            try p.run()
        } catch {
            return transition(to: .failed("Cannot start worker: \(error.localizedDescription)"))
        }
        process = p
        let config = try? JSONEncoder().encode(WorkerConfig(profile: profile, password: password))
        stdin.fileHandleForWriting.write(config ?? Data())
        try? stdin.fileHandleForWriting.close()
    }

    private func receive(_ event: WorkerEvent) {
        switch event {
        case .connected(let m): handle(.workerConnected(PartialWriteMethod(rawValue: m)))
        case .ready: handle(.workerReady)
        case .error(let msg): handle(.workerError(msg))
        }
    }

    /// 卸載。一般卸載遇到「使用中」會失敗並回到 mounted；force 會強制卸載，必要時結束 worker。
    func unmount(force: Bool) async {
        switch state {
        case .mounting:
            transition(to: .unmounting)
            process?.terminate()
        case .mounted:
            transition(to: .unmounting)
            let (ok, out) = await MountTable.unmount(mountPoint, force: force)
            guard !ok, state == .unmounting else { return }   // 成功：等 worker 結束事件
            if force {
                process?.terminate()
                try? await Task.sleep(for: .seconds(3))
                if let p = process, p.isRunning { kill(p.processIdentifier, SIGKILL) }
            } else {
                state = .mounted
                notice = out.isEmpty ? "The volume is in use." : out
            }
        default:
            break
        }
    }

    /// 等到 worker 結束（或逾時）。用於結束 app 前。
    /// 以短間隔檢查而非 continuation：逾時後不會留下懸置的等待者。
    func waitUntilStopped(timeout: Duration) async {
        let deadline = ContinuousClock.now + timeout
        while process != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// 主 app 結束時的最後手段：同步送出 SIGTERM。
    func terminateWorker() {
        process?.terminate()
    }
}

/// 把 pipe 的位元組流切成行（readabilityHandler 可能在行中間切斷）。
/// 只在該 FileHandle 的序列佇列上被呼叫，無並行存取。
private final class LineSplitter: @unchecked Sendable {
    private var buffer = Data()
    private let onLine: @Sendable (String) -> Void

    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<nl], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...nl)
            onLine(line)
        }
    }
}
