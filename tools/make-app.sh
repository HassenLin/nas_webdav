#!/bin/bash
# 把 SwiftPM 產出的執行檔組成 .app bundle（沿用 SmartphoneFileManager 的做法）。
#
# 專案以 SwiftPM 管理（不手寫 .xcodeproj），缺的只有 app bundle 外殼，這支腳本補上：
#   - Info.plist（LSUIElement：只在選單列，不出現在 Dock）
#   - 多語系字串（Localization/*.lproj → Contents/Resources/）
#   - 圖示（tools/AppIcon.icns）
#   - ad-hoc 簽章
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

# 本機自簽（ad-hoc）。不上架，Developer ID 等真的要散佈時再說。
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo "已組出 $APP"
