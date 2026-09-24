// Génère l'icône de l'app (Assets.xcassets) et le fond de la fenêtre du .dmg.
// Usage : swift scripts/make-artwork.swift   (depuis la racine du dépôt)
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

/// Valeur indispensable au script : arrêt avec un message clair si elle manque.
func required<T>(_ value: T?, _ description: String) -> T {
    guard let value else {
        fatalError("Impossible de créer : \(description)")
    }
    return value
}

/// Enceinte + ondes, comme l'icône de la barre des menus, en blanc.
func speakerGlyph(pointSize: CGFloat, color: NSColor) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
    let speaker = required(
        NSImage(systemSymbolName: "hifispeaker.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration),
        "symbole " + "hifispeaker.fill",
    )
    let waves = required(
        NSImage(systemSymbolName: "wave.3.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration),
        "symbole " + "wave.3.right",
    )
    let spacing = pointSize * 0.08
    let size = NSSize(
        width: speaker.size.width + spacing + waves.size.width,
        height: max(speaker.size.height, waves.size.height),
    )
    return NSImage(size: size, flipped: false) { rect in
        speaker.draw(
            in: NSRect(
                x: 0,
                y: (size.height - speaker.size.height) / 2,
                width: speaker.size.width,
                height: speaker.size.height,
            )
        )
        waves.draw(
            in: NSRect(
                x: speaker.size.width + spacing,
                y: (size.height - waves.size.height) / 2,
                width: waves.size.width,
                height: waves.size.height,
            )
        )
        color.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func png(pixels: Int, draw: (CGFloat) -> Void) -> Data {
    let rep = required(
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0,
        ),
        "image bitmap",
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return required(rep.representation(using: .png, properties: [:]), "PNG")
}

// MARK: - Icône de l'app (gabarit macOS : carré arrondi de 824 px dans un canevas de 1024 px)

func drawAppIcon(side: CGFloat) {
    let unit = side / 1024
    let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = 20 * unit
    shadow.shadowOffset = NSSize(width: 0, height: -8 * unit)
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    let tileGradient = required(
        NSGradient(colors: [
            NSColor(red: 0.20, green: 0.45, blue: 1.00, alpha: 1),
            NSColor(red: 0.42, green: 0.22, blue: 0.95, alpha: 1),
        ]),
        "dégradé de l'icône",
    )
    tileGradient.draw(in: shape, angle: -60)

    let glyph = speakerGlyph(pointSize: 400 * unit, color: .white)
    let scale = min(560 * unit / glyph.size.width, 440 * unit / glyph.size.height)
    let size = NSSize(width: glyph.size.width * scale, height: glyph.size.height * scale)
    glyph.draw(
        in: NSRect(
            x: tile.midX - size.width / 2,
            y: tile.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
    )
}

let iconSet = root.appendingPathComponent("Amplo/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try png(pixels: points * scale, draw: drawAppIcon).write(
            to: iconSet.appendingPathComponent(name)
        )
        images.append([
            "filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)",
        ])
    }
}
let info = ["author": "xcode", "version": 1] as [String: Any]
try JSONSerialization.data(
    withJSONObject: ["images": images, "info": info],
    options: [.prettyPrinted, .sortedKeys],
)
.write(to: iconSet.appendingPathComponent("Contents.json"))
try JSONSerialization.data(withJSONObject: ["info": info], options: [.prettyPrinted, .sortedKeys])
    .write(to: root.appendingPathComponent("Amplo/Assets.xcassets/Contents.json"))

// MARK: - Fond du .dmg (600 × 400 points, icônes centrées en (150, 190) et (450, 190) depuis le haut)

let backgroundSize = NSSize(width: 600, height: 400)

func drawBackground(scale: CGFloat) -> Data {
    let rep = required(
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(backgroundSize.width * scale),
            pixelsHigh: Int(backgroundSize.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0,
        ),
        "image bitmap",
    )
    rep.size = backgroundSize
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let backgroundGradient = required(
        NSGradient(
            starting: NSColor(white: 0.99, alpha: 1),
            ending: NSColor(white: 0.92, alpha: 1),
        ),
        "dégradé du fond",
    )
    backgroundGradient.draw(in: NSRect(origin: .zero, size: backgroundSize), angle: -90)

    let centered = NSMutableParagraphStyle()
    centered.alignment = .center
    func text(_ string: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
            .paragraphStyle: centered,
        ]
        (string as NSString).draw(
            in: NSRect(
                x: 20,
                y: backgroundSize.height - y,
                width: backgroundSize.width - 40,
                height: size * 1.6,
            ),
            withAttributes: attributes,
        )
    }
    text(
        "Glissez Amplo dans le dossier Applications",
        y: 70,
        size: 18,
        weight: .semibold,
        color: NSColor(white: 0.15, alpha: 1),
    )

    // Flèche entre les deux icônes (y = 190 depuis le haut).
    let arrowY = backgroundSize.height - 190
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 240, y: arrowY))
    arrow.line(to: NSPoint(x: 350, y: arrowY))
    arrow.move(to: NSPoint(x: 335, y: arrowY + 14))
    arrow.line(to: NSPoint(x: 352, y: arrowY))
    arrow.line(to: NSPoint(x: 335, y: arrowY - 14))
    arrow.lineWidth = 5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    NSColor(red: 0.30, green: 0.35, blue: 0.95, alpha: 0.85).setStroke()
    arrow.stroke()

    text(
        "Premier lancement : si macOS bloque Amplo, ouvrez Réglages Système",
        y: 300,
        size: 12,
        weight: .regular,
        color: NSColor(white: 0.35, alpha: 1),
    )
    text(
        "› Confidentialité et sécurité › « Ouvrir quand même », ou dans le Terminal :",
        y: 319,
        size: 12,
        weight: .regular,
        color: NSColor(white: 0.35, alpha: 1),
    )

    let command = "xattr -dr com.apple.quarantine /Applications/Amplo.app" as NSString
    let commandAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
        .foregroundColor: NSColor(white: 0.15, alpha: 1),
    ]
    let commandSize = command.size(withAttributes: commandAttributes)
    let commandBox = NSRect(
        x: (backgroundSize.width - commandSize.width) / 2 - 10,
        y: backgroundSize.height - 358,
        width: commandSize.width + 20,
        height: commandSize.height + 10,
    )
    NSColor(white: 0.85, alpha: 1).setFill()
    NSBezierPath(roundedRect: commandBox, xRadius: 6, yRadius: 6).fill()
    command.draw(
        at: NSPoint(x: commandBox.minX + 10, y: commandBox.minY + 5),
        withAttributes: commandAttributes,
    )

    NSGraphicsContext.restoreGraphicsState()
    return required(rep.representation(using: .png, properties: [:]), "PNG")
}

let temporary = FileManager.default.temporaryDirectory
let background1x = temporary.appendingPathComponent("dmg-background.png")
let background2x = temporary.appendingPathComponent("dmg-background@2x.png")
try drawBackground(scale: 1).write(to: background1x)
try drawBackground(scale: 2).write(to: background2x)
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = [
    "-cathidpicheck", background1x.path, background2x.path, "-out",
    root.appendingPathComponent("Support/dmg-background.tiff").path,
]
try tiffutil.run()
tiffutil.waitUntilExit()

print("Icône : \(iconSet.path)\nFond du .dmg : Support/dmg-background.tiff")
