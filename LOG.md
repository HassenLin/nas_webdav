# LOG

- 2026-10-19｜**修正：pCloud 顯示「已登入」但連線回登入失敗**：「已登入」只看鑰匙圈有沒有 token，從不確認 token 是否仍有效；
  實際存的是 10/18 早期版本取得、已失效的 token（登出、過期、改密碼都會讓它失效）。
  帳號編輯器開啟時以 `userinfo` 實際驗證（`PCloudLogin.validate`），狀態分為 未登入／檢查中／已登入／登入已失效／無法確認（連不上）；
  掛載或測試連線遇到 token 類錯誤（1000／2000／2094／2095）時，訊息改為「pCloud 登入已失效，請編輯帳號重新登入」。

- 2026-10-19｜**pCloud 上傳／下載：套用 SmartphoneFileManager 踩到的雷**
  - 雷 1：`uploadfile` 回應的 `metadata` 是**陣列**（其他方法是物件），只接受物件時成功的上傳被當成「unexpected response」——
    掛載後每次存檔都會回 EIO。`Envelope` 改為兩種都接受、其他欄位寬鬆解碼；解碼失敗時附上回應開頭以利診斷。
  - 雷 2：單一 `uploadfile` 傳大檔常逾時或中途斷線整份重來。大於 32 MiB 改用上傳工作階段
    （`upload_create`／`upload_write`／`upload_info`／`upload_save`，官方文件未列、官方 Swift SDK 使用），每段 32 MiB；
    斷線時等 1／3／10 秒，以 `upload_info` 查伺服器已收到的位置接著寫。工作階段在存檔前不出現在資料夾，失敗不留殘缺檔。
    與該專案的差別：不把工作階段 ID 存檔跨重開續傳（來源是 FUSE handle 的暫存檔，關檔失敗就不存在了）。錯誤碼 2067（工作階段不存在）→ ENOENT。
  - 雷 3：下載連結數小時後失效 → Range 讀被拒時換新連結重試一次；整檔下載改為 8 MiB 分區塊、區塊就地重試，不丟已下載的部分。
  - pCloud 掛載的 `daemon_timeout` 由 120 改為 600 秒（大檔上傳含重試在關檔的單一 FUSE 請求內完成）。
  - `swift build` 零警告；`swift test` 47 項通過（新增：陣列 metadata、工作階段回應、暫時性錯誤分類）。待實機驗收：pCloud 分段上傳。

- 2026-10-18｜**pCloud 改為帳號密碼登入，移除 OAuth**
  - OAuth 需要到 pCloud 註冊 app（Client ID／secret）並等待審核，不值得；改為 email＋密碼登入（`PCloudLogin`，對齊 SmartphoneFileManager）：
    `getdigest` → `passworddigest = sha1(密碼 + sha1(小寫 email) + digest)` → `userinfo?getauth=1`（POST 本文，密碼不送出）。
  - 兩步驟驗證：2297 時編輯器顯示驗證碼欄位 → `tfa_login`。地區自動偵測（先試設定的區，失敗再試另一區）。
  - 套用 SmartphoneFileManager 實機踩到的雷（該專案已以歐洲帳號＋兩步驟驗證實機驗證）：
    - 要用 `login` 方法（不是 `userinfo`）並帶 `os=6`／`device`／固定 `deviceid`（主機名稱雜湊），否則開了 2FA 的帳號不回 2297；
      `tfa_login` 同樣帶裝置參數＋`trustdevice=1`，之後此 Mac 不必再輸入驗證碼（官方文件未記載）。
    - 在錯的資料中心登入回 2321（This user is on another location）→ 自動改試另一區；兩區都失敗時優先回報帳密錯誤。
    - 輸入驗證碼後按 Return 會觸發「儲存」關閉表單、驗證狀態遺失 → 輸入密碼／驗證碼時 Return 改對應「登入」／「驗證」。
  - 鑰匙圈只存 auth token（`pcloud.com`＋email 為鍵）；請求以 `auth=` 參數送出；刪除帳號時 `logout` 讓 token 失效。
  - 移除 `PCloudOAuth`、Client ID／secret 設定（`AppConfig.pcloudClientID`、鑰匙圈 client secret）；舊 config.json 多出的鍵會被忽略。
  - `swift test` 44 項通過（含密碼摘要公式與 Python hashlib 比對；實機測試預設略過）；對真實 pCloud 伺服器驗證請求格式（不存在的帳號兩區皆回 2000）；實際帳號待驗證。

