// verovio_bridge.cpp — recording device context + C API.

#include "verovio_bridge.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <map>
#include <string>
#include <vector>

#include "clef.h"
#include "devicecontext.h"
#include "keysig.h"
#include "doc.h"
#include "floatingobject.h"
#include "horizontalaligner.h"
#include "measure.h"
#include "metersig.h"
#include "staff.h"
#include "toolkit.h"
#include "verticalaligner.h"
#include "view.h"
#include "vrv.h"

using namespace vrv;

// The Dart side reads VBCommand as 4-byte words (Cmd in engraving.dart): keep these in step.
#define VB_WORD(field, index) static_assert(offsetof(VBCommand, field) == (index) * 4, #field " moved")
VB_WORD(kind, 0);
VB_WORD(staff, 1);
VB_WORD(flags, 2);
VB_WORD(classIndex, 3);
VB_WORD(strokeWidth, 4);
VB_WORD(dash, 5);
VB_WORD(gap, 6);
VB_WORD(x, 7);
VB_WORD(y, 8);
VB_WORD(size, 9);
VB_WORD(codepoint, 10);
VB_WORD(alignment, 11);
VB_WORD(start, 12);
VB_WORD(count, 13);
VB_WORD(fontIndex, 14);
VB_WORD(bounds, 15);
VB_WORD(sourceIndex, 19);
VB_WORD(rotation, 20);
static_assert(sizeof(VBCommand) == 21 * 4, "VBCommand is 21 words");
static_assert(sizeof(VBPathElement) == 7 * 4, "VBPathElement is an op and 6 floats");
#undef VB_WORD

namespace {

// Verovio stores alignment times as fractions of a whole note.
constexpr double kQuarterNotesPerWhole = 4.0;

std::string ToUTF8(const std::u32string &text)
{
    std::string out;
    for (char32_t c : text) {
        if (c < 0x80) {
            out += char(c);
        }
        else if (c < 0x800) {
            out += char(0xC0 | (c >> 6));
            out += char(0x80 | (c & 0x3F));
        }
        else if (c < 0x10000) {
            out += char(0xE0 | (c >> 12));
            out += char(0x80 | ((c >> 6) & 0x3F));
            out += char(0x80 | (c & 0x3F));
        }
        else {
            out += char(0xF0 | (c >> 18));
            out += char(0x80 | ((c >> 12) & 0x3F));
            out += char(0x80 | ((c >> 6) & 0x3F));
            out += char(0x80 | (c & 0x3F));
        }
    }
    return out;
}

/// Captures Verovio's drawing calls instead of producing SVG.
class RecordingDeviceContext : public DeviceContext {
public:
    RecordingDeviceContext() : DeviceContext(CUSTOM_DEVICE_CONTEXT) {}

    std::vector<VBCommand> commands;
    std::vector<VBPathElement> pathElements;
    std::string textBytes;
    std::vector<std::string> classNames;
    std::vector<std::string> fontNames;
    std::vector<std::string> sourceIds;
    std::vector<VBStaffInfo> staves;
    std::vector<VBMeasureInfo> measures;
    std::vector<VBOnset> onsets;
    std::vector<VBSignature> signatures;
    float staffSpace = 0;

    // MARK: Graphic grouping — decides which staff owns each drawing call

    void StartGraphic(Object *object, const std::string &gClass, const std::string &gId, GraphicID graphicID,
        bool prepend) override
    {
        this->Push(object);
        if (object->Is(MEASURE)) this->RecordMeasure(vrv_cast<Measure *>(object));
    }
    void EndGraphic(Object *object, View *view) override
    {
        if (object->Is(STAFF)) this->RecordStaff(vrv_cast<Staff *>(object), view);
        if (object->Is(CLEF) || object->Is(KEYSIG) || object->Is(METERSIG)) this->RecordSignature(object);
        this->Pop();
    }
    void ResumeGraphic(Object *object, std::string gId) override { this->Push(object); }
    void EndResumedGraphic(Object *object, View *view) override { this->Pop(); }
    void StartTextGraphic(Object *object, const std::string &gClass, const std::string &gId) override
    {
        this->Push(object);
    }
    void EndTextGraphic(Object *object, View *view) override { this->Pop(); }
    void StartCustomGraphic(const std::string &name, std::string gClass, std::string gId) override
    {
        Owner owner = m_owners.empty() ? Owner{ 0, 0, 0, -1 } : m_owners.back();
        owner.commandStart = int(commands.size());
        m_owners.push_back(owner); // inherits the rotation of the graphic it is in
    }
    void EndCustomGraphic() override { this->Pop(); }

