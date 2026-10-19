# 安裝與建置

需求：macOS 14+、**完整的 Xcode**（Swift 6；只有 Command Line Tools 時 SwiftUI 巨集外掛不存在，`tools/xcode-env.sh` 會自動改用已安裝的 Xcode）。

## macFUSE（掛載必要）

```bash
brew install --cask macfuse      # 安裝程式會要求管理者密碼
```

1. 「系統設定 → 隱私權與安全性」允許「Benjamin Fleischer」的系統軟體，重新開機。
2. Apple 晶片：須先進入復原模式 →「啟動安全性工具程式」→「降低安全性」並勾選允許使用者管理核心延伸。
3. 驗證：`ls /usr/local/lib/libfuse.2.dylib`，再執行 `./tools/check-fuse-abi.sh` 確認 ABI 相容。

替代（免核心延伸，實驗性）：`brew install --cask macos-fuse-t/cask/fuse-t`。

## lftp（FTP／FTPS／SFTP 帳號需要，選用）

```bash
brew install lftp
```

只用 WebDAV、pCloud 可不裝。app 會找 `/opt/homebrew/bin`、`/usr/local/bin` 與 PATH。

## pCloud

不需註冊 pCloud app：帳號 → 新增 → 協定選 pCloud → 填 email、密碼 →「登入」。
密碼只以一次性摘要送出換取登入 token，鑰匙圈只存 token；帳號開了兩步驟驗證時會再要驗證碼。
地區（美國／歐洲）自動偵測。

## 一鍵安裝（建議）

```bash
./tools/install.sh                 # 缺 macFUSE／lftp 時詢問是否安裝
./tools/install.sh --yes           # 直接安裝 macFUSE、不詢問
./tools/install.sh --no-deps --skip-tests --dest ~/Applications
```

腳本會：檢查 macOS／Xcode 工具鏈 → macFUSE → lftp（選用） → `swift test` → `make-app.sh release` →
安裝為 `/Applications/NAS Bridge.app`（無權限時改 `~/Applications`）。

## 手動

```bash
./tools/make-app.sh release        # 產物：.build/NASBridge.app
```

- 簽章：`make-app.sh` 自動挑鑰匙圈裡有效的 **Apple Development** 憑證（優先 team `34ZXLE998M`），找不到才 ad-hoc。
  固定身分下，鑰匙圈（WebDAV／FTP／SFTP 密碼、pCloud token）的「允許」同意一次就一直有效；ad-hoc 每次 build
  cdhash 都不同，重 build 後會再詢問。可用 `NB_SIGN_IDENTITY=<SHA-1 或名稱>`（`-`＝強制 ad-hoc）、
  `NB_SIGN_TEAM=<Team ID>` 指定。不加 Hardened Runtime（會擋 dlopen 他人簽章的 libfuse）。
- 首次開啟若被 Gatekeeper 擋：右鍵 → 打開。
- Synology 端：「套件中心」安裝 **WebDAV Server**，啟用 HTTPS（預設埠 5006），帳號需有該共用資料夾權限；
  FTP／SFTP：「控制台 → 檔案服務 → FTP」啟用 FTPS（explicit）或 SFTP。
- 新增/修改 UI 字串後：在 `tools/zh-Hant.json` 補繁中翻譯，執行 `python3 tools/gen-strings.py`。
  擷取全部鍵：`swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <dir>`，
  再以 `--check <keys.json>` 檢查缺漏。
