# LOG

- 2026-10-17｜**初版**
  - SwiftPM 分層：L0 CFuseShim（libfuse 2.x 最小 ABI，執行期 dlopen）、L1 NASBridgeCore、L4 SwiftUI 選單列 app。
  - WebDAV：PROPFIND／Range GET／PUT／MOVE／MKCOL／DELETE；僅 HTTPS；憑證釘選；鑰匙圈存密碼。
  - 寫入策略：探測部分寫入（Content-Range／SabreDAV PATCH），不支援時暫存檔整檔上傳（參考 miquels/webdavfs 並補上退路）。
  - 多實例：每個掛載一個 worker 子行程；`MountInstance` FSM 管理；app 結束或當掉時自動卸載。
  - tray 選單、連線管理視窗（測試連線、信任憑證）、macFUSE 安裝導引、登入時啟動。
  - tools：install.sh、make-app.sh、make-icon.swift、check-fuse-abi.sh、gen-strings（沿用 SmartphoneFileManager）。
  - 測試 13 項通過；實機掛載待 macFUSE 安裝後驗證。