    // MARK: Unused device state

    void SetBackground(int color, int style) override {}
    void SetBackgroundImage(void *image, double opacity) override {}
    void SetBackgroundMode(int mode) override {}
    void SetTextForeground(int color) override {}
    void SetTextBackground(int color) override {}
    void SetLogicalOrigin(int x, int y) override {}
    Point GetLogicalOrigin() override { return Point(0, 0); }
    void StartPage() override {}
    void EndPage() override {}
    bool ApplyOffset() override { return true; }
    void DrawBackgroundImage(int x, int y) override {} // a page background: the renderer paints paper

    // Only reached from MEI <graphic> / <svg> (images and inline SVG in text), which MusicXML
    // import never creates; and Verovio's views never call the spline or rotated-text calls.
    void DrawGraphicUri(int x, int y, int width, int height, const std::string &uri) override {}
    void DrawSvgShape(int x, int y, int width, int height, double scale, pugi::xml_node svg) override {}
    void DrawSpline(int n, Point points[]) override {}
    void DrawRotatedText(const std::string &text, int x, int y, double angle) override {}

    /// Turns everything drawn in the current graphic by [angle] degrees about [orig], like the
    /// SVG output's rotate(): arpeggio and glissando wiggles are horizontal glyph lines turned
    /// upright. Only the first rotation of a graphic counts, as in SVG.
    void RotateGraphic(Point const &orig, double angle) override
    {
        if (m_owners.empty() || m_owners.back().rotated) return;
        Owner &owner = m_owners.back();
        owner.rotated = true;
        owner.angle = angle;
        owner.cx = orig.x;
        owner.cy = orig.y;
    }

    // MARK: Shapes

    void DrawLine(int x1, int y1, int x2, int y2) override
    {
        const int start = this->BeginPath();
        this->Element(VB_PATH_MOVE, { float(x1), float(y1) });
        this->Element(VB_PATH_LINE, { float(x2), float(y2) });
        this->EndPath(start, VB_FLAG_STROKE);
    }

    void DrawPolyline(int n, Point points[], bool close) override
    {
        if (n < 2) return;
        const int start = this->BeginPath();
        this->Element(VB_PATH_MOVE, { float(points[0].x), float(points[0].y) });
        for (int i = 1; i < n; ++i) this->Element(VB_PATH_LINE, { float(points[i].x), float(points[i].y) });
        if (close) this->Element(VB_PATH_CLOSE, {});
        this->EndPath(start, VB_FLAG_STROKE);
    }

    void DrawPolygon(int n, Point points[]) override
    {
        if (n < 2) return;
        const int start = this->BeginPath();
        this->Element(VB_PATH_MOVE, { float(points[0].x), float(points[0].y) });
        for (int i = 1; i < n; ++i) this->Element(VB_PATH_LINE, { float(points[i].x), float(points[i].y) });
        this->Element(VB_PATH_CLOSE, {});
        this->EndPath(start, this->FillFlag() | this->StrokeIfWidth());
    }

    void DrawRectangle(int x, int y, int width, int height) override
    {
        this->DrawRoundedRectangle(x, y, width, height, 0);
    }

    void DrawRoundedRectangle(int x, int y, int width, int height, int radius) override
    {
        if (height < 0) {
            height = -height;
            y -= height;
        }
        if (width < 0) {
            width = -width;
            x -= width;
        }
        const float x0 = x, y0 = y, x1 = x + width, y1 = y + height;
        const int start = this->BeginPath();
        this->Element(VB_PATH_MOVE, { x0, y0 });
        this->Element(VB_PATH_LINE, { x1, y0 });
        this->Element(VB_PATH_LINE, { x1, y1 });
        this->Element(VB_PATH_LINE, { x0, y1 });
        this->Element(VB_PATH_CLOSE, {});
        this->EndPath(start, this->FillFlag() | this->StrokeIfWidth());
    }

