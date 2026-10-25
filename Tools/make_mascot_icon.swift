// Draws the mascot's tile, the easter egg in place of the app icon (a click on Settings ▸ About's
// icon): the official mascot, Tools/mascot.png, on the app icon's tile (make_app_icon.swift) and
// a pale sky paper, standing on the tile's foot. Writes the app's two sizes. Run from the
// repository root:
//   swift Tools/make_mascot_icon.swift [preview-directory]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let art = "Tools/mascot.png"
let assets = "app/assets/icon"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// The tile of macOS's icon grid: 824 of 1024, corners 185 (as the app icon's).
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let corner: CGFloat = 185

let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: art) as CFURL, nil)!
let mascot = CGImageSourceCreateImageAtIndex(source, 0, nil)!

func drawIcon(_ c: CGContext) {
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: rgb(0x000000, 0.22))
    c.addPath(tilePath)
    c.setFillColor(rgb(0xFFFFFF))
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(tilePath)
    c.clip()
    let paper = CGGradient(colorsSpace: nil, colors: [rgb(0xEEF6FE), rgb(0xD3E7F9)] as CFArray, locations: [0, 1])!
    // y-up here (CGContext): the light at the top.
    c.drawLinearGradient(paper, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY),
                         options: [])
    // The tile's width, centred, its foot on the tile's: the legs run off the edge.
    let side = tile.width
    c.interpolationQuality = .high
    c.draw(mascot, in: CGRect(x: 512 - side / 2, y: tile.minY, width: side, height: side))
    c.restoreGState()
}

func render(_ pixels: Int) -> Data {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(c)
    let data = NSMutableData()
    let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(out, c.makeImage()!, nil)
    CGImageDestinationFinalize(out)
    return data as Data
}

let directory = CommandLine.arguments.dropFirst().first ?? assets
// The app's (256) and the Dock's at its largest (512: 256 pt at 2×).
try render(256).write(to: URL(fileURLWithPath: "\(directory)/mascot.png"))
try render(512).write(to: URL(fileURLWithPath: "\(directory)/mascot_512.png"))
