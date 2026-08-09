// Generator ikony aplikacji.
//
// Rysuje kafelek w kształcie zbliżonym do systemowego (superelipsa) z gradientem
// i napisem „KSEF", po czym zapisuje komplet rozmiarów wymaganych przez `iconutil`.
//
// Uruchamiane przez `scripts/make-icon.sh`; wynik (`Resources/AppIcon.icns`)
// jest wersjonowany, więc zwykły build nie musi go odtwarzać.

import AppKit
import CoreGraphics
import Foundation

let canvas = 1024.0
/// Marginesy zgodne z siatką ikon macOS — kafelek zajmuje 824 z 1024 punktów.
let inset = 100.0
let tile = canvas - 2 * inset

/// Ścieżka superelipsy — daje „miękki" narożnik charakterystyczny dla ikon macOS,
/// wyraźnie łagodniejszy niż zwykły zaokrąglony prostokąt.
func squircle(in rect: CGRect, exponent: Double = 5.0) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2
    let b = rect.height / 2
    let cx = rect.midX
    let cy = rect.midY
    let steps = 720

    for step in 0 ... steps {
        let theta = Double(step) / Double(steps) * 2 * Double.pi
        let cosT = cos(theta)
        let sinT = sin(theta)
        // Postać parametryczna superelipsy: znak zachowuje ćwiartkę, potęga kształtuje narożnik.
        let x = cx + a * pow(abs(cosT), 2 / exponent) * (cosT < 0 ? -1 : 1)
        let y = cy + b * pow(abs(sinT), 2 / exponent) * (sinT < 0 ? -1 : 1)
        if step == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

func drawIcon(size: Double) -> NSBitmapImageRep? {
    let scale = size / canvas
    guard let context = CGContext(
        data: nil,
        width: Int(size),
        height: Int(size),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    context.scaleBy(x: scale, y: scale)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    let tileRect = CGRect(x: inset, y: inset, width: tile, height: tile)
    let shape = squircle(in: tileRect)

    // Delikatny cień pod kafelkiem, jak w ikonach systemowych.
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012),
                      blur: canvas * 0.03,
                      color: CGColor(gray: 0, alpha: 0.28))
    context.addPath(shape)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // Gradient w granatach — kolorystyka urzędowo-finansowa, dobrze czytelna w obu motywach.
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let colors = [
        CGColor(srgbRed: 0.192, green: 0.416, blue: 0.729, alpha: 1),
        CGColor(srgbRed: 0.086, green: 0.216, blue: 0.451, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: tileRect.minX, y: tileRect.maxY),
                                   end: CGPoint(x: tileRect.maxX, y: tileRect.minY),
                                   options: [])
    }

    // Rozjaśnienie górnej krawędzi — sugeruje wypukłość kafelka.
    if let sheen = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [
                                  CGColor(gray: 1, alpha: 0.22),
                                  CGColor(gray: 1, alpha: 0.0),
                              ] as CFArray,
                              locations: [0, 1]) {
        context.drawLinearGradient(sheen,
                                   start: CGPoint(x: tileRect.midX, y: tileRect.maxY),
                                   end: CGPoint(x: tileRect.midX, y: tileRect.midY),
                                   options: [])
    }
    context.restoreGState()

    // Napis „KSEF" — dobrany tak, by wypełniał szerokość kafelka z zapasem na marginesy.
    let text = "KSEF"
    let targetWidth = tile * 0.76
    var fontSize = tile * 0.34
    var attributes: [NSAttributedString.Key: Any] = [:]

    for _ in 0 ..< 24 {
        attributes = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .black),
            .foregroundColor: NSColor.white,
            .kern: fontSize * 0.02,
        ]
        let width = NSAttributedString(string: text, attributes: attributes).size().width
        if abs(width - targetWidth) < 1 { break }
        fontSize *= targetWidth / max(width, 1)
    }

    let attributed = NSAttributedString(string: text, attributes: attributes)
    let textSize = attributed.size()

    let graphicsContext = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext

    // Napis nieco powyżej środka — pod nim zostaje miejsce na kreskę.
    let textOrigin = CGPoint(x: tileRect.midX - textSize.width / 2,
                             y: tileRect.midY - textSize.height / 2 + tile * 0.055)
    attributed.draw(at: textOrigin)

    NSGraphicsContext.restoreGraphicsState()

    // Kreska pod napisem — nawiązanie do linii podsumowania na fakturze.
    let ruleWidth = textSize.width * 0.92
    let ruleHeight = tile * 0.028
    let ruleRect = CGRect(x: tileRect.midX - ruleWidth / 2,
                          y: textOrigin.y - tile * 0.075,
                          width: ruleWidth,
                          height: ruleHeight)
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
    context.addPath(CGPath(roundedRect: ruleRect,
                           cornerWidth: ruleHeight / 2,
                           cornerHeight: ruleHeight / 2,
                           transform: nil))
    context.fillPath()

    guard let image = context.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image)
}

// Komplet rozmiarów wymaganych przez katalog `.iconset`.
let variants: [(name: String, size: Double)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for variant in variants {
    guard let rep = drawIcon(size: variant.size),
          let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write(Data("Nie udało się narysować \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}

print("Zapisano \(variants.count) rozmiarów w \(outputDirectory.path)")
