// font_metrics.cpp — measuring fonts for Verovio's metric files, with CoreText (macOS).
//
// Verovio lays out with each glyph's ink box and advance, read from XML files. For the fonts
// the app doesn't ship metrics for (a text font installed on the Mac, a SMuFL font the user
// added) Dart writes those files from what this measures. Elsewhere every call fails softly.

#include "verovio_bridge.h"

#include <string>

#if defined(__APPLE__)
#include <CoreFoundation/CoreFoundation.h>
#include <CoreText/CoreText.h>

namespace {

std::string ToString(CFStringRef string)
{
    if (!string) return "";
    const CFIndex length = CFStringGetLength(string);
    const CFIndex size = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
    std::string out(size_t(size), '\0');
    if (!CFStringGetCString(string, out.data(), size, kCFStringEncodingUTF8)) return "";
    out.resize(strlen(out.c_str()));
    return out;
}

CFStringRef MakeString(const char *utf8) { return CFStringCreateWithCString(nullptr, utf8, kCFStringEncodingUTF8); }

// The first face in a font file.
CTFontDescriptorRef DescriptorOfFile(const char *path)
{
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(nullptr, (const UInt8 *)path, CFIndex(strlen(path)), false);
    if (!url) return nullptr;
    CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL(url);
    CFRelease(url);
    if (!descriptors) return nullptr;
    CTFontDescriptorRef first = nullptr;
    if (CFArrayGetCount(descriptors) > 0) {
        first = (CTFontDescriptorRef)CFRetain(CFArrayGetValueAtIndex(descriptors, 0));
    }
    CFRelease(descriptors);
    return first;
}

// An installed family's face closest to bold / italic; null when the family isn't installed
// (CoreText would otherwise quietly hand back another font).
CTFontRef FontOfFamily(const char *family, bool bold, bool italic, CGFloat size)
{
    CFStringRef name = MakeString(family);
    if (!name) return nullptr;
    const CTFontSymbolicTraits wanted = (bold ? kCTFontBoldTrait : 0) | (italic ? kCTFontItalicTrait : 0);
    CFNumberRef traitsValue = CFNumberCreate(nullptr, kCFNumberSInt32Type, &wanted);
    const void *traitKeys[] = {kCTFontSymbolicTrait};
    const void *traitValues[] = {traitsValue};
    CFDictionaryRef traits = CFDictionaryCreate(nullptr, traitKeys, traitValues, 1, &kCFTypeDictionaryKeyCallBacks,
                                                &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = {kCTFontFamilyNameAttribute, kCTFontTraitsAttribute};
    const void *values[] = {name, traits};
    CFDictionaryRef attributes = CFDictionaryCreate(nullptr, keys, values, 2, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef descriptor = CTFontDescriptorCreateWithAttributes(attributes);
    const void *mandatory[] = {kCTFontFamilyNameAttribute};
    CFSetRef mandatoryKeys = CFSetCreate(nullptr, mandatory, 1, &kCFTypeSetCallBacks);
    CTFontDescriptorRef matched = CTFontDescriptorCreateMatchingFontDescriptor(descriptor, mandatoryKeys);
    CTFontRef font = matched ? CTFontCreateWithFontDescriptor(matched, size, nullptr) : nullptr;
    if (font) {
        CFStringRef got = CTFontCopyFamilyName(font);
        const bool same = got && CFStringCompare(got, name, kCFCompareCaseInsensitive) == kCFCompareEqualTo;
        if (got) CFRelease(got);
        if (!same) {
            CFRelease(font);
            font = nullptr;
        }
    }
    if (matched) CFRelease(matched);
    CFRelease(mandatoryKeys);
    CFRelease(descriptor);
    CFRelease(attributes);
    CFRelease(traits);
    CFRelease(traitsValue);
    CFRelease(name);
    return font;
}

thread_local std::string g_result;

} // namespace

extern "C" {

int32_t vb_measure_font(const char *font, bool isFile, bool bold, bool italic, const uint32_t *codes, int32_t count, float *out)
{
    // Opened once to read its units per em, then at that size so a point is a font unit.
    CTFontRef probe = nullptr;
    if (isFile) {
        CTFontDescriptorRef descriptor = DescriptorOfFile(font);
        if (descriptor) {
            probe = CTFontCreateWithFontDescriptor(descriptor, 12, nullptr);
            const unsigned upm = CTFontGetUnitsPerEm(probe);
            CFRelease(probe);
            probe = CTFontCreateWithFontDescriptor(descriptor, CGFloat(upm), nullptr);
            CFRelease(descriptor);
        }
    }
    else {
        probe = FontOfFamily(font, bold, italic, 12);
        if (probe) {
            const unsigned upm = CTFontGetUnitsPerEm(probe);
            CFRelease(probe);
            probe = FontOfFamily(font, bold, italic, CGFloat(upm));
        }
    }
    if (!probe) return 0;
    const int32_t upm = int32_t(CTFontGetUnitsPerEm(probe));
    for (int32_t i = 0; i < count; i++) {
        float *o = out + i * 5;
        o[0] = o[1] = o[2] = o[3] = 0;
        o[4] = -1; // not in the font
        UniChar chars[2];
        const uint32_t c = codes[i];
        CFIndex length = 1;
        if (c > 0xFFFF) {
            chars[0] = UniChar(0xD800 + ((c - 0x10000) >> 10));
            chars[1] = UniChar(0xDC00 + ((c - 0x10000) & 0x3FF));
            length = 2;
        }
        else {
            chars[0] = UniChar(c);
        }
        CGGlyph glyphs[2] = {0, 0};
        if (!CTFontGetGlyphsForCharacters(probe, chars, glyphs, length) || glyphs[0] == 0) continue;
        CGRect box = CGRectZero;
        CGSize advance = CGSizeZero;
        CTFontGetBoundingRectsForGlyphs(probe, kCTFontOrientationHorizontal, glyphs, &box, 1);
        CTFontGetAdvancesForGlyphs(probe, kCTFontOrientationHorizontal, glyphs, &advance, 1);
        if (CGRectIsNull(box)) box = CGRectZero;
        o[0] = float(box.origin.x);
        o[1] = float(box.origin.y);
        o[2] = float(box.size.width);
        o[3] = float(box.size.height);
        o[4] = float(advance.width);
    }
    CFRelease(probe);
    return upm;
}

const char *vb_font_families(void)
{
    g_result.clear();
    CFArrayRef names = CTFontManagerCopyAvailableFontFamilyNames();
    if (!names) return "";
    for (CFIndex i = 0; i < CFArrayGetCount(names); i++) {
        const std::string name = ToString((CFStringRef)CFArrayGetValueAtIndex(names, i));
        if (name.empty() || name[0] == '.') continue; // the system's hidden UI fonts
        g_result += name;
        g_result += '\n';
    }
    CFRelease(names);
    return g_result.c_str();
}

const char *vb_font_file_family(const char *path)
{
    g_result.clear();
    CTFontDescriptorRef descriptor = DescriptorOfFile(path);
    if (!descriptor) return "";
    CFStringRef family = (CFStringRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute);
    g_result = ToString(family);
    if (family) CFRelease(family);
    CFRelease(descriptor);
    return g_result.c_str();
}

const char *vb_font_family_file(const char *family)
{
    g_result.clear();
    CTFontRef font = FontOfFamily(family, false, false, 12);
    if (!font) return "";
    CFURLRef url = (CFURLRef)CTFontCopyAttribute(font, kCTFontURLAttribute);
    if (url) {
        UInt8 path[4096];
        if (CFURLGetFileSystemRepresentation(url, true, path, sizeof(path))) g_result = (const char *)path;
        CFRelease(url);
    }
    CFRelease(font);
    return g_result.c_str();
}

} // extern "C"

#else

extern "C" {

int32_t vb_measure_font(const char *, bool, bool, bool, const uint32_t *, int32_t, float *) { return 0; }
const char *vb_font_families(void) { return ""; }
const char *vb_font_file_family(const char *) { return ""; }
const char *vb_font_family_file(const char *) { return ""; }

} // extern "C"

#endif
