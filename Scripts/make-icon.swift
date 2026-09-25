import AppKit

// 生成 App 图标：渐变圆角方块 + bolt.fill
let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func makeIcon(size s: CGFloat, name: String) {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let corner = s * 0.225

    // 阴影
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 0.04
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.02)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)

    // 渐变背景
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.25, green: 0.47, blue: 0.98, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.78, blue: 0.72, alpha: 1),
    ])!
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    shadow.set()
    gradient.draw(in: bgPath, angle: -70)

    // 顶部高光
    let highlight = NSBezierPath(roundedRect: NSRect(x: s*0.08, y: s*0.55, width: s*0.84, height: s*0.37), xRadius: s*0.18, yRadius: s*0.18)
    NSColor.white.withAlphaComponent(0.14).setFill()
    highlight.fill()

    // bolt 符号（模板绘制 + sourceAtop 染成白色）
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .bold)
    if let base = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil),
       let symbol = base.withSymbolConfiguration(config) {
        let sz = symbol.size
        let scale = min((s * 0.62) / sz.width, (s * 0.62) / sz.height)
        let drawSize = NSSize(width: sz.width * scale, height: sz.height * scale)
        let drawRect = NSRect(x: (s - drawSize.width) / 2, y: (s - drawSize.height) / 2, width: drawSize.width, height: drawSize.height)

        let tinted = NSImage(size: NSSize(width: s, height: s))
        tinted.lockFocus()
        symbol.isTemplate = true
        symbol.draw(in: drawRect)
        NSColor.white.set()
        NSRect(x: 0, y: 0, width: s, height: s).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: 0, y: 0, width: s, height: s))
    }

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try? png.write(to: url)
}

let specs: [(CGFloat, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]
for (size, name) in specs {
    makeIcon(size: size, name: name)
}
print("iconset written to \(outDir)")
