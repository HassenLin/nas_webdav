#!/usr/bin/env swift
import Foundation

// 由 tools/zh-Hant.json（台灣用語）產生 tools/zh-Hans.json（大陸用語、簡體字）。
//
// 兩步：
//   1. 用語對照（台灣 → 大陸），在繁體階段替換，長詞優先避免被短詞拆開
//   2. macOS 內建 ICU 轉換 "Hant-Hans"（字形轉換，零第三方相依）
// 只覆寫自動產生的部分：tools/zh-Hans.overrides.json 裡的鍵以人工翻譯為準。
//
// 用法：swift tools/hant2hans.swift   （tools/gen-strings.py 會自動呼叫）

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let hantURL = root.appendingPathComponent("zh-Hant.json")
let hansURL = root.appendingPathComponent("zh-Hans.json")
let overridesURL = root.appendingPathComponent("zh-Hans.overrides.json")

/// 台灣 → 大陸用語。順序無關：套用前依長度由長到短排序。
let terms: [String: String] = [
    "磁碟": "磁盤", "偵測": "檢測", "鑰匙圈": "鑰匙串", "釘選": "固定",
    "個人專屬資料夾": "个人文件夹", "資料夾": "文件夾", "檔案分享": "文件共享", "檔案": "文件", "檔名": "文件名",
    "執行檔": "可執行文件", "裝置": "設備", "設定": "設置", "預設": "默認", "螢幕": "屏幕", "網路": "網絡", "連線": "連接",
    "執行": "運行", "視窗": "窗口", "選單": "菜單", "貼上": "粘貼", "剪下": "剪切", "拷貝": "拷貝",
    "重新整理": "刷新", "匯出": "導出", "匯入": "導入", "支援": "支持", "訊息": "信息", "資訊": "信息",
    "存取": "訪問", "解除安裝": "卸載", "儲存空間": "存儲空間", "儲存": "保存", "記憶體": "內存",
    "位元率": "碼率", "使用者": "用戶", "下載項目": "下載", "垃圾桶": "廢紙簍", "檢視": "查看",
    "隱私權與安全性": "隱私與安全性", "隱私權": "隱私", "取代": "替換", "尋找": "查找", "重新開機": "重啟",
    "偵錯": "調試", "終端機": "終端", "字元": "字符", "遞迴": "遞歸", "唯讀": "只讀", "影像": "圖像",
    "套件名稱": "包名", "套件": "包", "已充飽": "已充滿", "停用": "禁用", "目的資料夾": "目標文件夾",
    "目的地": "目標位置", "目的項目": "目標項目", "版本號碼": "版本號", "開發人員選項": "開發者選項",
    "一律允許這部電腦": "始終允許使用這台計算機進行調試", "這部電腦": "這台電腦", "密碼": "密碼",
    "輔助說明": "幫助", "安裝導引": "安裝向導", "導引": "向導", "雲碟": "雲盤",
    "解壓縮": "解壓", "壓縮": "壓縮", "發佈頁面": "發布頁面", "發佈": "發布", "篩選": "篩選",
    "建置": "構建", "專案": "項目", "原始碼": "源代碼", "程式": "程序", "物件": "對象",
    "指令": "命令", "非預期": "意外", "逾時": "超時", "權限": "權限", "列出": "列出",
    "常用位置": "常用位置", "起始資料夾": "起始文件夾", "隱藏檔": "隱藏文件", "本機": "本地",
    "貼到": "粘貼到", "存成": "保存為", "目前": "當前", "請見": "請參閱", "螢幕鏡像": "投屏", "鏡像": "投屏",
    "介面": "界面", "游標": "光標", "行數": "行數", "編碼": "編碼", "上傳": "上傳",
]

/// 單次掃描、最長詞優先：已替換的文字不再被其他規則處理
/// （逐條 replacingOccurrences 會連鎖：執行檔→可執行文件 之後又被 執行→運行 改壞）
let sortedTerms = terms.sorted { $0.key.count > $1.key.count }

func convert(_ text: String) -> String {
    var result = ""
    var rest = Substring(text)
    while !rest.isEmpty {
        if let (from, to) = sortedTerms.first(where: { rest.hasPrefix($0.key) }) {
            result += to
            rest = rest.dropFirst(from.count)
        } else {
            result.append(rest.removeFirst())
        }
    }
    // 大陸慣用彎引號，台灣慣用「」
    result = result.replacingOccurrences(of: "「", with: "“").replacingOccurrences(of: "」", with: "”")
        .replacingOccurrences(of: "『", with: "‘").replacingOccurrences(of: "』", with: "’")
    return result.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? result
}

let hant = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: hantURL))
let overrides = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: overridesURL))) ?? [:]
var hans: [String: String] = [:]
for (key, value) in hant { hans[key] = overrides[key] ?? convert(value) }

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(hans).write(to: hansURL)
print("已產出 \(hansURL.path)（\(hans.count) 筆，人工覆寫 \(overrides.count) 筆）")
