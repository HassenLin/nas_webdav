#!/usr/bin/env python3
"""產生 Localization/zh-Hant.lproj 與 zh-Hans.lproj 的 Localizable.strings。

- 繁體中文：人工維護 tools/zh-Hant.json（鍵＝程式碼中的英文字串，與編譯器 -emit-localized-strings 的鍵一致）
- 簡體中文：由 tools/hant2hans.swift 從繁中自動轉換（用語對照＋ICU Hant-Hans），
  個別不滿意的翻譯寫進 tools/zh-Hans.overrides.json 覆寫
- 英文：開發語言，鍵即顯示文字

可加 --check <keys.json> 比對編譯器擷取的鍵，列出尚未翻譯者。
用法：python3 tools/gen-strings.py [--check keys.json]
"""
import json, os, re, subprocess, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
subprocess.run(["swift", os.path.join(root, "tools/hant2hans.swift")], check=True)

# 格式參數：%lld、%@、%2$@…（翻譯若調換順序，必須寫位置編號，否則執行時型別錯位會當機，
# 例如 "%@" 拿到整數被當成物件指標讀取 → EXC_BAD_ACCESS）
SPEC = re.compile(r"%(?:(\d+)\$)?(\.\d+)?(lld|llu|ld|lu|d|u|f|@)")

def specs(s):
    """回傳 [(參數位置, 型別)]；未寫位置編號者依出現順序遞增"""
    out, n = [], 0
    for m in SPEC.finditer(s):
        n += 1
        out.append((int(m.group(1)) if m.group(1) else n, m.group(3)))
    return out

def check_specs(lang, table):
    bad = [k for k, v in table.items() if sorted(specs(k)) != sorted(specs(v))]
    for k in bad:
        print(f"{lang} 格式參數不符：{k!r} → {table[k]!r}", file=sys.stderr)
    if bad:
        sys.exit(1)

def esc(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

for lang in ["zh-Hant", "zh-Hans"]:
    table = json.load(open(os.path.join(root, f"tools/{lang}.json"), encoding="utf-8"))
    check_specs(lang, table)
    out = os.path.join(root, f"Localization/{lang}.lproj/Localizable.strings")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w", encoding="utf-8") as f:
        f.write("/* 由 tools/gen-strings.py 產生，請勿手動修改 */\n")
        for k in sorted(table):
            f.write(f'"{esc(k)}" = "{esc(table[k])}";\n')
    print(f"已產出 {out}（{len(table)} 筆）")

if "--check" in sys.argv:
    table = json.load(open(os.path.join(root, "tools/zh-Hant.json"), encoding="utf-8"))
    keys = json.load(open(sys.argv[sys.argv.index("--check") + 1], encoding="utf-8"))
    missing = [k for k in keys if k and k not in table]
    for k in missing:
        print("未翻譯：", repr(k))
    sys.exit(1 if missing else 0)
