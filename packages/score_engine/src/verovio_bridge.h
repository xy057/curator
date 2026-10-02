// verovio_bridge.h — a plain C interface over Verovio, called from Dart via FFI.
//
// Verovio engraves the score into a single long system (breaks = "none").
// Instead of producing SVG, a recording device context captures every drawing
// call into a flat display list, tagged with the staff (@n) it belongs to.
// The Flutter renderer then draws each staff as an independent layer that can be moved and
// faded without re-engraving.
//
// All coordinates are Verovio device units, y pointing down.

#ifndef VEROVIO_BRIDGE_H
#define VEROVIO_BRIDGE_H

#include <stdbool.h>
#include <stdint.h>

#if defined(_WIN32)
#if defined(VB_BUILDING_LIBRARY)
#define VB_API __declspec(dllexport)
#else
#define VB_API __declspec(dllimport)
#endif
#else
#define VB_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VBEngraver VBEngraver;

typedef enum {
    VB_CMD_PATH = 0,  // vector shape made of VBPathElements
    VB_CMD_GLYPH = 1, // one SMuFL glyph drawn with the music font
    VB_CMD_TEXT = 2   // one run of text (UTF-8)
} VBCommandKind;

typedef enum {
    VB_PATH_MOVE = 0,    // p0 p1
    VB_PATH_LINE = 1,    // p0 p1
    VB_PATH_QUAD = 2,    // control p0 p1, end p2 p3
    VB_PATH_CUBIC = 3,   // control p0 p1, control p2 p3, end p4 p5
    VB_PATH_CLOSE = 4,
    VB_PATH_ELLIPSE = 5  // rect x y w h in p0..p3
} VBPathOp;

enum {
    VB_FLAG_FILL = 1 << 0,
    VB_FLAG_STROKE = 1 << 1,
    VB_FLAG_ROUND_CAP = 1 << 2,
    VB_FLAG_SQUARE_CAP = 1 << 3,
    VB_FLAG_ROUND_JOIN = 1 << 4,
    VB_FLAG_BEVEL_JOIN = 1 << 5,
    VB_FLAG_ITALIC = 1 << 6,
    VB_FLAG_BOLD = 1 << 7,
    VB_FLAG_SMUFL_TEXT = 1 << 8, // text run should use the music font
    VB_FLAG_NEW_TEXT_BLOCK = 1 << 9 // text run starts a new positioned block
};

/// Read from Dart by word index (`Cmd` in engraving.dart): every field is 4 bytes, and the
/// static_asserts in verovio_bridge.cpp pin each one to its index. Rotated graphics (arpeggio
/// and glissando wiggles) are recorded already rotated: path points turned, glyphs with a
/// [rotation].
typedef struct {
    int32_t kind;        // VBCommandKind
    int32_t staff;       // staff @n (1-based); 0 = system level (barlines, brackets, labels)
    int32_t flags;
    int32_t classIndex;  // index into the class-name table (innermost element, e.g. "Note")
    float strokeWidth;
    float dash, gap;     // dash pattern, 0 = solid
    float x, y;          // glyph origin / text block anchor
    float size;          // glyph or text point size
    uint32_t codepoint;  // glyph
    int32_t alignment;   // text: 0 left, 1 center, 2 right
    int32_t start;       // first path element, or first byte of text
    int32_t count;       // number of path elements, or text bytes
    int32_t fontIndex;   // text: index into the font-name table
    float bounds[4];     // glyph: ink box x, y, width, height (device units, y down)
    int32_t sourceIndex; // text: index into the source-id table (the MusicXML element), or -1
    float rotation;      // glyph: degrees clockwise about (x, y), e.g. -90 for an arpeggio wiggle
} VBCommand;

typedef struct {
    int32_t op; // VBPathOp
    float p[6];
} VBPathElement;

typedef struct {
    int32_t n;      // staff @n
    float top;      // y of the top staff line
    float height;   // distance from top to bottom staff line
    int32_t lines;  // number of staff lines
} VBStaffInfo;

typedef struct {
    float left;          // x of the left barline
    float right;         // x of the right barline
    double duration;     // measure length in quarter notes
    int32_t onsetStart;  // first entry in the onset table
    int32_t onsetCount;
} VBMeasureInfo;

typedef struct {
    double time; // quarter notes from the start of the measure
    float x;     // x where every note starting at that time is aligned
} VBOnset;