    void DrawCircle(int x, int y, int radius) override
    {
        this->DrawEllipse(x - radius, y - radius, 2 * radius, 2 * radius);
    }

    void DrawEllipse(int x, int y, int width, int height) override
    {
        const int start = this->BeginPath();
        this->Element(VB_PATH_ELLIPSE, { float(x), float(y), float(width), float(height) });
        this->EndPath(start, this->FillFlag() | this->StrokeIfWidth());
    }

    void DrawEllipticArc(int x, int y, int width, int height, double startAngle, double endAngle) override
    {
        // Rare in common notation; approximate with line segments.
        const double rx = width / 2.0, ry = height / 2.0, xc = x + rx, yc = y + ry;
        const int steps = 24;
        const int start = this->BeginPath();
        for (int i = 0; i <= steps; ++i) {
            const double a = (startAngle + (endAngle - startAngle) * i / steps) * M_PI / 180.0;
            this->Element(i == 0 ? VB_PATH_MOVE : VB_PATH_LINE, { float(xc + rx * cos(a)), float(yc - ry * sin(a)) });
        }
        this->EndPath(start, VB_FLAG_STROKE);
    }

    void DrawQuadBezierPath(Point bezier[3]) override
    {
        const int start = this->BeginPath();
        this->Element(VB_PATH_MOVE, { float(bezier[0].x), float(bezier[0].y) });
        this->Element(
            VB_PATH_QUAD, { float(bezier[1].x), float(bezier[1].y), float(bezier[2].x), float(bezier[2].y) });
        this->EndPath(start, VB_FLAG_STROKE | VB_FLAG_ROUND_CAP | VB_FLAG_ROUND_JOIN);
    }

    void DrawCubicBezierPath(Point bezier[4]) override
    {
        const int start = this->BeginPath();
        this->Element(VB_PATH_MOVE, { float(bezier[0].x), float(bezier[0].y) });
        this->Cubic(bezier[1], bezier[2], bezier[3]);
        this->EndPath(start, VB_FLAG_STROKE | VB_FLAG_ROUND_CAP | VB_FLAG_ROUND_JOIN);
    }

    void DrawCubicBezierPathFilled(Point bezier1[4], Point bezier2[4]) override
    {
        // Slurs and ties: the outer curve out, the inner curve back.
        const int start = this->BeginPath();
        this->Element(VB_PATH_MOVE, { float(bezier1[0].x), float(bezier1[0].y) });
        this->Cubic(bezier1[1], bezier1[2], bezier1[3]);
        this->Cubic(bezier2[2], bezier2[1], bezier2[0]);
        this->Element(VB_PATH_CLOSE, {});
        this->EndPath(start, VB_FLAG_FILL | this->StrokeIfWidth() | VB_FLAG_ROUND_CAP | VB_FLAG_ROUND_JOIN);
    }

    void DrawBentParallelogramFilled(Point side[4], int height) override
    {
        const int start = this->BeginPath();
        this->Element(VB_PATH_MOVE, { float(side[0].x), float(side[0].y) });
        this->Cubic(side[1], side[2], side[3]);
        this->Element(VB_PATH_LINE, { float(side[3].x), float(side[3].y + height) });
        this->Cubic(Point(side[2].x, side[2].y + height), Point(side[1].x, side[1].y + height),
            Point(side[0].x, side[0].y + height));
        this->Element(VB_PATH_CLOSE, {});
        this->EndPath(start, VB_FLAG_FILL | this->StrokeIfWidth() | VB_FLAG_ROUND_CAP | VB_FLAG_ROUND_JOIN);
    }

    // MARK: Music glyphs

