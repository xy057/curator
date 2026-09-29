// Draws Curator's app icon: a sheet of paper with three staves scrolling past a fixed
// pointer. The middle staff is fading, as a staff does when its instrument stops being shown,
// and the staves fade at both edges, as the score comes and goes in the scroll. On every
// staff a note sits exactly on the pointer: every onset is under it when it sounds.
//
// Small sizes are drawn with less (fewer staves, thicker lines) so they stay crisp. Writes
// the macOS icon set and the Windows .ico. Run from the repository root:
//   swift Tools/make_app_icon.swift [preview-directory]
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let iconSet = "app/macos/Runner/Assets.xcassets/AppIcon.appiconset"
let windowsIcon = "app/windows/runner/resources/app_icon.ico"
let bravura = "packages/score_engine/assets/fonts/Bravura.otf"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let ink = rgb(0x14171A)
let pointerBlue = rgb(0x1F8AE0) // AccentColor.sky.strong

guard let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(
    URL(fileURLWithPath: bravura) as CFURL) as? [CTFontDescriptor])?.first else {
    fatalError("Missing \(bravura)")
}

/// A SMuFL glyph as a path in a y-down space, origin on its baseline, one staff space = `space`.
func glyph(_ scalar: UInt16, space: CGFloat) -> CGPath {
    let font = CTFontCreateWithFontDescriptor(descriptor, space * 4, nil) // em = 4 spaces
    var character = scalar
    var id: CGGlyph = 0
    CTFontGetGlyphsForCharacters(font, &character, &id, 1)
    var flip = CGAffineTransform(scaleX: 1, y: -1)
    return CTFontCreatePathForGlyph(font, id, &flip)!
}

let noteheadBlack: UInt16 = 0xE0A4
let noteheadHalf: UInt16 = 0xE0A3
let noteheadWhole: UInt16 = 0xE0A2

/// A note on a staff: `x` is where it starts (in 1024ths), `step` its line or space counted
/// in half spaces up from the bottom line, `stem` +1 up / -1 down / 0 none.
struct Note {
    let x: CGFloat
    let step: Int
    let head: UInt16
    let stem: Int
}

/// A staff: its middle line's height (in 1024ths), how strongly it is inked, its notes, and
/// runs of notes (by index) beamed together.
struct Staff {
    let y: CGFloat
    let alpha: CGFloat
    let notes: [Note]
    var beams: [ClosedRange<Int>] = []
}

/// How much is drawn at a size. Everything is in 1024ths of the canvas; below 256 pixels the
/// lines are one pixel thick and sit on pixel centres, so they stay sharp.
struct Detail {
    let staves: [Staff]
    let lines: Int
    let space: CGFloat
    let line: CGFloat
    let pointerX: CGFloat
    let pointer: CGFloat
    let pointerTop: CGFloat
    let pointerBottom: CGFloat
    /// Half the width of the pointer's cap.
    let cap: CGFloat
}

func detail(for pixels: Int) -> Detail {
    let pixel = 1024 / CGFloat(pixels)
    if pixels >= 128 {
        let x: CGFloat = 424
        return Detail(
            staves: [
                Staff(y: 340, alpha: 1, notes: [
                    Note(x: 236, step: 2, head: noteheadHalf, stem: 1),
                    Note(x: x, step: 3, head: noteheadBlack, stem: 1),
                    Note(x: 512, step: 4, head: noteheadBlack, stem: 1),
                    Note(x: 600, step: 5, head: noteheadBlack, stem: 1),
                    Note(x: 688, step: 6, head: noteheadBlack, stem: 1),
                    Note(x: 800, step: 7, head: noteheadHalf, stem: -1),
                ], beams: [1...4]),
                Staff(y: 516, alpha: 0.24, notes: [
                    Note(x: 280, step: 4, head: noteheadHalf, stem: 1),
                    Note(x: 600, step: 3, head: noteheadHalf, stem: 1),
                ]),
                Staff(y: 684, alpha: 1, notes: [
                    Note(x: 200, step: 3, head: noteheadHalf, stem: 1),
                    Note(x: x, step: 1, head: noteheadHalf, stem: 1),
                    Note(x: 688, step: 2, head: noteheadHalf, stem: 1),
                ]),
            ],
            lines: 5, space: 24, line: max(4.5, pixel), pointerX: x, pointer: max(11, 2 * pixel),
            pointerTop: 176, pointerBottom: 824, cap: 35)
    }
    if pixels >= 48 {
        let x: CGFloat = 416
        return Detail(
            staves: [
                Staff(y: 360, alpha: 1, notes: [
                    Note(x: x, step: 3, head: noteheadBlack, stem: 1),
                    Note(x: 592, step: 5, head: noteheadBlack, stem: 1),
                ], beams: [0...1]),
                Staff(y: 664, alpha: 1, notes: [
                    Note(x: x, step: 1, head: noteheadBlack, stem: 1),
                ]),
            ],
            lines: 5, space: 3 * pixel, line: pixel, pointerX: x, pointer: 2 * pixel,
            pointerTop: 160, pointerBottom: 864, cap: 4 * pixel)
    }
    if pixels >= 32 {
        return Detail(
            staves: [Staff(y: 528, alpha: 1, notes: [Note(x: 416, step: 3, head: noteheadBlack, stem: 1)])],
            lines: 5, space: 3 * pixel, line: pixel, pointerX: 416, pointer: 2 * pixel,
            pointerTop: 224, pointerBottom: 832, cap: 3 * pixel)
    }
    return Detail(
        staves: [Staff(y: 544, alpha: 1, notes: [])],
        lines: 3, space: 3 * pixel, line: pixel, pointerX: 416, pointer: pixel,
        pointerTop: 256, pointerBottom: 832, cap: 2 * pixel)
}

