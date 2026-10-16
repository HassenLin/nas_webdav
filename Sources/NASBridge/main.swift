import NASBridgeCore

// 同一個執行檔兼任兩種角色：
//   `--fuse-worker`：單一掛載的 FUSE worker 子行程（由 MountInstance 啟動，不顯示任何 UI）
//   其他：選單列 app
// 必須在 NSApplication 初始化之前分流，worker 才不會出現在 Dock 或連上 WindowServer。
if CommandLine.arguments.contains(WorkerProtocol.flag) {
    WorkerMain.run()
} else {
    NASBridgeApp.main()
}