    void DrawMusicText(const std::u32string &text, int x, int y, bool setSmuflGlyph) override
    {
        const Resources *resources = this->GetResources();
        if (!resources || m_fontStack.empty()) return;
        const FontInfo *font = m_fontStack.top();

        for (char32_t c : text) {
            const Glyph *glyph = resources->GetGlyph(c);
            if (!glyph) continue;

            VBCommand cmd = this->MakeCommand(VB_CMD_GLYPH);
            cmd.size = font->GetPointSize();
            cmd.codepoint = uint32_t(c);

            int gx, gy, w, h;
            glyph->GetBoundingBox(gx, gy, w, h);
            const double k = double(font->GetPointSize()) / glyph->GetUnitsPerEm();
            float left = float(x + gx * k), top = float(y - (gy + h) * k); // glyph boxes are y-up
            float right = left + float(w * k), bottom = top + float(h * k);
            float ox = x, oy = y;
            if (this->Rotated()) {
                // The ink box turns with the glyph: keep the box around its four corners.
                float xs[4] = { left, right, right, left }, ys[4] = { top, top, bottom, bottom };
                for (int i = 0; i < 4; ++i) this->Turn(xs[i], ys[i]);
                left = *std::min_element(xs, xs + 4);
                right = *std::max_element(xs, xs + 4);
                top = *std::min_element(ys, ys + 4);
                bottom = *std::max_element(ys, ys + 4);
                this->Turn(ox, oy);
                cmd.rotation = float(m_owners.back().angle);
            }
            cmd.x = ox;
            cmd.y = oy;
            cmd.bounds[0] = left;
            cmd.bounds[1] = top;
            cmd.bounds[2] = right - left;
            cmd.bounds[3] = bottom - top;
            commands.push_back(cmd);

            if (glyph->GetHorizAdvX() > 0) {
                x += glyph->GetHorizAdvX() * font->GetPointSize() / glyph->GetUnitsPerEm();
            }
            else {
                x += w * font->GetPointSize() / glyph->GetUnitsPerEm();
            }
        }
    }

    // MARK: Text — runs inside StartText/EndText form positioned blocks

    void StartText(int x, int y, data_HORIZONTALALIGNMENT alignment) override
    {
        m_textX = x;
        m_textY = y;
        m_textAlignment = alignment;
        m_newTextBlock = true;
    }
    void MoveTextTo(int x, int y, data_HORIZONTALALIGNMENT alignment) override
    {
        m_textX = x;
        m_textY = y;
        if (alignment != HORIZONTALALIGNMENT_NONE) m_textAlignment = alignment;
        m_newTextBlock = true;
    }
    void MoveTextVerticallyTo(int y) override
    {
        m_textY = y;
        m_newTextBlock = true;
    }
    void EndText() override {}

    void DrawText(const std::string &text, const std::u32string &wtext, int x, int y, int width, int height) override
    {
        if (m_fontStack.empty()) return;
        const FontInfo *font = m_fontStack.top();
        const std::string utf8 = text.empty() ? ToUTF8(wtext) : text;
        if (utf8.empty()) return;

        VBCommand cmd = this->MakeCommand(VB_CMD_TEXT);
        cmd.x = m_textX;
        cmd.y = m_textY;
        cmd.size = font->GetPointSize();
        cmd.alignment = (m_textAlignment == HORIZONTALALIGNMENT_center) ? 1
            : (m_textAlignment == HORIZONTALALIGNMENT_right)             ? 2
                                                                         : 0;
        if (font->GetStyle() == FONTSTYLE_italic || font->GetStyle() == FONTSTYLE_oblique) cmd.flags |= VB_FLAG_ITALIC;
        if (font->GetWeight() == FONTWEIGHT_bold) cmd.flags |= VB_FLAG_BOLD;
        if (font->GetSmuflFont() != SMUFL_NONE) cmd.flags |= VB_FLAG_SMUFL_TEXT;
        if (m_newTextBlock) cmd.flags |= VB_FLAG_NEW_TEXT_BLOCK;
        m_newTextBlock = false;
        cmd.fontIndex = this->Intern(fontNames, m_fontIndex, font->GetFaceName());
        cmd.start = int32_t(textBytes.size());
        cmd.count = int32_t(utf8.size());
        textBytes += utf8;
        commands.push_back(cmd);
    }

private:
    struct Owner {
        int staff;
        int classIndex;
        int commandStart; // first command drawn inside this graphic
        int sourceIndex; // editable text element (dir, tempo, reh) this graphic belongs to, or -1
        bool rotated = false; // RotateGraphic: turned by angle (degrees, clockwise) about cx, cy
        double angle = 0, cx = 0, cy = 0;
    };

