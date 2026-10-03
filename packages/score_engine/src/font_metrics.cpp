// font_metrics.cpp — measuring fonts for Verovio's metric files, on every platform.
//
// Verovio lays out with each glyph's ink box and advance, read from XML files. For the fonts
// the app doesn't ship metrics for (an installed text font, a SMuFL font the user added) Dart
// writes those files from what this measures, reading the font file with stb_truetype.

#include "verovio_bridge.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

// stb_truetype is not ours to hold to our warnings.
#if defined(__clang__) || defined(__GNUC__)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wall"
#pragma GCC diagnostic ignored "-Wextra"
#elif defined(_MSC_VER)
#pragma warning(push, 0)
#endif
#define STB_TRUETYPE_IMPLEMENTATION
#define STBTT_STATIC
#include "stb_truetype.h"
#if defined(__clang__) || defined(__GNUC__)
#pragma GCC diagnostic pop
#elif defined(_MSC_VER)
#pragma warning(pop)
#endif

namespace {

std::vector<unsigned char> ReadFile(const char *path)
{
    std::vector<unsigned char> bytes;
#if defined(_WIN32)
    // Paths come as UTF-8; fopen would read them in the ANSI code page.
    const int length = MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
    if (length <= 0) return bytes;
    std::wstring wide(size_t(length), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wide.data(), length);
    FILE *file = _wfopen(wide.c_str(), L"rb");
#else
    FILE *file = fopen(path, "rb");
#endif
    if (!file) return bytes;
    if (fseek(file, 0, SEEK_END) == 0) {
        const long size = ftell(file);
        if (size > 0 && fseek(file, 0, SEEK_SET) == 0) {
            bytes.resize(size_t(size));
            if (fread(bytes.data(), 1, bytes.size(), file) != bytes.size()) bytes.clear();
        }
    }
    fclose(file);
    return bytes;
}

struct Box {
    float x0 = INFINITY, y0 = INFINITY, x1 = -INFINITY, y1 = -INFINITY;
    void Add(float x, float y)
    {
        x0 = std::min(x0, x);
        y0 = std::min(y0, y);
        x1 = std::max(x1, x);
        y1 = std::max(y1, y);
    }
    bool Empty() const { return x0 > x1; }
};

// Where one coordinate of a Bézier segment (quadratic when not [cubic]: c2 unused) turns.
void Extrema(float p0, float c1, float c2, float p1, bool cubic, std::vector<float> &ts)
{
    if (!cubic) {
        const float d = p0 - 2 * c1 + p1;
        if (d != 0) ts.push_back((p0 - c1) / d);
        return;
    }
    // The derivative, over 3: a t² + b t + c.
    const float a = -p0 + 3 * c1 - 3 * c2 + p1, b = 2 * (p0 - 2 * c1 + c2), c = c1 - p0;
    if (std::fabs(a) < 1e-9f) {
        if (b != 0) ts.push_back(-c / b);
        return;
    }
    const float disc = b * b - 4 * a * c;
    if (disc < 0) return;
    const float root = std::sqrt(disc);
    ts.push_back((-b + root) / (2 * a));
    ts.push_back((-b - root) / (2 * a));
}

float Bezier(float p0, float c1, float c2, float p1, bool cubic, float t)
{
    const float u = 1 - t;
    if (!cubic) return u * u * p0 + 2 * u * t * c1 + t * t * p1;
    return u * u * u * p0 + 3 * u * u * t * c1 + 3 * u * t * t * c2 + t * t * t * p1;
}

// The ink box of a glyph's outline: its points and where its curves turn, so the box is tight
// (a curve's control points may lie outside it).
Box InkBox(const stbtt_fontinfo &font, int glyph)
{
    Box box;
    stbtt_vertex *vertices = nullptr;
    const int count = stbtt_GetGlyphShape(&font, glyph, &vertices);
    float x = 0, y = 0;
    for (int i = 0; i < count; i++) {
        const stbtt_vertex &v = vertices[i];
        const bool cubic = v.type == STBTT_vcubic;
        if (v.type == STBTT_vcurve || cubic) {
            std::vector<float> ts;
            Extrema(x, v.cx, v.cx1, v.x, cubic, ts);
            Extrema(y, v.cy, v.cy1, v.y, cubic, ts);
            for (float t : ts) {
                if (t > 0 && t < 1) box.Add(Bezier(x, v.cx, v.cx1, v.x, cubic, t), Bezier(y, v.cy, v.cy1, v.y, cubic, t));
            }
        }
        box.Add(v.x, v.y);
        x = v.x;
        y = v.y;
    }
    stbtt_FreeShape(&font, vertices);
    return box;
}

} // namespace

extern "C" {

int32_t vb_measure_font(const char *path, int32_t face, const uint32_t *codes, int32_t count, float *out)
{
    const std::vector<unsigned char> bytes = ReadFile(path);
    if (bytes.empty()) return 0;
    const int offset = stbtt_GetFontOffsetForIndex(bytes.data(), face);
    stbtt_fontinfo font;
    if (offset < 0 || !stbtt_InitFont(&font, bytes.data(), offset)) return 0;
    const float scale = stbtt_ScaleForMappingEmToPixels(&font, 1);
    if (!(scale > 0)) return 0;
    const int32_t upm = int32_t(std::lround(1 / scale));
    for (int32_t i = 0; i < count; i++) {
        float *o = out + i * 5;
        o[0] = o[1] = o[2] = o[3] = 0;
        o[4] = -1; // not in the font
        const int glyph = stbtt_FindGlyphIndex(&font, int(codes[i]));
        if (glyph == 0) continue;
        int advance = 0, bearing = 0;
        stbtt_GetGlyphHMetrics(&font, glyph, &advance, &bearing);
        const Box box = InkBox(font, glyph);
        if (!box.Empty()) {
            o[0] = box.x0;
            o[1] = box.y0;
            o[2] = box.x1 - box.x0;
            o[3] = box.y1 - box.y0;
        }
        o[4] = float(advance);
    }
    return upm;
}

} // extern "C"