// The tile of macOS's icon grid: 824 of 1024, corners 185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let corner: CGFloat = 185

func drawIcon(_ c: CGContext, _ d: Detail) {
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Shadow under the sheet.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 18, color: rgb(0x000000, 0.22))
    c.addPath(tilePath)
    c.setFillColor(rgb(0xFFFFFF))
    c.fillPath()
    c.restoreGState()

    // Paper: white at the top warming slightly towards the bottom.
    c.saveGState()
    c.addPath(tilePath)
    c.clip()
    let paper = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF), rgb(0xF3F0EA)] as CFArray,
                           locations: [0, 1])!
    c.drawLinearGradient(paper, start: CGPoint(x: 512, y: tile.minY), end: CGPoint(x: 512, y: tile.maxY),
                         options: [])

    // The music, faded at both edges of the sheet.
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    for staff in d.staves { drawStaff(c, staff, d) }
    let fade = CGGradient(
        colorsSpace: nil,
        colors: [rgb(0, 0), rgb(0, 1), rgb(0, 1), rgb(0, 0)] as CFArray,
        locations: [0, 0.2, 0.8, 1])!
    c.setBlendMode(.destinationIn)
    c.drawLinearGradient(fade, start: CGPoint(x: tile.minX, y: 0), end: CGPoint(x: tile.maxX, y: 0),
                         options: [])
    c.endTransparencyLayer()

    // The pointer, with the playhead's cap.
    let pointerX = d.pointerX, top = d.pointerTop, bottom = d.pointerBottom
    c.setFillColor(pointerBlue)
    let w = d.pointer
    c.addPath(CGPath(roundedRect: CGRect(x: pointerX - w / 2, y: top, width: w, height: bottom - top),
                     cornerWidth: w / 2, cornerHeight: w / 2, transform: nil))
    c.fillPath()
    let cap = d.cap
    c.move(to: CGPoint(x: pointerX - cap, y: top))
    c.addLine(to: CGPoint(x: pointerX + cap, y: top))
    c.addLine(to: CGPoint(x: pointerX, y: top + cap * 1.1))
    c.closePath()
    c.fillPath()
    c.restoreGState()
}

func drawStaff(_ c: CGContext, _ staff: Staff, _ d: Detail) {
    let s = d.space
    let bottomLine = staff.y + CGFloat(d.lines / 2) * s
    c.saveGState()
    c.setAlpha(staff.alpha)
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    c.setFillColor(ink)
    for i in 0..<d.lines {
        let y = bottomLine - CGFloat(i) * s
        c.fill(CGRect(x: tile.minX, y: y - d.line / 2, width: tile.width, height: d.line))
    }

    let stemWidth = d.line
    let length = s * 3.5
    let heads = staff.notes.map { bottomLine - CGFloat($0.step) * s / 2 }
    // Where each stem ends: a standard length, or on its beam, a line from the run's first stem
    // end to its last with the slant held to one space.
    var ends = zip(staff.notes, heads).map { note, y in y - CGFloat(note.stem) * length }
    var stemX: [CGFloat] = []
    for (note, y) in zip(staff.notes, heads) {
        let head = glyph(note.head, space: s)
        let box = head.boundingBoxOfPath
        // Onsets sit on the pointer: a notehead starts at the note's x.
        let left = note.x + d.pointer / 2
        var place = CGAffineTransform(translationX: left - box.minX, y: y)
        c.addPath(head.copy(using: &place)!)
        c.fillPath()
        stemX.append(note.stem > 0 ? left + box.width - stemWidth : left)
    }
    for run in staff.beams {
        let a = run.lowerBound, b = run.upperBound
        let rise = max(-s, min(s, ends[b] - ends[a]))
        let high = staff.notes[a].stem > 0 ? min(ends[a], ends[b] - rise) : max(ends[a], ends[b] - rise)
        for i in run {
            let t = (stemX[i] - stemX[a]) / (stemX[b] - stemX[a])
            ends[i] = high + rise * t
        }
        let thick = s * 0.5 * CGFloat(staff.notes[a].stem)
        c.move(to: CGPoint(x: stemX[a], y: ends[a]))
        c.addLine(to: CGPoint(x: stemX[b] + stemWidth, y: ends[b] + rise * stemWidth / (stemX[b] - stemX[a])))
        c.addLine(to: CGPoint(x: stemX[b] + stemWidth, y: ends[b] + thick))
        c.addLine(to: CGPoint(x: stemX[a], y: ends[a] + thick))
        c.closePath()
        c.fillPath()
    }
    for (i, note) in staff.notes.enumerated() where note.stem != 0 {
        let from = heads[i] - CGFloat(note.stem) * s * 0.17
        c.fill(CGRect(x: stemX[i], y: min(from, ends[i]), width: stemWidth, height: abs(ends[i] - from)))
    }
    c.endTransparencyLayer()
    c.restoreGState()
}

func render(_ pixels: Int) -> Data {
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in a y-down 1024 space.
    c.translateBy(x: 0, y: CGFloat(pixels))
    c.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    drawIcon(c, detail(for: pixels))
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