    bool Rotated() const { return !m_owners.empty() && m_owners.back().rotated; }

    /// Applies the current graphic's rotation to a point.
    void Turn(float &x, float &y) const
    {
        const Owner &o = m_owners.back();
        const double a = o.angle * M_PI / 180.0, dx = x - o.cx, dy = y - o.cy;
        x = float(o.cx + dx * cos(a) - dy * sin(a));
        y = float(o.cy + dx * sin(a) + dy * cos(a));
    }
    std::vector<Owner> m_owners;
    std::map<std::string, int> m_classIndex;
    std::map<std::string, int> m_fontIndex;
    std::map<std::string, int> m_sourceIndex;
    int m_textX = 0, m_textY = 0;
    data_HORIZONTALALIGNMENT m_textAlignment = HORIZONTALALIGNMENT_left;
    bool m_newTextBlock = true;

    static int StaffNumberFor(Object *object)
    {
        if (object->Is(STAFF)) return vrv_cast<Staff *>(object)->GetN();

        // Floating elements (slurs, dynamics, hairpins, directions…) are drawn outside the staff
        // group, but Verovio sets their current positioner to the staff being drawn.
        if (FloatingObject *floating = dynamic_cast<FloatingObject *>(object)) {
            FloatingPositioner *positioner = floating->GetCurrentFloatingPositioner();
            if (positioner && positioner->GetAlignment() && positioner->GetAlignment()->GetStaff()) {
                return positioner->GetAlignment()->GetStaff()->GetN();
            }
        }
        if (Object *staff = object->GetFirstAncestor(STAFF)) return vrv_cast<Staff *>(staff)->GetN();
        return -1; // inherit
    }

    void Push(Object *object)
    {
        int staff = StaffNumberFor(object);
        if (staff < 0) staff = m_owners.empty() ? 0 : m_owners.back().staff;
        const int cls = this->Intern(classNames, m_classIndex, object->GetClassName());
        int source = m_owners.empty() ? -1 : m_owners.back().sourceIndex;
        if (object->Is(DIR) || object->Is(TEMPO) || object->Is(REH)) {
            source = this->Intern(sourceIds, m_sourceIndex, object->GetID());
        }
        Owner owner{ staff, cls, int(commands.size()), source };
        if (this->Rotated()) { // nested graphics turn with the one they are in
            const Owner &parent = m_owners.back();
            owner.rotated = true;
            owner.angle = parent.angle;
            owner.cx = parent.cx;
            owner.cy = parent.cy;
        }
        m_owners.push_back(owner);
    }
    void Pop()
    {
        if (!m_owners.empty()) m_owners.pop_back();
    }

    static int Intern(std::vector<std::string> &table, std::map<std::string, int> &index, const std::string &name)
    {
        auto it = index.find(name);
        if (it != index.end()) return it->second;
        const int i = int(table.size());
        table.push_back(name);
        index[name] = i;
        return i;
    }

    VBCommand MakeCommand(int kind)
    {
        VBCommand cmd = {};
        cmd.kind = kind;
        cmd.staff = m_owners.empty() ? 0 : m_owners.back().staff;
        cmd.classIndex = m_owners.empty() ? -1 : m_owners.back().classIndex;
        cmd.sourceIndex = m_owners.empty() ? -1 : m_owners.back().sourceIndex;
        return cmd;
    }

    int BeginPath() const { return int(pathElements.size()); }

    void Element(int op, std::initializer_list<float> values)
    {
        VBPathElement el = {};
        el.op = op;
        int i = 0;
        for (float v : values) el.p[i++] = v;
        if (this->Rotated()) {
            if (op == VB_PATH_ELLIPSE) {
                // Turn the centre; a quarter turn swaps width and height (Verovio only turns by those).
                float cx = el.p[0] + el.p[2] / 2, cy = el.p[1] + el.p[3] / 2;
                this->Turn(cx, cy);
                if (std::fmod(std::fabs(m_owners.back().angle), 180.0) > 45.0) std::swap(el.p[2], el.p[3]);
                el.p[0] = cx - el.p[2] / 2;
                el.p[1] = cy - el.p[3] / 2;
            }
            else {
                for (int j = 0; j + 1 < i; j += 2) this->Turn(el.p[j], el.p[j + 1]);
            }
        }
        pathElements.push_back(el);
    }

