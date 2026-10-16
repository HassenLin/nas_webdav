# 確保以完整 Xcode 的工具鏈建置（由 make-app.sh、install.sh 以 source 載入）。
#
# 背景：新版 SDK 的 SwiftUI 把 @State 等屬性包裝改以巨集實作，巨集外掛（libSwiftUIMacros.dylib）
# 只隨 Xcode 提供；xcode-select 指向 Command Line Tools 時編譯會失敗：
#   external macro implementation type 'SwiftUIMacros.StateMacro' could not be found ...
#   plugin for module 'SwiftUIMacros' not found
# 處理：已指定 DEVELOPER_DIR 時尊重之；xcode-select 不是指向某個 Xcode.app 時，找到 Xcode 就只對這次建置
# 設定 DEVELOPER_DIR（不需 sudo、不改系統設定），找不到則說明需要安裝 Xcode。
if [ -z "${DEVELOPER_DIR:-}" ]; then
    _nb_active="$(xcode-select -p 2>/dev/null || true)"
    case "$_nb_active" in
        *.app/Contents/Developer) ;;   # 已指向 Xcode
        *)
            _nb_xcode=""
            if [ -d /Applications/Xcode.app ]; then
                _nb_xcode=/Applications/Xcode.app
            else
                _nb_xcode="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null | head -1)"
            fi
            if [ -n "$_nb_xcode" ]; then
                export DEVELOPER_DIR="$_nb_xcode/Contents/Developer"
                echo "使用 Xcode 工具鏈：${DEVELOPER_DIR}（xcode-select 目前指向 ${_nb_active:-（未設定）}）" >&2
            else
                echo "錯誤：需要完整的 Xcode（App Store 安裝）。只有 Command Line Tools 無法建置：" >&2
                echo "      SwiftUI 的巨集外掛只隨 Xcode 提供。安裝後可執行：" >&2
                echo "      sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
                exit 1
            fi
            ;;
    esac
    unset _nb_active _nb_xcode
fi