typedef enum {
    VB_SIG_CLEF = 0,
    VB_SIG_KEY = 1,
    VB_SIG_METER = 2
} VBSignatureKind;

/// A clef, key or time signature as music, not glyphs, so the frozen zone can redraw it at
/// full size.
typedef struct {
    int32_t kind;         // VBSignatureKind
    int32_t staff;        // staff @n
    float x;              // leftmost glyph x
    int32_t shape;        // clef: 1 G, 2 GG, 3 F, 4 C, 5 percussion, 6 TAB
    int32_t line;         // clef: staff line, 1 = bottom
    int32_t octave;       // clef: octave shift (-2…2), e.g. -1 for a tenor G clef with 8 below
    int32_t fifths;       // key: sharps > 0, flats < 0
    int32_t commandStart; // the glyph commands drawn for it
    int32_t commandCount;
    int32_t count;        // meter: beats (additive counts summed)
    int32_t unit;         // meter: beat unit (4 = crotchet)
    int32_t symbol;       // meter: SMuFL glyph for common / cut time, or 0 for numbers
    int32_t summands[4];  // meter: the numerator as written, e.g. 2, 2, 3 for 2+2+3
    int32_t summandCount; // meter: how many of summands are used (1 for a plain number)
} VBSignature;

typedef enum {
    VB_STRUCT_COMMAND = 0,
    VB_STRUCT_PATH_ELEMENT = 1,
    VB_STRUCT_STAFF_INFO = 2,
    VB_STRUCT_MEASURE_INFO = 3,
    VB_STRUCT_ONSET = 4,
    VB_STRUCT_SIGNATURE = 5
} VBStruct;

/// sizeof one of the structs above, so the Dart side can check it reads them with the same
/// layout (see engraving.dart). -1 for an unknown struct.
VB_API int32_t vb_struct_size(int32_t which);

VB_API VBEngraver *vb_engraver_create(const char *resourcePath);
VB_API void vb_engraver_destroy(VBEngraver *engraver);

/// Verovio JSON options, merged on top of the bridge defaults.
VB_API bool vb_engraver_set_options(VBEngraver *engraver, const char *json);
VB_API bool vb_engraver_load_data(VBEngraver *engraver, const char *data);

/// Engraves and records the display list. Call after loading.
VB_API bool vb_engraver_render(VBEngraver *engraver);
/// What Verovio reported (one "[Warning] …" or "[Error] …" a line) since loading, then
/// clears it. Valid until the next call on this engraver.
VB_API const char *vb_engraver_log(VBEngraver *engraver);

/// Every Verovio option with its type, default and range (Toolkit::GetAvailableOptions), as
/// JSON. Valid until the next call on this engraver.
VB_API const char *vb_engraver_available_options(VBEngraver *engraver);

VB_API float vb_page_width(const VBEngraver *engraver);
VB_API float vb_staff_space(const VBEngraver *engraver);

VB_API int32_t vb_command_count(const VBEngraver *engraver);
VB_API const VBCommand *vb_commands(const VBEngraver *engraver);
VB_API int32_t vb_path_element_count(const VBEngraver *engraver);
VB_API const VBPathElement *vb_path_elements(const VBEngraver *engraver);
VB_API int32_t vb_text_byte_count(const VBEngraver *engraver);
VB_API const char *vb_text_bytes(const VBEngraver *engraver);
VB_API int32_t vb_class_name_count(const VBEngraver *engraver);
VB_API const char *vb_class_name(const VBEngraver *engraver, int32_t index);
VB_API int32_t vb_font_name_count(const VBEngraver *engraver);
VB_API const char *vb_font_name(const VBEngraver *engraver, int32_t index);

VB_API int32_t vb_staff_count(const VBEngraver *engraver);
VB_API const VBStaffInfo *vb_staves(const VBEngraver *engraver);
VB_API int32_t vb_measure_count(const VBEngraver *engraver);
VB_API const VBMeasureInfo *vb_measures(const VBEngraver *engraver);
VB_API int32_t vb_onset_count(const VBEngraver *engraver);
VB_API const VBOnset *vb_onsets(const VBEngraver *engraver);
VB_API int32_t vb_source_id_count(const VBEngraver *engraver);
VB_API const char *vb_source_id(const VBEngraver *engraver, int32_t index);
VB_API int32_t vb_signature_count(const VBEngraver *engraver);
VB_API const VBSignature *vb_signatures(const VBEngraver *engraver);

#ifdef __cplusplus
}
#endif

#endif