    void Cubic(Point c1, Point c2, Point end)
    {
        this->Element(VB_PATH_CUBIC,
            { float(c1.x), float(c1.y), float(c2.x), float(c2.y), float(end.x), float(end.y) });
    }

    int FillFlag() const
    {
        // Like SVG, shapes are filled unless the brush is fully transparent.
        const Brush &brush = m_brushStack.top();
        return (brush.HasOpacity() && brush.GetOpacity() == 0.0f) ? 0 : VB_FLAG_FILL;
    }

    int StrokeIfWidth() const { return m_penStack.top().GetWidth() > 0 ? VB_FLAG_STROKE : 0; }

    void EndPath(int start, int flags)
    {
        const Pen &pen = m_penStack.top();
        VBCommand cmd = this->MakeCommand(VB_CMD_PATH);
        cmd.flags = flags;
        cmd.strokeWidth = std::max(pen.GetWidth(), 1);
        if (pen.GetLineCap() == LINECAP_ROUND) cmd.flags |= VB_FLAG_ROUND_CAP;
        if (pen.GetLineCap() == LINECAP_SQUARE) cmd.flags |= VB_FLAG_SQUARE_CAP;
        if (pen.GetLineJoin() == LINEJOIN_ROUND) cmd.flags |= VB_FLAG_ROUND_JOIN;
        if (pen.GetLineJoin() == LINEJOIN_BEVEL) cmd.flags |= VB_FLAG_BEVEL_JOIN;
        if (pen.GetDashLength() > 0) {
            cmd.dash = pen.GetDashLength();
            cmd.gap = pen.GetGapLength() > 0 ? pen.GetGapLength() : pen.GetDashLength();
        }
        cmd.start = start;
        cmd.count = int32_t(pathElements.size()) - start;
        commands.push_back(cmd);
    }

    // MARK: Layout metadata

    void RecordSignature(Object *object)
    {
        if (m_owners.empty()) return;
        const Owner &owner = m_owners.back();
        VBSignature sig = {};
        sig.staff = owner.staff;
        sig.commandStart = owner.commandStart;
        sig.commandCount = int32_t(commands.size()) - owner.commandStart;
        bool found = false;
        for (int i = owner.commandStart; i < int(commands.size()); ++i) {
            if (commands[i].kind != VB_CMD_GLYPH) continue;
            sig.x = found ? std::min(sig.x, commands[i].x) : commands[i].x;
            found = true;
        }
        // A key signature can draw nothing and still change the key in force: a change to C major
        // or an atonal key (Verovio draws no cancelling naturals there), or a hidden one. It is
        // recorded where it stands, as no accidentals: what the score shows from there on.
        const bool emptyKey = !found && object->Is(KEYSIG);
        if (emptyKey) sig.x = float(vrv_cast<const KeySig *>(object)->GetDrawingX());
        if ((!found && !emptyKey) || sig.staff <= 0) return;

        if (object->Is(CLEF)) {
            const Clef *clef = vrv_cast<const Clef *>(object);
            sig.kind = VB_SIG_CLEF;
            sig.shape = int32_t(clef->GetShape());
            sig.line = clef->GetLine();
            const int steps = clef->GetDis() == OCTAVE_DIS_8 ? 1 : clef->GetDis() == OCTAVE_DIS_15 ? 2 : 0;
            sig.octave = clef->GetDisPlace() == STAFFREL_basic_below ? -steps : steps;
        }
        else if (object->Is(METERSIG)) {
            const MeterSig *meter = vrv_cast<const MeterSig *>(object);
            sig.kind = VB_SIG_METER;
            sig.count = meter->GetTotalCount();
            sig.unit = meter->HasUnit() ? meter->GetUnit() : meter->GetSymImplicitUnit();
            sig.symbol = meter->HasSym() && meter->GetForm() != METERFORM_num ? int32_t(meter->GetSymbolGlyph()) : 0;
            // An additive numerator ("2+2+3") as written; anything else as its total.
            const auto &[counts, sign] = meter->GetCount();
            if (sign == MeterCountSign::Plus && counts.size() > 1 && counts.size() <= 4) {
                for (int count : counts) sig.summands[sig.summandCount++] = count;
            }
            else {
                sig.summands[0] = sig.count;
                sig.summandCount = 1;
            }
        }
        else {
            sig.kind = VB_SIG_KEY;
            sig.fifths = emptyKey ? 0 : vrv_cast<const KeySig *>(object)->GetFifthsInt();
        }
        signatures.push_back(sig);
    }

