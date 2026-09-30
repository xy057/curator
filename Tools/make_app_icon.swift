// Draws Curator's app icon: three instrument lanes, as in the timeline, crossed by the
// pointer. Two lanes are shown at the pointer; the third comes in after it.
//
// Small sizes put every edge on a whole pixel so they stay crisp. Writes the macOS icon set
// and the Windows .ico. Run from the repository root:
//   swift Tools/make_app_icon.swift [preview-directory]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconSet = "app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
let windowsIcon = "app/windows/runner/resources/app_icon.ico"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let sky = rgb(0x4DA8F0) // AccentColor.sky
let skyStrong = rgb(0x1F8AE0) // AccentColor.sky.strong
let skySoft = rgb(0xA9D3F6)
let ink = rgb(0x14171A)

// The tile of macOS's icon grid: 824 of 1024, corners 185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let corner: CGFloat = 185

/// A lane: where it starts and ends across the tile, and its colour. Everything is in 1024ths.
struct Lane {
    let from: CGFloat
    let to: CGFloat
    let color: CGColor
}

let lanes = [
    Lane(from: 212, to: 640, color: sky),
    Lane(from: 548, to: 812, color: skySoft),
    Lane(from: 268, to: 580, color: skyStrong),
]
let pointerX: CGFloat = 470

/// Snaps a length in 1024ths to whole pixels at `pixels`, at least `least` pixels.
func snap(_ v: CGFloat, _ pixels: Int, least: CGFloat = 1) -> CGFloat {
    let pixel = 1024 / CGFloat(pixels)
    return max(least, (v / pixel).rounded()) * pixel
}

func drawIcon(_ c: CGContext, pixels: Int) {
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
    let paper = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF), rgb(0xECF0F5)] as CFArray,
                           locations: [0, 1])!
    c.drawLinearGradient(paper, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY),
                         options: [])

    // Lanes 92 high with 44 between them, snapped so small sizes keep their edges sharp.
    let height = snap(92, pixels, least: 2), gap = snap(44, pixels)
    var y = snap(512 - (3 * height + 2 * gap) / 2, pixels)
    for lane in lanes {
        let from = snap(lane.from, pixels), to = snap(lane.to, pixels)
        let rect = CGRect(x: from, y: y, width: to - from, height: height)
        c.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        c.setFillColor(lane.color)
        c.fillPath()
        y += height + gap
    }

    let width = snap(22, pixels), left = snap(pointerX - width / 2, pixels)
    let top = snap(232, pixels), bottom = snap(792, pixels)
    c.addPath(CGPath(roundedRect: CGRect(x: left, y: top, width: width, height: bottom - top),
                     cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
    c.setFillColor(ink)
    c.fillPath()
    c.restoreGState()
}

func render(_ pixels: Int) -> Data {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in a y-down 1024 space.
    c.translateBy(x: 0, y: CGFloat(pixels))
    c.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    drawIcon(c, pixels: pixels)
    let data = NSMutableData()
    let out = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(out, c.makeImage()!, nil)
    CGImageDestinationFinalize(out)
    return data as Data
}

let preview = CommandLine.arguments.dropFirst().first
let directory = preview ?? iconSet
var pngs: [Int: Data] = [:]
for pixels in [16, 32, 48, 64, 128, 256, 512, 1024] {
    pngs[pixels] = render(pixels)
    if pixels != 48 {
        try pngs[pixels]!.write(to: URL(fileURLWithPath: "\(directory)/app_icon_\(pixels).png"))
    }
}

// A Windows .ico holding PNG images (Vista and later read them).
if preview == nil {
    let sizes = [16, 32, 48, 256]
    var ico = Data([0, 0, 1, 0, UInt8(sizes.count), 0])
    var offset = 6 + 16 * sizes.count
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func le32(_ v: Int) -> [UInt8] { le16(v) + le16(v >> 16) }
    for size in sizes {
        let png = pngs[size]!
        ico.append(contentsOf: [UInt8(size % 256), UInt8(size % 256), 0, 0] + le16(1) + le16(32)
                   + le32(png.count) + le32(offset))
        offset += png.count
    }
    for size in sizes { ico.append(pngs[size]!) }
    try ico.write(to: URL(fileURLWithPath: windowsIcon))
}
