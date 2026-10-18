#!/bin/bash
# 把 SwiftPM 產出的執行檔組成 .app bundle（沿用 SmartphoneFileManager 的做法）。
#
# 專案以 SwiftPM 管理（不手寫 .xcodeproj），缺的只有 app bundle 外殼，這支腳本補上：
#   - Info.plist（LSUIElement：只在選單列，不出現在 Dock）
#   - 多語系字串（Localization/*.lproj → Contents/Resources/）
#   - 圖示（tools/AppIcon.icns）
#   - 簽章：優先用鑰匙圈裡有效的 Apple Development 憑證（固定身分），找不到才 ad-hoc
#
# 用法：./tools/make-app.sh [debug|release]   產物：.build/NASBridge.app
set -euo pipefail
cd "$(dirname "$0")/.."
# 需要完整 Xcode 的工具鏈（SwiftUI 巨集外掛），見 xcode-env.sh
source tools/xcode-env.sh

CONFIG="${1:-debug}"
APP_NAME="NASBridge"
DISPLAY_NAME="NAS Bridge"
BUNDLE_ID="idv.hassen.nasbridge.mac"
VERSION="1.0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP=".build/${APP_NAME}.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/${APP_NAME}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# 多語系：SwiftUI 的 Text("…") 與 String(localized:) 都查 Bundle.main，
# 所以 .lproj 要放在 app bundle 本身，而不是 SwiftPM 的資源 bundle。
cp -R Localization/*.lproj "$APP/Contents/Resources/"

if [ -f tools/AppIcon.icns ]; then
    cp tools/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
    echo "警告：找不到 tools/AppIcon.icns，這次組出來的 app 沒有圖示" >&2
    echo "      產生方式：swift tools/make-icon.swift" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>zh-Hant</string><string>zh-Hans</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <!-- 選單列 app：不出現在 Dock 與 ⌘Tab -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- 自用工具、不上架，App Sandbox 關閉：要 dlopen macFUSE 的 libfuse、啟動 worker 子行程、
         在使用者指定的資料夾掛載檔案系統，三者在 sandbox 下都會被擋。
         也不啟用 Hardened Runtime：否則 library validation 會拒絕載入他人簽章的 libfuse
         （真要公證散佈時，需加 com.apple.security.cs.disable-library-validation entitlement）。 -->
</dict>
</plist>
PLIST

# 簽章身分：鑰匙圈項目（帳號密碼）的存取權限綁在 app 的簽章上。
# ad-hoc 簽章每次 build 的 cdhash 都不同，macOS 視為另一個 app，每次重 build 都要重新「允許」；
# 用固定的 Apple Development 憑證簽，權限綁在「bundle id＋憑證」上，同意一次就一直有效。
#   NB_SIGN_IDENTITY  指定身分（SHA-1 或名稱；"-"＝強制 ad-hoc）
#   NB_SIGN_TEAM      未指定身分時優先挑這個 team 的憑證（預設 34ZXLE998M），沒有就挑任一有效的
# 不上架、不公證；真的要散佈時再改 Developer ID。
# 不加 --options runtime：Hardened Runtime 的 library validation 會拒絕 dlopen 他人簽章的 libfuse。
pick_identity() {
    # find-identity -v 仍會列出已撤銷的憑證（標 CSSMERR_TP_CERT_REVOKED），要濾掉
    local valid
    valid="$(security find-identity -v -p codesigning 2>/dev/null | grep '"Apple Development:' | grep -v CSSMERR || true)"
    { grep "(${NB_SIGN_TEAM:-34ZXLE998M})\"" <<<"$valid" || true; echo "$valid"; } | awk 'NF && !found { print $2; found = 1 }'   # 不用 exit：提早關管線會 SIGPIPE，pipefail 下整支腳本中止
}
IDENTITY="${NB_SIGN_IDENTITY:-$(pick_identity)}"
IDENTITY="${IDENTITY:--}"
# --timestamp=none：離線也能簽。
if [ "$IDENTITY" != "-" ] && codesign --force --timestamp=none --sign "$IDENTITY" "$APP" >/dev/null 2>&1; then
    echo "簽章：$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
else
    codesign --force --sign - "$APP" >/dev/null 2>&1 || true
    echo "簽章：ad-hoc（找不到可用的 Apple Development 憑證；重新 build 後鑰匙圈會再詢問權限）"
fi

echo "已組出 $APP"
