// Erzeugt das App-Icon: ein Prisma, das einen Lichtstrahl in vier Bänder
// zerlegt — Foton und die vier Board-Spalten in einem Bild.
//
//     swift Tools/make_icon.swift FotonKanban/Assets.xcassets/AppIcon.appiconset
//
// Alles ist auf einer Zeichenfläche von 1024 definiert und wird auf die
// jeweilige Zielgröße skaliert. Die Formen sind bewusst massiv gehalten, damit
// das Icon auch bei 32 Pixeln im Dock noch als Prisma lesbar bleibt.

import AppKit
import CoreGraphics
import Foundation

let canvas: CGFloat = 1024
// Maße des macOS-Iconrasters: der Körper sitzt mit Rand in der Fläche.
let bodyInset: CGFloat = 100
let bodySize = canvas - 2 * bodyInset
let cornerRadius: CGFloat = 185

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

let bandColors: [CGColor] = [
    color(0xFF5A4E),  // Rot
    color(0xFFB020),  // Amber
    color(0x2ED39A),  // Grün
    color(0x4DA3FF),  // Blau
]

/// Zeichnet das Motiv in Koordinaten der 1024er-Fläche.
///
/// - Parameter simplified: Für Kantenlängen bis 32 Pixel. Der eintretende
///   Strahl entfällt und die Kanten werden kräftiger — bei dieser Größe ist
///   weniger tatsächlich mehr, sonst verschmiert alles zu einem Fleck.
func draw(in context: CGContext, simplified: Bool) {
    let body = CGRect(x: bodyInset, y: bodyInset, width: bodySize, height: bodySize)
    let squircle = CGPath(
        roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    )

    // Hintergrund: tiefes Indigo, nach unten dunkler.
    context.saveGState()
    context.addPath(squircle)
    context.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(
        colorsSpace: space,
        colors: [color(0x2A2350), color(0x0B0916)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: canvas),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Ab hier in Körperkoordinaten: Ursprung unten links im Körper.
    context.translateBy(x: bodyInset, y: bodyInset)
    // Der Entwurf ist von oben nach unten gedacht, CoreGraphics zählt von
    // unten — einmal spiegeln, dann stimmen die Zahlen mit der Skizze überein.
    context.translateBy(x: 0, y: bodySize)
    context.scaleBy(x: 1, y: -1)

    // Breiter als hoch gedacht: ein Prisma, kein Obelisk.
    let apex = CGPoint(x: 350, y: 170)
    let baseLeft = CGPoint(x: 185, y: 665)
    let baseRight = CGPoint(x: 515, y: 665)
    let beamY: CGFloat = 455
    let beamHeight: CGFloat = 62

    if !simplified {
        // Eintretender Strahl, endet an der linken Prismenkante.
        let hitX = apex.x + (baseLeft.x - apex.x) * ((beamY - apex.y) / (baseLeft.y - apex.y))
        context.setFillColor(color(0xFFFFFF))
        context.addPath(CGPath(
            roundedRect: CGRect(x: 30, y: beamY - beamHeight / 2, width: hitX - 20, height: beamHeight),
            cornerWidth: beamHeight / 2, cornerHeight: beamHeight / 2, transform: nil
        ))
        context.fillPath()
    }

    // Austretende Bänder, aufgefächert. Schmal an der Kante, breit am Rand.
    let fanStartX: CGFloat = 470
    let fanEndX: CGFloat = 782
    for (index, bandColor) in bandColors.enumerated() {
        let i = CGFloat(index)
        let startTop = 395 + i * 35
        let endTop = 200 + i * 130
        let path = CGMutablePath()
        path.move(to: CGPoint(x: fanStartX, y: startTop))
        path.addLine(to: CGPoint(x: fanEndX, y: endTop))
        path.addLine(to: CGPoint(x: fanEndX, y: endTop + 100))
        path.addLine(to: CGPoint(x: fanStartX, y: startTop + 25))
        path.closeSubpath()
        context.setFillColor(bandColor)
        context.addPath(path)
        context.fillPath()
    }

    // Das Prisma zuletzt, damit es die Bänder an der Austrittskante überdeckt.
    let triangle = CGMutablePath()
    triangle.move(to: apex)
    triangle.addLine(to: baseRight)
    triangle.addLine(to: baseLeft)
    triangle.closeSubpath()

    // Hell genug, dass die Form auch ohne erkennbare Kante gegen den
    // Hintergrund steht.
    context.setFillColor(color(0x4C4193))
    context.addPath(triangle)
    context.fillPath()

    context.setStrokeColor(color(0xD8D3FF))
    context.setLineWidth(simplified ? 44 : 30)
    context.setLineJoin(.round)
    context.addPath(triangle)
    context.strokePath()

    context.restoreGState()
}

func render(size: Int) -> Data {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    let scale = CGFloat(size) / canvas
    context.scaleBy(x: scale, y: scale)
    draw(in: context, simplified: size <= 32)

    let image = context.makeImage()!
    let representation = NSBitmapImageRep(cgImage: image)
    return representation.representation(using: .png, properties: [:])!
}

// MARK: - Ausgabe

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    print("Aufruf: swift Tools/make_icon.swift <Zielordner>")
    exit(1)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// Jeder Eintrag bekommt eine eigene Datei — auch wenn zwei Einträge dieselbe
/// Pixelgröße haben (16@2x und 32@1x sind beide 32 Pixel). Verweisen zwei
/// Einträge auf dieselbe Datei, verwirft der Asset-Compiler sie stillschweigend
/// und im fertigen Icon fehlen Größen.
let entries: [(point: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2),
]

func fileName(point: Int, scale: Int) -> String {
    let suffix = scale == 2 ? "@2x" : ""
    return "icon_\(point)x\(point)\(suffix).png"
}

for entry in entries {
    let pixels = entry.point * entry.scale
    let name = fileName(point: entry.point, scale: entry.scale)
    let url = outputDirectory.appending(path: name, directoryHint: .notDirectory)
    try render(size: pixels).write(to: url)
    print("geschrieben: \(name)  (\(pixels) px)")
}

let images = entries.map { entry in
    """
        {
          "filename" : "\(fileName(point: entry.point, scale: entry.scale))",
          "idiom" : "mac",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.point)x\(entry.point)"
        }
    """
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(
    to: outputDirectory.appending(path: "Contents.json", directoryHint: .notDirectory),
    atomically: true, encoding: .utf8
)
print("geschrieben: Contents.json")
