# LOG

- 2026-10-17｜**帳號管理與 macFUSE 安裝對話框**
  - 模型拆分：`Account`（網址／帳號／鑰匙圈密碼／憑證釘選）與 `MountProfile`（帳號＋遠端路徑→掛載點）；設定檔改為 `config.json`（舊 `profiles.json` 不再讀取）。
  - 鑰匙圈改用網際網路密碼（伺服器＋埠＋帳號）；改網址或帳號時搬移密碼；使用中的帳號不可刪除。
  - 主視窗改為「掛載」「帳號」兩個分頁；帳號表格可顯示／隱藏密碼、測試連線、信任憑證；掛載編輯器可直接新增帳號。
  - macFUSE 安裝對話框：啟動時或掛載時缺少即自動開啟；下載官方 dmg 並驗證校驗碼與 Developer ID 簽章（限定 Team ID）後開啟安裝程式，或以 Homebrew 安裝；自動偵測安裝完成。
  - 測試 20 項通過（含實際下載 macFUSE 5.4.0 驗證）。

- 2026-10-17｜**初版**
  - SwiftPM 分層：L0 CFuseShim（libfuse 2.x 最小 ABI，執行期 dlopen）、L1 NASBridgeCore、L4 SwiftUI 選單列 app。
  - WebDAV：PROPFIND／Range GET／PUT／MOVE／MKCOL／DELETE；僅 HTTPS；憑證釘選；鑰匙圈存密碼。
  - 寫入策略：探測部分寫入（Content-Range／SabreDAV PATCH），不支援時暫存檔整檔上傳（參考 miquels/webdavfs 並補上退路）。
  - 多實例：每個掛載一個 worker 子行程；`MountInstance` FSM 管理；app 結束或當掉時自動卸載。
  - tray 選單、連線管理視窗（測試連線、信任憑證）、macFUSE 安裝導引、登入時啟動。
  - tools：install.sh、make-app.sh、make-icon.swift、check-fuse-abi.sh、gen-strings（沿用 SmartphoneFileManager）。
  - 測試 13 項通過；實機掛載待 macFUSE 安裝後驗證。
