// Generates Verovio text-metric files from Academico so Verovio lays out text (tempo marks,
// expressions, instrument names) with the same widths the renderer draws.
//
// Verovio looks up text metrics by fixed file names (text/Times*.xml), so the Academico
// metrics are written under those names. Run from the repository root:
//   swift Tools/make_text_metrics.swift
import CoreText
import Foundation

let fonts = "packages/score_engine/assets/fonts"
let reference = "packages/score_engine/third_party/verovio/data/text/Times.xml"
let output = "packages/score_engine/assets/verovio/text"

let styles = [
    ("Academico-Regular", "Times"),
    ("Academico-Bold", "Times-bold"),
    ("Academico-Italic", "Times-italic"),
    ("Academico-BoldItalic", "Times-bold-italic"),
]

// The characters Verovio has metrics for, taken from its own Times file. Each `c` is the
// character's UTF-8 bytes in hex (e.g. "41" = A, "C3A9" = é).
let referenceXML = try String(contentsOfFile: reference, encoding: .utf8)
let codes = referenceXML.matches(of: #/<g c="([0-9A-Fa-f]+)"/#).map { String($0.1) }

for (file, verovioName) in styles {
    let url = URL(fileURLWithPath: "\(fonts)/\(file).otf")
    guard let descriptor = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])?.first else {
        fatalError("Missing \(url.path)")
    }
    let probe = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
    let upm = CGFloat(CTFontGetUnitsPerEm(probe))
    let font = CTFontCreateWithFontDescriptor(descriptor, upm, nil) // 1 point = 1 font unit

    var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                 "<bounding-boxes font-family=\"\(verovioName)\" units-per-em=\"\(Int(upm))\">"]
    for code in codes {
        let bytes = stride(from: 0, to: code.count, by: 2).compactMap { i -> UInt8? in
            let start = code.index(code.startIndex, offsetBy: i)
            return UInt8(code[start..<code.index(start, offsetBy: 2)], radix: 16)
        }
        var chars = Array(String(decoding: bytes, as: UTF8.self).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: chars.count)
        guard CTFontGetGlyphsForCharacters(font, &chars, &glyphs, chars.count) else { continue }
        var box = CGRect.zero
        var advance = CGSize.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &glyphs, &box, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphs, &advance, 1)
        if box.isNull { box = .zero }
        lines.append(String(format: "   <g c=\"%@\" x=\"%.1f\" y=\"%.1f\" w=\"%.1f\" h=\"%.1f\" h-a-x=\"%.1f\" />",
                            code, box.minX, box.minY, box.width, box.height, advance.width))
    }
    lines.append("</bounding-boxes>")
    try (lines.joined(separator: "\n") + "\n").write(toFile: "\(output)/\(verovioName).xml", atomically: true, encoding: .utf8)
    print("wrote \(output)/\(verovioName).xml (\(lines.count - 3) glyphs from \(file))")
}
