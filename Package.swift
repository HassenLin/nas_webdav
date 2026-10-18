// swift-tools-version: 6.0
import PackageDescription

// NAS Bridge：把 NAS／雲端儲存（WebDAV、FTP／FTPS、SFTP、pCloud）以 macFUSE 掛載成本機磁碟，常駐選單列。
//
// 與 SmartphoneFileManager 相同：用 SwiftPM 而不手寫 .xcodeproj，以檔案系統為準；
// app bundle 外殼由 `tools/make-app.sh` 補上。Xcode 直接 `open Package.swift` 即可編輯與除錯。
//
// 分層：
//   L0 CFuseShim     — libfuse 2.x 高階 API 的最小 ABI 宣告（只有標頭）。
//                      libfuse 不在建置時連結，而是執行期 dlopen：未安裝 macFUSE 也能建置與啟動，
//                      app 會顯示安裝導引；也讓 FUSE-T 可作為替代後端。
//   L1 NASBridgeCore — 各協定的 RemoteStore（WebDAV、lftp、pCloud）、通用 POSIX 檔案系統語意、FUSE 橋接、
//                      worker 子行程、掛載狀態機。零 UI 相依，可 swift test。
//   L4 NASBridge     — SwiftUI 選單列 app（MenuBarExtra + 連線管理視窗），唯一有 UI 相依的地方。
//
// 同一個執行檔兼任兩種角色（見 Sources/NASBridge/main.swift）：
//   - 無參數：選單列 app
//   - `--fuse-worker`：單一掛載的 FUSE worker（每個掛載一個子行程 → 多實例互不影響、崩潰隔離）
let package = Package(
    name: "NASBridge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NASBridgeCore", targets: ["NASBridgeCore"]),
        .executable(name: "NASBridge", targets: ["NASBridge"]),
    ],
    targets: [
        .target(name: "CFuseShim"),
        .target(name: "NASBridgeCore", dependencies: ["CFuseShim"]),
        .testTarget(name: "NASBridgeCoreTests", dependencies: ["NASBridgeCore"]),
        .executableTarget(name: "NASBridge", dependencies: ["NASBridgeCore"]),
    ]
)
