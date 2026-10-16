# NAS Bridge（macOS）

把 **Synology NAS 的 WebDAV（HTTPS）** 透過 **macFUSE** 掛載成本機磁碟的選單列 app，以 **Swift 6 + SwiftUI** 撰寫。
專案形式沿用 SmartphoneFileManager：SwiftPM 套件 + `tools/make-app.sh`（Xcode 直接 `open Package.swift`）。

- **部署目標**：macOS 14+（開發機 macOS 27 / Xcode 27 / Swift 6.4）
- **相依**：macFUSE（`brew install --cask macfuse`；建置不需要，執行期 dlopen libfuse）；FUSE-T 為實驗性替代
- **安全**：只允許 `https://`；帳密存登入鑰匙圈；可釘選伺服器憑證 SHA-256（自簽憑證用）
- **多實例**：可同時掛載多個 NAS／多個共用資料夾，**每個掛載一個 worker 子行程**（互不影響、崩潰隔離）
- **發佈**：自用、ad-hoc 簽章、App Sandbox 關閉；**語系**：English／繁體中文／简体中文（跟隨系統語言）

## 功能

| 區塊 | 說明 |
|---|---|
| 選單列（tray） | 圖示反映整體狀態（未掛載／已掛載／有錯誤）；每個連線一個子選單：狀態、掛載／卸載／強制卸載、在 Finder 開啟、編輯；全部掛載／卸載、登入時啟動、結束（先卸載全部） |
| 連線管理視窗 | 清單＋編輯器：名稱、伺服器網址、遠端路徑、帳號、密碼（鑰匙圈）、掛載點（預設 `~/Volumes/<名稱>`）、唯讀、啟動時自動掛載、釘選憑證；**測試連線**（認證、可用空間、寫入方式；憑證不受信任時可一鍵「信任此憑證」） |
| 讀取 | HTTP Range GET，1 MiB 區塊快取，不先下載整檔（webdavfs 做法） |
| 寫入 | 掛載時以隱藏探測檔**實際試寫**：支援部分寫入（Apache `PUT Content-Range`／SabreDAV `PATCH`）就直接寫遠端（連續寫入合併到 4 MiB 才送出）；不支援則退回「本機暫存檔＋關檔時整檔 PUT」 |
| 檔案操作 | 建立、刪除、改名（MOVE）、mkdir、rmdir（非空目錄回 ENOTEMPTY）、truncate、statfs（RFC 4331 配額） |
| 快取 | 屬性／目錄列表 5 秒 TTL、不存在 2 秒負向快取；本機變更即時失效 |
| 安裝導引 | 未偵測到 macFUSE 時選單顯示「尚未安裝 macFUSE…」，開啟步驟與一鍵拷貝指令 |

## 安裝

```bash
./tools/install.sh            # 檢查需求、詢問是否安裝 macFUSE、測試、組 app、安裝到 /Applications
```

詳見 [`INSTALL.md`](INSTALL.md)。

## 開發

```bash
swift test                                            # 單元測試
NB_LIVE_URL=https://host:9001/public NB_LIVE_USER=… NB_LIVE_PASS=… swift test --filter Live   # 實機 WebDAV
./tools/check-fuse-abi.sh                             # macFUSE 升版後：比對 CFuseShim.h 與真實標頭 ABI
./tools/make-app.sh && open .build/NASBridge.app
open Package.swift                                    # Xcode 開發／除錯
```

## 目錄結構

```
Package.swift                 SwiftPM（L0 CFuseShim + L1 NASBridgeCore + L4 App + 測試）
Sources/CFuseShim/            L0：libfuse 2.x 高階 API 的最小 ABI 宣告（只有標頭，執行期 dlopen）
Sources/NASBridgeCore/        L1：零 UI 相依，可 swift test
  Model/                      MountProfile（設定＋驗證）、ProfileStore（JSON）、KeychainStore
  WebDAV/                     WebDAVClient（同步 API、部分寫入探測）、MultistatusParser、TLSTrustDelegate（釘選）、DAVError（errno）
  FS/                         POSIXFileSystem（FUSE 唯一依賴的抽象）、WebDAVFileSystem、OpenFile、MetadataCache
  Fuse/                       FuseLibrary（dlopen macFUSE／FUSE-T）、FuseHost（C callback 膠水）
  Worker/                     WorkerProtocol（stdin 設定、stdout 事件行）、WorkerMain（子行程進入點）
  Mount/                      MountInstance（FSM＋worker 管理）、MountManager（協調者）、ConnectionTester、MountTable
Sources/NASBridge/            L4：SwiftUI 選單列 app
  main.swift                  依 --fuse-worker 分流：worker 或 app
  App/                        NASBridgeApp（MenuBarExtra、AppDelegate）、MenuBarMenu
  Connections/                ConnectionsView、ProfileEditor
  Setup/                      SetupGuideView（macFUSE 安裝導引）
Tests/NASBridgeCoreTests/     Swift Testing（含預設略過的實機測試）
Localization/                 *.lproj（tools/gen-strings.py 產生）
tools/                        install.sh、make-app.sh、make-icon.swift、AppIcon.icns、check-fuse-abi.sh、
                              xcode-env.sh、gen-strings.py、hant2hans.swift、zh-Hant.json、zh-Hans.overrides.json
```

## 狀態

- `swift build` 零警告（Swift 6 嚴格併發）；`swift test` 13/13（實機測試待提供帳密）。
- app 可組出並啟動（選單列、首次啟動開啟連線視窗）。
- **待驗證**：macFUSE 安裝後的實際掛載、`check-fuse-abi.sh`、對 `https://www.hassen.myds.me:9001/public` 的實機測試。

設計取捨見 [`BACKGROUND.md`](BACKGROUND.md)，更動紀錄見 [`LOG.md`](LOG.md)。
