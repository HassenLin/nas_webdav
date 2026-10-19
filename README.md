# NAS Bridge（macOS）

把 **NAS／雲端儲存**（WebDAV、FTP／FTPS、SFTP、pCloud）透過 **macFUSE** 掛載成本機磁碟的選單列 app，以 **Swift 6 + SwiftUI** 撰寫。
專案形式沿用 SmartphoneFileManager：SwiftPM 套件 + `tools/make-app.sh`（Xcode 直接 `open Package.swift`）。

- **來源 repo／設計參考**：[miquels/webdavfs](https://github.com/miquels/webdavfs)（WebDAV FUSE，Go）；其他見文末[參考來源](#參考來源)
- **部署目標**：macOS 14+（開發機 macOS 27 / Xcode 27 / Swift 6.4）
- **協定**：WebDAV（僅 HTTPS）、FTP（純 FTP／FTPS explicit／FTPS implicit；被動／主動）、SFTP（密碼或私鑰）、
  pCloud（email＋密碼登入、支援兩步驟驗證，美國／歐洲資料中心自動偵測；不需註冊 pCloud app）
- **相依**：macFUSE（`brew install --cask macfuse`；建置不需要，執行期 dlopen libfuse）；FUSE-T 為實驗性替代；
  FTP／FTPS／SFTP 需 lftp（`brew install lftp`，選用）
- **安全**：WebDAV 只允許 `https://`、可釘選伺服器憑證 SHA-256；FTPS 可信任指定的自簽憑證指紋；SFTP 主機金鑰首次連線記住；
  純 FTP 允許但標示「未加密」警告；密碼／token 存登入鑰匙圈
- **多實例**：可同時掛載多個 NAS／多個共用資料夾，**每個掛載一個 worker 子行程**（互不影響、崩潰隔離）
- **發佈**：自用、App Sandbox 關閉；簽章優先用鑰匙圈裡的 Apple Development 憑證（重新 build 不必再允許鑰匙圈存取），找不到才 ad-hoc；**語系**：English／繁體中文／简体中文（跟隨系統語言）

## 功能

| 區塊 | 說明 |
|---|---|
| 選單列（tray） | 圖示反映整體狀態（未掛載／已掛載／有錯誤）；每個掛載一個子選單：狀態、掛載／卸載／強制卸載、在 Finder 開啟、編輯；全部掛載／卸載、掛載…、帳號…、登入時啟動、結束（先卸載全部） |
| 帳號管理 | 「帳號」分頁：表格列出 名稱／協定（未加密標示警告）／伺服器／帳號／密碼／使用中掛載數；密碼存登入鑰匙圈（網際網路密碼，以伺服器＋埠＋協定＋帳號為鍵，可沿用 Finder 已存的密碼），預設遮罩、按眼睛圖示顯示；pCloud 顯示實際登入狀態（向 pCloud 確認 token；失效時顯示「請重新登入」）。編輯表單：協定切換、WebDAV 憑證釘選、FTP 加密與主動／被動、SFTP 私鑰、pCloud email＋密碼登入（兩步驟驗證碼、地區自動偵測；token 與密碼存鑰匙圈，token 失效時自動重新登入）、**測試連線**（WebDAV／FTPS 憑證不受信任時可一鍵「信任此憑證」）；使用中的帳號不可刪除 |
| 掛載管理 | 「掛載」分頁：清單＋編輯器：帳號（可直接新增帳號）、遠端路徑、名稱、掛載點（預設 `~/Volumes/<名稱>`）、唯讀、啟動時自動掛載；測試（含寫入方式探測）、掛載／卸載、刪除。一個帳號可有多個掛載 |
| macFUSE 安裝對話框 | 啟動時未偵測到 macFUSE、或要掛載時缺少就自動跳出：**下載並安裝**（GitHub 官方 dmg → 校驗碼比對 → 取出 pkg → 檢查 Developer ID 簽章與作者 Team ID → 開啟「安裝程式」）或**以 Homebrew 安裝**（開終端機執行）；每 2 秒自動偵測，裝好後顯示後續步驟（允許系統延伸、重新開機） |
| 讀取 | 不先下載整檔：WebDAV／pCloud 以 HTTP Range（1 MiB 區塊快取，[webdavfs](https://github.com/miquels/webdavfs) 做法）；FTP／FTPS 以 `REST`＋`RETR`、SFTP 從 offset 讀（lftp `get1 --source-region`，4 MiB 區塊）。伺服器不支援時才整檔下載 |
| 寫入 | 掛載時以隱藏探測檔**實際試寫**：WebDAV 支援部分寫入（Apache `PUT Content-Range`／SabreDAV `PATCH`）就直接寫遠端；FTP／FTPS（`REST`＋`STOR`）、SFTP（offset）為**檔尾接續寫**（續傳機制，lftp `put -c`），循序寫入（拷貝進來的檔案）直接送遠端、改寫既有內容時該 handle 當場轉本機暫存檔。連續寫入合併到 4 MiB 才送出；不支援（及 pCloud）退回「本機暫存檔＋關檔時整檔上傳」（pCloud 大於 32 MiB 分段上傳、斷線從已收到處接著寫）；FTP／SFTP 每次送出後比對大小 |
| 檔案操作 | 建立、刪除、改名（覆蓋目的檔，同 POSIX）、mkdir、rmdir（非空目錄回 ENOTEMPTY）、truncate、statfs（WebDAV RFC 4331 配額、pCloud 帳號配額） |
| FTP／SFTP 連線 | 每個掛載 3 條常駐 lftp 連線（連線池），只登入一次、閒置斷線自動重連；大檔傳輸只佔一條 |
| 延伸屬性 | Finder／cp 拷貝時的 `com.apple.*` 等屬性暫存於記憶體（不寫到 NAS，卸載後消失），讓拷貝不因屬性失敗 |
| 快取 | 屬性／目錄列表 5 秒 TTL、不存在 2 秒負向快取；本機變更即時失效 |

## 安裝

```bash
./tools/install.sh            # 檢查需求、詢問是否安裝 macFUSE、測試、組 app、安裝到 /Applications
```

詳見 [`INSTALL.md`](INSTALL.md)。

## 開發

```bash
swift test                                            # 單元測試
NB_LIVE_URL=https://host:9001/public NB_LIVE_USER=… NB_LIVE_PASS=… swift test --filter LiveWebDAV   # 實機 WebDAV
NB_LIVE_LFTP="ftp://u:p@host:21 ftpes://u:p@host:21 sftp://u@host:22/path#~/.ssh/key" \
  swift test --filter LiveLftp                       # 實機 FTP／FTPS／SFTP（FTPS 自簽憑證指紋：NB_LIVE_FTPS_FP）
NB_LIVE_MACFUSE=1 swift test --filter MacFUSEInstaller   # 實際下載 macFUSE、驗證校驗碼與簽章（不安裝）
./tools/check-fuse-abi.sh                             # macFUSE 升版後：比對 CFuseShim.h 與真實標頭 ABI
./tools/make-app.sh && open .build/NASBridge.app
open Package.swift                                    # Xcode 開發／除錯
```

## 目錄結構

```
Package.swift                 SwiftPM（L0 CFuseShim + L1 NASBridgeCore + L4 App + 測試）
Sources/CFuseShim/            L0：libfuse 2.x 高階 API 的最小 ABI 宣告（只有標頭，執行期 dlopen）
Sources/NASBridgeCore/        L1：零 UI 相依，可 swift test
  Model/                      Account（協定＋伺服器＋帳號＋協定專屬選項）、MountProfile（帳號＋遠端路徑→掛載點）、
                              ConfigStore（JSON）、KeychainStore（網際網路密碼／pCloud token）
  FS/                         POSIXFileSystem（FUSE 唯一依賴的抽象）、RemoteFileSystem（通用 POSIX 語意：快取、開檔策略、
                              寫入合併、rename 覆蓋、截斷）、OpenFile、MetadataCache
  Remote/                     RemoteStore（各協定的最小操作契約＋能力旗標）、RemoteStoreFactory（協定 → 實作的唯一對應）
  WebDAV/                     WebDAVClient（同步 API、部分寫入探測）、WebDAVStore、MultistatusParser、TLSTrustDelegate（釘選）、
                              DAVError（errno，各協定共用）
  Lftp/                       LftpStore（FTP／FTPS／SFTP，連線池）、LftpSession（常駐 lftp 行程）、LftpCommand、LftpListingParser
  PCloud/                     PCloudStore（同步 JSON API、Range 讀）、PCloudLogin（密碼摘要登入、兩步驟驗證、登出）
  Fuse/                       FuseLibrary（dlopen macFUSE／FUSE-T）、FuseHost（C callback 膠水）、VolatileXattrStore
  Worker/                     WorkerProtocol（stdin 設定、stdout 事件行）、WorkerMain（子行程進入點）
  Mount/                      MountInstance（FSM＋worker 管理）、MountManager（協調者）、ConnectionTester、MountTable
  Setup/                      MacFUSEInstaller（下載／驗證／開啟安裝程式、Homebrew）
Sources/NASBridge/            L4：SwiftUI 選單列 app
  main.swift                  依 --fuse-worker 分流：worker 或 app
  App/                        NASBridgeApp（MenuBarExtra、AppDelegate、WindowOpener）、MenuBarMenu
  Main/                       MainWindow（掛載／帳號分頁）、MainWindowState（導覽狀態）
  Mounts/                     MountsView、MountEditor
  Accounts/                   AccountsView（表格）、AccountEditor（表單）
  Setup/                      MacFUSEDialog（安裝對話框）
Tests/NASBridgeCoreTests/     Swift Testing（含預設略過的實機測試）
Localization/                 *.lproj（tools/gen-strings.py 產生）
tools/                        install.sh、make-app.sh、make-icon.swift、AppIcon.icns、check-fuse-abi.sh、
                              xcode-env.sh、gen-strings.py、hant2hans.swift、zh-Hant.json、zh-Hans.overrides.json
```

## 狀態

- `swift build` 零警告（Swift 6 嚴格併發）；`swift test` 41/41（含記憶體 FakeStore 對四種能力組合跑同一套 POSIX 情境）；WebDAV 實機測試待提供帳密。
- FTP／FTPS／SFTP 實機（本機 pyftpdlib、自簽 FTPS、使用者層級 sshd 私鑰登入）：`LiveLftp` 全部通過，三者皆探測為「Range 讀＋檔尾接續寫」；
  worker 實際 FUSE 掛載 FTP：`cp` 20 MiB 為 5 次 4 MiB 接續 STOR（不整檔重傳）、`dd` 讀中段只 REST＋RETR 該區塊、
  改寫 1 byte 轉本機後內容正確；中文資料夾、含空白改名、xattr、卸載皆正常。
- pCloud：單元測試（密碼摘要公式、URL 編碼、錯誤碼）通過；對真實 pCloud 伺服器以不存在的帳號驗證登入請求格式（兩區皆回 2000）；
  **實際帳號登入與掛載待驗證**（`NB_LIVE_PCLOUD="email:密碼" swift test --filter LivePCloud`）。
- app 可組出並啟動；未安裝 macFUSE 時啟動即自動跳出安裝對話框。
- macFUSE 5.4.0 實機：`check-fuse-abi.sh` 29 項一致；掛載 `https://www.hassen.myds.me:9001/public` 後瀏覽、刪除、`cp`／`ditto` 上傳（含延伸屬性）、改名皆正常。
- **待驗證**：Finder 拖放上傳大檔、WebDAV 實機測試套件（`--filter LiveWebDAV`）、pCloud 實機掛載（含大於 32 MiB 分段上傳）、新帳號編輯畫面的實際操作。

設計取捨見 [`BACKGROUND.md`](BACKGROUND.md)，更動紀錄見 [`LOG.md`](LOG.md)。

## 參考來源

| 來源 | 用途 |
|---|---|
| [miquels/webdavfs](https://github.com/miquels/webdavfs) | WebDAV FUSE 檔案系統（Go、Linux）：Range 讀不落地、部分寫入（`PUT Content-Range`／SabreDAV `PATCH`）、寫入合併的設計參考 |
| SmartphoneFileManager（同作者，本機 `~/works/SmartphoneFileManager`） | 專案形式（SwiftPM＋`make-app.sh`、gen-strings 多語系）；FTP／SFTP（lftp）、pCloud（REST、帳號密碼登入）的移植來源 |
| [macFUSE](https://github.com/macfuse/macfuse)／[FUSE-T](https://www.fuse-t.org) | FUSE 後端（libfuse 2.x 高階 API，執行期 dlopen） |
| [lftp](https://lftp.yar.ru) | FTP／FTPS／SFTP 協定實作（外部工具） |
| [pCloud API](https://docs.pcloud.com) | pCloud HTTP JSON API 與帳號密碼（digest）登入 |