- 2026-10-18｜**FTP／FTPS／SFTP 改用續傳機制做 offset 讀寫（FUSE driver 層）**
  - 讀：`get1 --source-region`（FTP `REST`＋`RETR`、SFTP offset），4 MiB 區塊，不再開檔整檔下載；區段跨過檔尾時接受 lftp 已寫入的部分。
  - 寫：新增寫入方式 `PartialWriteMethod.append`：`put -c` 從遠端大小接續（FTP `REST`＋`STOR`、SFTP offset），本機以稀疏檔只送新段；
    送出後比對大小。`RemoteFileSystem` 遇到非檔尾寫入時把 handle 單向轉為本機暫存檔（`convertToLocal`）。
  - 掛載時以探測檔實測（"ABCD" → 接續 "EF" → 讀 [1,3)），不支援的伺服器退回整檔；唯讀掛載假設 REST 讀可用。
  - `RemoteStore.readChunkSize`（預設 1 MiB，lftp 4 MiB）。
  - 測試 42 項通過（FakeStore 模擬「只能接在檔尾」）；實機 FTP／FTPS／SFTP 皆探測為 Range 讀＋接續寫並通過；
    FUSE 實掛 FTP：20 MiB 拷貝為 5 次 4 MiB 接續 STOR、讀中段只傳該區塊、改寫轉本機內容正確。

- 2026-10-18｜**新增 FTP／FTPS／SFTP、pCloud；固定憑證簽章；README 參考來源**
  - 架構：`WebDAVFileSystem` 一般化為 `RemoteFileSystem`（POSIX 語意只寫一次），協定差異降到 `RemoteStore` 契約
    （能力旗標：Range 讀、部分寫入、rename 是否覆蓋）；`RemoteStoreFactory` 為協定 → 實作的唯一對應，worker 與「測試連線」共用。
  - WebDAV：`WebDAVStore` 薄轉接層（行為不變）。
  - FTP／FTPS（explicit／implicit、被動／主動）、SFTP（密碼／私鑰）：移植 SmartphoneFileManager 的 lftp 指令組裝與列表解析，
    改為**常駐 lftp 行程＋3 條連線池**；FTPS 限 TLS 1.2、上傳後比對大小；可信任自簽憑證指紋；SFTP 主機金鑰 TOFU（app 專用 known_hosts）。
    修正：掛載根原本不實際連線就回報成功，改以 `cd` 驗證（實機測試時發現）。
  - pCloud（美國／歐洲）：同步 JSON API、`getfilelink`＋Range 讀、整檔上傳、帳號配額；OAuth2 loopback 登入（移植）。
  - 模型：`Account` 加 `protocol` 與協定專屬欄位（舊 config.json 逐欄相容讀取）；鑰匙圈鍵含協定，pCloud token 以帳號 id 為鍵；
    `AppConfig.pcloudClientID`；`WorkerConfig.password` → `credential`。
  - UI：帳號編輯器協定切換與各協定欄位、pCloud 登入與 app 設定、純 FTP 未加密警告；帳號表格加「協定」「伺服器」欄。
  - `make-app.sh`：優先以鑰匙圈裡有效的 Apple Development 憑證簽章（`NB_SIGN_IDENTITY`／`NB_SIGN_TEAM`），找不到才 ad-hoc，
    鑰匙圈「允許」同意一次即持續有效。`install.sh` 加選用的 lftp。
  - 多語系：補 37 筆繁中；簡中轉換補「伺服器／登入／憑證／金鑰」用語（順帶修正既有的「伺服器網址」「登入時啟動」）。
  - README 新增「參考來源」（miquels/webdavfs、SmartphoneFileManager、macFUSE、lftp、pCloud API）。
  - 測試 41 項通過（新增 FakeStore 四種能力組合、lftp、pCloud、模型相容）；實機 FTP／FTPS／SFTP 通過、FTP 實際 FUSE 掛載讀寫正常；
    pCloud 實機待驗證。

- 2026-10-17｜**修正：無法上傳檔案**
  - 原因：掛載選項 `noapplexattr` 讓核心以 EPERM 拒絕 `com.apple.*` 延伸屬性，而 macOS 新檔案幾乎都帶
    `com.apple.provenance`，Finder／cp 拷貝因寫不進屬性而失敗（資料本身其實已寫入）。
  - 修正：移除 `noapplexattr`；實作 setxattr/getxattr/listxattr/removexattr，屬性存在 worker 記憶體
    （`VolatileXattrStore`，支援 XATTR_CREATE/REPLACE 與資源分支 position，單值上限 1 MiB；刪除／改名同步處理）。
  - CFuseShim.h 補上 Darwin 版 xattr 函式指標；`check-fuse-abi.sh` 對 macFUSE 5.4.0 標頭 29 項一致。
  - 實機：cp／ditto 上傳 3 MB 檔（含延伸屬性）成功、內容一致；測試 23 項通過。

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
