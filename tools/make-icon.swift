#!/usr/bin/env swift
import AppKit

// 產生 NAS Bridge app 圖示（tools/AppIcon.icns）。
//
// 自己用 Core Graphics 畫，不用 SF Symbols——Apple 授權禁止把那些符號用在
// app icon 上。圖形：藍色斜向漸層底 + 白色 NAS 機身（兩個硬碟槽，各帶綠色
// LED）+ 機身上方一朵雲，意指「把 NAS 經網路（WebDAV）接到本機」。
// 線條與色塊刻意粗大，16px 下仍可辨識。
//
// 重跑：swift tools/make-icon.swift && ./tools/make-app.sh

/// macOS 圖示實際圖形約佔畫布 80%，四周留白（Apple HIG 的比例）
let inset = 0.098

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    ctx.setShouldAntialias(true)

    let pad = size * inset
    let box = CGRect(x: pad, y: pad, width: size - pad * 2, height: size - pad * 2)
    let w = box.width

    /// 以 box 左下角為原點、寬度 w 為單位長度的矩形（座標 y 向上）
    func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> CGRect {
        CGRect(x: box.minX + w * x, y: box.minY + w * y, width: w * width, height: w * height)
    }
    func fillRounded(_ r: CGRect, radius: CGFloat, color: CGColor) {
        ctx.setFillColor(color)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    // ── 底：圓角方形 + 斜向漸層（#3B82F6 左上 → #1E3A8A 右下）────
    let radius = w * 0.224
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 1).cgColor,
        NSColor(srgbRed: 0x1E / 255, green: 0x3A / 255, blue: 0x8A / 255, alpha: 1).cgColor,
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: CGPoint(x: box.minX, y: box.maxY),
                               end: CGPoint(x: box.maxX, y: box.minY), options: [])
    }
    ctx.restoreGState()

    let white = NSColor(srgbRed: 0xFA / 255, green: 0xFA / 255, blue: 0xF7 / 255, alpha: 1).cgColor
    let ink = NSColor(srgbRed: 0x1E / 255, green: 0x3A / 255, blue: 0x8A / 255, alpha: 1).cgColor
    let green = NSColor(srgbRed: 0x34 / 255, green: 0xD3 / 255, blue: 0x99 / 255, alpha: 1).cgColor

    // ── 機身：寬 0.56、高 0.40，置中略偏下 ───────────────────────
    fillRounded(rect(0.22, 0.12, 0.56, 0.40), radius: w * 0.05, color: white)

    // ── 兩個並排硬碟槽，右下角各一顆綠色 LED ─────────────────────
    // 機身內縮 0.04、槽距 0.04 → 每槽寬 0.22
    for slotX in [0.26, 0.52] {
        let bay = rect(slotX, 0.16, 0.22, 0.32)
        fillRounded(bay, radius: w * 0.03, color: ink)
        let led = w * 0.026
        ctx.setFillColor(green)
        ctx.fillEllipse(in: CGRect(x: bay.maxX - w * 0.05 - led, y: bay.minY + w * 0.03,
                                   width: led * 2, height: led * 2))
    }

    // ── 機身上方：雲朵（三個圓 + 圓角底板聯集），表示網路連線 ────
    ctx.setFillColor(white)
    for (cx, cy, r) in [(0.39, 0.655, 0.075), (0.50, 0.715, 0.105), (0.615, 0.665, 0.085)] {
        ctx.fillEllipse(in: rect(cx - r, cy - r, r * 2, r * 2))
    }
    fillRounded(rect(0.33, 0.58, 0.34, 0.09), radius: w * 0.045, color: white)

    image.unlockFocus()
    return image
}

// ── 輸出 iconset 並打包成 .icns ───────────────────────────────
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

/// iconutil 只認這組固定檔名；512@2x（1024）一定要有，Finder 大圖預覽才不會糊
let entries: [(size: Int, name: String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]

for (size, name) in entries {
    let image = drawIcon(size: CGFloat(size))
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("產不出 \(name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil 失敗\n".utf8))
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)   // iconset 只是中繼產物
print("已產出 \(root.appendingPathComponent("AppIcon.icns").path)")
