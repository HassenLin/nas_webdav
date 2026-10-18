# 背景與設計取捨

目標：在 macOS 上把 Synology NAS 的 WebDAV 共用資料夾（以及 FTP／FTPS、SFTP、pCloud）當成本機磁碟使用
（Finder、任何 app 都能直接開檔），常駐選單列、可同時連多台 NAS。macOS 內建的 Finder「連接伺服器」WebDAV 慢且不穩，也不支援自簽憑證釘選。
設計參考 [miquels/webdavfs](https://github.com/miquels/webdavfs)（Go、Linux FUSE）。

| 取捨 | 選擇 | 理由 |
|---|---|---|
| 專案格式 | SwiftPM + `make-app.sh` | 與 SmartphoneFileManager 一致；以檔案系統為準，Xcode 可直接開 `Package.swift` |
| 分層 | L0 CFuseShim／L1 Core（無 UI）／L4 App | WebDAV 解析、路徑編碼、狀態機等易錯處可單元測試 |
| libfuse 連結 | 手寫最小 ABI 標頭＋執行期 `dlopen` | 未裝 macFUSE 也能建置與啟動（顯示安裝導引）；FUSE-T 可作替代。代價是 ABI 由人維護 → `tools/check-fuse-abi.sh` 對照真實標頭 |
| FUSE API 版本 | libfuse 2（高階 API，FUSE_USE_VERSION 26） | ABI 穩定、macFUSE 與 FUSE-T 皆提供。macFUSE 免 kext 的 FSKit 後端只支援 libfuse3（`-o backend=fskit`），日後可另寫 libfuse3 shim |
| 協定抽象 | `POSIXFileSystem`（FUSE 介面）→ 唯一實作 `RemoteFileSystem`（POSIX 語意）→ `RemoteStore`（各協定最小操作＋能力旗標：Range 讀、部分寫入、rename 是否覆蓋） | POSIX 語意（快取、開檔策略、寫入合併、rmdir 非空檢查、rename 覆蓋、截斷）只寫一次；協定實作只做「一個操作＝一次遠端請求」的翻譯，以記憶體 FakeStore 就能測完四種能力組合。原 `WebDAVFileSystem` 改名一般化，WebDAV 邏輯降到 `WebDAVStore` 薄轉接層 |
| FTP／FTPS／SFTP | lftp 外部工具（`brew install lftp`），**常駐行程＋連線池（3 條）**；指令以 `<指令> && echo 標記OK \|\| echo 標記ERR` 判斷完成 | 一個工具涵蓋 FTP 主動／被動、FTPS explicit／implicit、SFTP 密碼／金鑰；SmartphoneFileManager 每操作一個 `lftp -c` 行程要重新登入 0.1～1 秒，FUSE 的 getattr 量下 Finder 會卡，所以改常駐。lftp 自己的目錄快取關閉（多條 session 會互相看到舊資料），統一由 MetadataCache 管 |
| FTP／SFTP 讀寫 | 用續傳的協定機制：讀＝`get1 --source-region`（FTP `REST`＋`RETR`、讀到區段尾關資料連線；SFTP offset 讀），寫＝`put -c` 檔尾接續（FTP `REST <遠端大小>`＋`STOR`；SFTP offset 寫，本機以稀疏檔只送新的一段）；掛載時以探測檔實測，不支援才退回整檔；每次送出後比對大小；`daemon_timeout` 600 秒 | 與 SmartphoneFileManager 的續傳（`get -c`／`put -c`）同一套機制，搬到 FUSE driver 層：大檔隨開即讀、拷貝進來不必整檔落地。FTP 只能從遠端檔尾接續（REST＋STOR 改寫中段的行為各伺服器不一），所以改寫既有內容時該 handle 單向轉本機暫存檔。伺服器忽略 REST 時 STOR 會覆寫成片段 → 只在探測檔上試、送出後驗大小。lftp＋OpenSSL 3 的 TLS 1.3 資料通道上傳會截斷檔尾（SmartphoneFileManager 實測）→ FTPS 以 `OPENSSL_CONF` 限 TLS 1.2。Range 讀區塊 4 MiB：每次 RETR 要開資料連線，固定成本高 |
| FTPS 自簽憑證 | 只信任使用者確認過的指紋（`ssl:verify-certificate/<指紋> no`） | 比「整個關掉驗證」安全；與 WebDAV 的憑證釘選同一個 UI 流程（測試連線 →「信任此憑證」） |
| SFTP 主機金鑰 | 首次連線記住（`StrictHostKeyChecking=accept-new`），存在 app 自己的 `known_hosts` | TOFU；不動使用者的 `~/.ssh/known_hosts` |
| 純 FTP | 允許，清單與編輯器顯示「未加密」警告 | 許多舊 NAS 只有純 FTP；WebDAV 維持只允許 HTTPS（Basic 認證明文外洩風險且 NAS 都支援 HTTPS） |
| pCloud | HTTP JSON API（同步、路徑定址）、`getfilelink`＋Range 讀（連結快取 10 分鐘）、`uploadfile` 整檔上傳；OAuth2 loopback（`127.0.0.1:53682`），token 存鑰匙圈 | 不需第三方 SDK；美國／歐洲 API host 不同，換 token 以回呼帶回的 hostname 為準（只接受兩個官方 host）；redirect URI 與 SmartphoneFileManager 相同，可共用同一個 pCloud app |
| rename 覆蓋 | `renameReplacesTarget == false` 的協定（SFTP、pCloud、FTP）先刪目的檔再改名 | Finder／編輯器「安全存檔」依賴 POSIX rename 覆蓋；非原子，中間失敗會留下「目的檔已刪」 |
| 簽章 | 優先用鑰匙圈裡有效的 Apple Development 憑證，找不到才 ad-hoc；不加 Hardened Runtime | 鑰匙圈存取權限綁在簽章上：ad-hoc 每次 build cdhash 不同、每次都要重新「允許」；固定憑證則同意一次永久有效。Hardened Runtime 的 library validation 會拒絕 dlopen 他人簽章的 libfuse |
| 多實例 | 每個掛載一個 worker 子行程（同一執行檔 `--fuse-worker`） | `fuse_main` 處理訊號、全域狀態，一行程一掛載最單純；一個掛載卡住或崩潰不影響其他掛載與 UI |
| 帳號與掛載分離 | `Account`（伺服器＋帳號＋鑰匙圈密碼）與 `MountProfile`（帳號＋遠端路徑→掛載點） | 同一台 NAS 常掛多個共用資料夾，帳密只需維護一份；被使用中的帳號不可刪，避免懸空參照 |
| 鑰匙圈項目 | 網際網路密碼（伺服器＋埠＋協定（HTTPS／FTP／FTPS／SSH）＋帳號為鍵）；pCloud token 為一般密碼（帳號 id 為鍵） | 「鑰匙圈存取」以伺服器顯示、可沿用 Finder 已存的密碼；改網址或帳號時自動搬移 |
| macFUSE 安裝 | app 內下載官方 dmg → `.sha256` 比對 → `pkgutil --check-signature` 限定作者 Team ID `3T5GSNBU6W` → 交給「安裝程式」 | 一鍵完成又不需要 app 取得 root；校驗碼防傳輸損毀，Team ID 防 release 被換成他人簽章的套件 |
| Homebrew 途徑 | 產生 `.command` 用「終端機」開啟 | 不需「自動化」權限；brew 自己會要求管理者密碼 |
| 密碼傳遞 | 主 app 讀鑰匙圈 → stdin JSON 給 worker（密碼或 pCloud token；lftp 再經環境變數 `LFTP_PASSWORD`） | 參數／環境變數會被 `ps` 看到；worker 不碰鑰匙圈也就不會跳第二次授權 |
| worker 生命週期 | stdout 事件行（CONNECTED／READY／ERROR）；行程結束＝已卸載 | 協定極簡、無需 XPC；worker 監看父行程，app 當掉時自行卸載 |
| 掛載狀態 | `MountInstance` FSM：停留 unmounted／mounted／failed，過渡 mounting／unmounting | 所有轉移集中在 `handle(_:)`，未定義的事件明確忽略並記錄 |
| 讀取 | Range GET＋1 MiB 區塊快取 | 不落地，大檔隨開即讀；核心循序讀時請求數少 |
| 寫入 | **實測**部分寫入能力，不支援時退回暫存檔整檔上傳 | webdavfs 在不支援時降為唯讀；但若伺服器忽略 Content-Range，`PUT` 會把整檔覆寫成片段——所以只在探測檔上試，不信標頭宣稱 |
| 寫入合併 | 連續寫入累積至 4 MiB 才送出 | 核心以 64 KiB～1 MiB 為單位 write，逐次送 HTTP 會極慢 |
| 屬性快取 | 5 秒 TTL＋2 秒負向快取 | Finder 會大量 getattr 與探測不存在的檔案；代價是他人變更最多延遲 5 秒 |
| 權限／時間戳 | 固定 0755／0644、擁有者為目前使用者；chmod/chown/utimens 回報成功但不動作 | WebDAV 無此概念；回錯誤會讓 cp／Finder 拷貝失敗 |
| AppleDouble | `noappledouble` | 不在 NAS 上留下 `._*` 垃圾檔 |
| 延伸屬性（xattr） | 存在 worker 記憶體（`VolatileXattrStore`），不寫到 NAS、卸載即消失；**不可**用 `noapplexattr` | macOS 新檔案幾乎都帶 `com.apple.provenance`／`quarantine`；`noapplexattr` 讓核心以 EPERM 拒絕，Finder／cp 拷貝因此整個失敗（實測） |
| 認證 | 預先帶 Basic header（僅 HTTPS），Digest 由 URLSession challenge 處理 | Synology 為 Basic；省去每個請求的 401 往返 |
| 憑證 | 系統信任鏈，或釘選葉憑證 SHA-256 | Synology 常用自簽憑證；釘選比「忽略憑證錯誤」安全 |
| 掛載點 | 預設 `~/Volumes/<名稱>` | 一般使用者無權在 `/Volumes` 建立資料夾 |
| 單一 app 實例 | 同 bundle id 已在執行就啟用它並結束自己 | 兩個 app 同管一批掛載點會互相干擾 |
| UI 字串 | 英文為鍵，繁中人工翻譯、簡中自動轉換 | 沿用 SmartphoneFileManager 的 gen-strings 工具 |