    void RecordStaff(Staff *staff, View *view)
    {
        for (const VBStaffInfo &info : staves) {
            if (info.n == staff->GetN()) return; // one system: first occurrence is enough
        }
        Doc *doc = vrv_cast<Doc *>(staff->GetFirstAncestor(DOC));
        const int doubleUnit = doc->GetDrawingDoubleUnit(staff->m_drawingStaffSize);
        if (staffSpace == 0) staffSpace = doc->GetDrawingDoubleUnit(100);

        VBStaffInfo info;
        info.n = staff->GetN();
        info.top = view->ToDeviceContextY(staff->GetDrawingY());
        info.lines = staff->m_drawingLines;
        info.height = float(doubleUnit * std::max(0, staff->m_drawingLines - 1));
        staves.push_back(info);
    }

    void RecordMeasure(Measure *measure)
    {
        const int x0 = measure->GetDrawingX();
        VBMeasureInfo info;
        info.left = x0 + measure->GetLeftBarLineXRel();
        info.right = x0 + measure->GetRightBarLineXRel();
        const Alignment *end = measure->m_measureAligner.GetRightBarLineAlignment();
        info.duration = end ? end->GetTime().ToDouble() * kQuarterNotesPerWhole : 0;
        info.onsetStart = int32_t(onsets.size());

        double lastTime = -1;
        for (const Object *child : measure->m_measureAligner.GetChildren()) {
            const Alignment *alignment = vrv_cast<const Alignment *>(child);
            if (alignment->GetType() != ALIGNMENT_DEFAULT && alignment->GetType() != ALIGNMENT_FULLMEASURE
                && alignment->GetType() != ALIGNMENT_FULLMEASURE2) {
                continue;
            }
            const double time = alignment->GetTime().ToDouble() * kQuarterNotesPerWhole;
            if (time <= lastTime) continue; // grace notes share or precede their main time
            lastTime = time;
            onsets.push_back({ time, float(x0 + alignment->GetXRel()) });
        }
        info.onsetCount = int32_t(onsets.size()) - info.onsetStart;
        measures.push_back(info);
    }
};

} // namespace

struct VBEngraver {
    Toolkit toolkit;
    RecordingDeviceContext *dc = nullptr;
    std::string log;
    float pageWidth = 0;

    VBEngraver() : toolkit(false) {}
    ~VBEngraver() { delete dc; }
};

extern "C" {

int32_t vb_struct_size(int32_t which)
{
    switch (which) {
        case VB_STRUCT_COMMAND: return sizeof(VBCommand);
        case VB_STRUCT_PATH_ELEMENT: return sizeof(VBPathElement);
        case VB_STRUCT_STAFF_INFO: return sizeof(VBStaffInfo);
        case VB_STRUCT_MEASURE_INFO: return sizeof(VBMeasureInfo);
        case VB_STRUCT_ONSET: return sizeof(VBOnset);
        case VB_STRUCT_SIGNATURE: return sizeof(VBSignature);
        default: return -1;
    }
}

VBEngraver *vb_engraver_create(const char *resourcePath)
{
    VBEngraver *engraver = new VBEngraver();
    if (!engraver->toolkit.SetResourcePath(resourcePath)) {
        delete engraver;
        return nullptr;
    }
    // One endless system, no header/footer: the curated view scrolls horizontally.
    engraver->toolkit.SetOptions(R"({
        "breaks": "none",
        "header": "none",
        "footer": "none",
        "adjustPageHeight": true,
        "font": "Bravura",
        "fontFallback": "Bravura",
        "scale": 100,
        "pageMarginLeft": 0,
        "pageMarginRight": 0,
        "pageMarginTop": 0,
        "pageMarginBottom": 0,
        "spacingStaff": 12,
        "mnumInterval": 0
    })");
    return engraver;
}

