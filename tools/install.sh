#!/bin/bash
# 在另一台 Mac 上從原始碼安裝 NAS Bridge。
#
# 做的事（依序）：
#   1. 檢查 macOS 版本（14+）與完整 Xcode 的 Swift toolchain（只有 Command Line Tools 不行，見 xcode-env.sh）
#   2. 必要相依：macFUSE（Homebrew cask；安裝程式會要求管理者密碼，之後需在系統設定允許系統延伸並重新開機）
#   3. 跑核心層單元測試（可略過）
#   4. 以 release 組出 .app，安裝到 /Applications（無寫入權限時改 ~/Applications）
#
# 用法：
#   ./tools/install.sh                 互動詢問是否安裝 macFUSE
#   ./tools/install.sh --yes           缺 macFUSE 時直接安裝、不詢問
#   ./tools/install.sh --no-deps       不安裝相依（app 內有安裝導引）
#   ./tools/install.sh --skip-tests    略過單元測試
#   ./tools/install.sh --dest DIR      指定安裝資料夾
set -euo pipefail
cd "$(dirname "$0")/.."

ASSUME_YES=0
NO_DEPS=0
SKIP_TESTS=0
DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --yes|-y) ASSUME_YES=1 ;;
        --no-deps) NO_DEPS=1 ;;
        --skip-tests) SKIP_TESTS=1 ;;
        --dest) DEST="$2"; shift ;;
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "未知參數：$1" >&2; exit 2 ;;
    esac
    shift
done

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告：\033[0m%s\n' "$*" >&2; }
die()  { printf '\033[1;31m錯誤：\033[0m%s\n' "$*" >&2; exit 1; }

ask() {   # ask "問題" → 0=是 1=否
    [ "$NO_DEPS" = 1 ] && return 1
    [ "$ASSUME_YES" = 1 ] && return 0
    read -r -p "$1 [Y/n] " reply
    [[ -z "$reply" || "$reply" =~ ^[Yy] ]]
}

# ── 1. 系統需求 ─────────────────────────────────────────────
info "檢查系統需求"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "需要 macOS 14 以上（目前 $(sw_vers -productVersion)）"

source tools/xcode-env.sh
command -v swift >/dev/null 2>&1 || die "找不到 Swift toolchain，請安裝 Xcode（App Store）"
swift_version=$(swift --version 2>/dev/null | head -1)
info "Swift：$swift_version"
echo "$swift_version" | grep -Eq 'Swift version (6|[7-9])\.' || die "需要 Swift 6 以上（請更新 Xcode）"

# ── 2. macFUSE ─────────────────────────────────────────────
# 建置不需要 macFUSE（libfuse 於執行期 dlopen），但掛載需要
if [ -e /usr/local/lib/libfuse.2.dylib ] || [ -e /usr/local/lib/libfuse-t.dylib ]; then
    info "FUSE 已安裝"
elif command -v brew >/dev/null 2>&1 && ask "安裝 macFUSE（掛載需要；會要求管理者密碼）？"; then
    brew install --cask macfuse
    warn "請到「系統設定 → 隱私權與安全性」允許 Benjamin Fleischer 的系統軟體，然後重新開機。"
    warn "Apple 晶片需先在復原模式的「啟動安全性工具程式」開啟「降低安全性」以允許核心延伸。"
else
    warn "未安裝 macFUSE：app 可啟動，但無法掛載；app 選單有安裝導引。https://macfuse.github.io"
fi

# ── 3. 測試 ────────────────────────────────────────────────
if [ "$SKIP_TESTS" = 0 ]; then
    info "執行單元測試"
    swift test 2>&1 | tail -3
fi

# ── 4. 組 app 並安裝 ────────────────────────────────────────
info "建置 release 版"
./tools/make-app.sh release
APP=".build/NASBridge.app"

if [ -z "$DEST" ]; then
    if [ -w /Applications ]; then DEST="/Applications"; else DEST="$HOME/Applications"; fi
fi
mkdir -p "$DEST"
TARGET="$DEST/NAS Bridge.app"

# 正在執行的舊版先結束（它會先卸載所有掛載），否則複製會失敗或執行到舊檔
if pgrep -f "NAS Bridge.app/Contents/MacOS/NASBridge$" >/dev/null 2>&1; then
    osascript -e 'tell application id "idv.hassen.nasbridge.mac" to quit' 2>/dev/null || true
    sleep 3
fi
rm -rf "$TARGET"
cp -R "$APP" "$TARGET"
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

info "已安裝：$TARGET"
cat <<MSG

完成。第一次使用：
  • 從選單列的磁碟圖示開啟「Connections…」，新增 Synology WebDAV 連線（https://<NAS>:5006）
  • 預設掛載到 ~/Volumes/<名稱>，可在 Finder 側邊欄看到
  • 想開機自動啟動：選單列 → Launch at Login

啟動：open "$TARGET"
MSG
