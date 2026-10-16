# 背景與設計取捨

目標：在 macOS 上把 Synology NAS 的 WebDAV 共用資料夾當成本機磁碟使用（Finder、任何 app 都能直接開檔），
常駐選單列、可同時連多台 NAS。macOS 內建的 Finder「連接伺服器」WebDAV 慢且不穩，也不支援自簽憑證釘選。
設計參考 [miquels/webdavfs](https://github.com/miquels/webdavfs)（Go、Linux FUSE）。

| 取捨 | 選擇 | 理由 |
|---|---|---|
| 專案格式 | SwiftPM + `make-app.sh` | 與 SmartphoneFileManager 一致；以檔案系統為準，Xcode 可直接開 `Package.swift` |
| 分層 | L0 CFuseShim／L1 Core（無 UI）／L4 App | WebDAV 解析、路徑編碼、狀態機等易錯處可單元測試 |
| libfuse 連結 | 手寫最小 ABI 標頭＋執行期 `dlopen` | 未裝 macFUSE 也能建置與啟動（顯示安裝導引）；FUSE-T 可作替代。代價是 ABI 由人維護 → `tools/check-fuse-abi.sh` 對照真實標頭 |
| FUSE API 版本 | libfuse 2（高階 API，FUSE_USE_VERSION 26） | ABI 穩定、macFUSE 與 FUSE-T 皆提供。macFUSE 免 kext 的 FSKit 後端只支援 libfuse3（`-o backend=fskit`），日後可另寫 libfuse3 shim |
| 多實例 | 每個掛載一個 worker 子行程（同一執行檔 `--fuse-worker`） | `fuse_main` 處理訊號、全域狀態，一行程一掛載最單純；一個掛載卡住或崩潰不影響其他掛載與 UI |
| 帳號與掛載分離 | `Account`（伺服器＋帳號＋鑰匙圈密碼）與 `MountProfile`（帳號＋遠端路徑→掛載點） | 同一台 NAS 常掛多個共用資料夾，帳密只需維護一份；被使用中的帳號不可刪，避免懸空參照 |
| 鑰匙圈項目 | 網際網路密碼（伺服器＋埠＋https＋帳號為鍵） | 「鑰匙圈存取」以伺服器顯示、可沿用 Finder 已存的密碼；改網址或帳號時自動搬移 |
| macFUSE 安裝 | app 內下載官方 dmg → `.sha256` 比對 → `pkgutil --check-signature` 限定作者 Team ID `3T5GSNBU6W` → 交給「安裝程式」 | 一鍵完成又不需要 app 取得 root；校驗碼防傳輸損毀，Team ID 防 release 被換成他人簽章的套件 |
| Homebrew 途徑 | 產生 `.command` 用「終端機」開啟 | 不需「自動化」權限；brew 自己會要求管理者密碼 |
| 密碼傳遞 | 主 app 讀鑰匙圈 → stdin JSON 給 worker | 參數／環境變數會被 `ps` 看到；worker 不碰鑰匙圈也就不會跳第二次授權 |
| worker 生命週期 | stdout 事件行（CONNECTED／READY／ERROR）；行程結束＝已卸載 | 協定極簡、無需 XPC；worker 監看父行程，app 當掉時自行卸載 |
| 掛載狀態 | `MountInstance` FSM：停留 unmounted／mounted／failed，過渡 mounting／unmounting | 所有轉移集中在 `handle(_:)`，未定義的事件明確忽略並記錄 |
| 讀取 | Range GET＋1 MiB 區塊快取 | 不落地，大檔隨開即讀；核心循序讀時請求數少 |
| 寫入 | **實測**部分寫入能力，不支援時退回暫存檔整檔上傳 | webdavfs 在不支援時降為唯讀；但若伺服器忽略 Content-Range，`PUT` 會把整檔覆寫成片段——所以只在探測檔上試，不信標頭宣稱 |
| 寫入合併 | 連續寫入累積至 4 MiB 才送出 | 核心以 64 KiB～1 MiB 為單位 write，逐次送 HTTP 會極慢 |
| 屬性快取 | 5 秒 TTL＋2 秒負向快取 | Finder 會大量 getattr 與探測不存在的檔案；代價是他人變更最多延遲 5 秒 |
| 權限／時間戳 | 固定 0755／0644、擁有者為目前使用者；chmod/chown/utimens 回報成功但不動作 | WebDAV 無此概念；回錯誤會讓 cp／Finder 拷貝失敗 |
| AppleDouble | `noappledouble`、`noapplexattr` | 不在 NAS 上留下 `._*` 垃圾檔 |
| 認證 | 預先帶 Basic header（僅 HTTPS），Digest 由 URLSession challenge 處理 | Synology 為 Basic；省去每個請求的 401 往返 |
| 憑證 | 系統信任鏈，或釘選葉憑證 SHA-256 | Synology 常用自簽憑證；釘選比「忽略憑證錯誤」安全 |
| 掛載點 | 預設 `~/Volumes/<名稱>` | 一般使用者無權在 `/Volumes` 建立資料夾 |
| 單一 app 實例 | 同 bundle id 已在執行就啟用它並結束自己 | 兩個 app 同管一批掛載點會互相干擾 |
| UI 字串 | 英文為鍵，繁中人工翻譯、簡中自動轉換 | 沿用 SmartphoneFileManager 的 gen-strings 工具 |