void vb_engraver_destroy(VBEngraver *engraver) { delete engraver; }

bool vb_engraver_set_options(VBEngraver *engraver, const char *json) { return engraver->toolkit.SetOptions(json); }

bool vb_engraver_load_data(VBEngraver *engraver, const char *data) { return engraver->toolkit.LoadData(data); }

bool vb_engraver_render(VBEngraver *engraver)
{
    delete engraver->dc;
    engraver->dc = new RecordingDeviceContext();
    if (engraver->toolkit.GetPageCount() < 1) return false;
    const bool ok = engraver->toolkit.RenderToDeviceContext(1, engraver->dc);
    engraver->pageWidth = engraver->dc->GetWidth();
    return ok;
}

const char *vb_engraver_available_options(VBEngraver *engraver)
{
    engraver->log = engraver->toolkit.GetAvailableOptions();
    return engraver->log.c_str();
}

const char *vb_engraver_log(VBEngraver *engraver)
{
    engraver->log = engraver->toolkit.GetLog();
    return engraver->log.c_str();
}

float vb_page_width(const VBEngraver *engraver) { return engraver->pageWidth; }
float vb_staff_space(const VBEngraver *engraver) { return engraver->dc ? engraver->dc->staffSpace : 0; }

#define VB_TABLE(name, field)                                                                                         \
    int32_t vb_##name##_count(const VBEngraver *engraver)                                                              \
    {                                                                                                                  \
        return engraver->dc ? int32_t(engraver->dc->field.size()) : 0;                                                 \
    }

VB_TABLE(command, commands)
VB_TABLE(path_element, pathElements)
VB_TABLE(class_name, classNames)
VB_TABLE(font_name, fontNames)
VB_TABLE(staff, staves)
VB_TABLE(measure, measures)
VB_TABLE(onset, onsets)
VB_TABLE(signature, signatures)
VB_TABLE(source_id, sourceIds)

const VBCommand *vb_commands(const VBEngraver *engraver) { return engraver->dc ? engraver->dc->commands.data() : nullptr; }
const VBPathElement *vb_path_elements(const VBEngraver *engraver)
{
    return engraver->dc ? engraver->dc->pathElements.data() : nullptr;
}
int32_t vb_text_byte_count(const VBEngraver *engraver) { return engraver->dc ? int32_t(engraver->dc->textBytes.size()) : 0; }
const char *vb_text_bytes(const VBEngraver *engraver) { return engraver->dc ? engraver->dc->textBytes.data() : nullptr; }
// A name from one of the recording's tables; "" (never a crash across the C boundary) when
// nothing is recorded or the index is out of range.
static const char *Name(const VBEngraver *engraver, std::vector<std::string> RecordingDeviceContext::*table, int32_t index)
{
    if (!engraver->dc) return "";
    const std::vector<std::string> &names = engraver->dc->*table;
    return (index >= 0 && index < int32_t(names.size())) ? names[index].c_str() : "";
}

const char *vb_class_name(const VBEngraver *engraver, int32_t index)
{
    return Name(engraver, &RecordingDeviceContext::classNames, index);
}
const char *vb_font_name(const VBEngraver *engraver, int32_t index)
{
    return Name(engraver, &RecordingDeviceContext::fontNames, index);
}
const char *vb_source_id(const VBEngraver *engraver, int32_t index)
{
    return Name(engraver, &RecordingDeviceContext::sourceIds, index);
}
const VBStaffInfo *vb_staves(const VBEngraver *engraver) { return engraver->dc ? engraver->dc->staves.data() : nullptr; }
const VBMeasureInfo *vb_measures(const VBEngraver *engraver)
{
    return engraver->dc ? engraver->dc->measures.data() : nullptr;
}
const VBOnset *vb_onsets(const VBEngraver *engraver) { return engraver->dc ? engraver->dc->onsets.data() : nullptr; }
const VBSignature *vb_signatures(const VBEngraver *engraver)
{
    return engraver->dc ? engraver->dc->signatures.data() : nullptr;
}

} // extern "C"
