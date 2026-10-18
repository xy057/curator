#!/usr/bin/env python3
"""Builds the app's icons: one font per style and app/lib/app_icons.dart, which names them.

Refined draws Google's Material Symbols Rounded, Carbon draws IBM's Carbon icons (both Apache 2.0,
from their official releases). Each icon has one code point in both fonts, so AppIcon.of picks the
style's font and nothing else. Only the icons in ICONS go in. Run from the repository root:
  python3 -m venv /tmp/fonttools && /tmp/fonttools/bin/pip install fonttools
  /tmp/fonttools/bin/python Tools/make_icon_fonts.py
"""
import io
import re
import subprocess
import tarfile
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

from fontTools.fontBuilder import FontBuilder
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.recordingPen import DecomposingRecordingPen, RecordingPen
from fontTools.pens.transformPen import TransformPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.svgLib.path import parse_path
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

CARBON = '11.90.0'  # @carbon/icons
CARBON_URL = f'https://registry.npmjs.org/@carbon/icons/-/icons-{CARBON}.tgz'
SYMBOLS = '49d4db35df873165d6bd6ba09b063c7dafbac2f4'  # google/material-design-icons
SYMBOLS_URL = ('https://raw.githubusercontent.com/google/material-design-icons/{}/variablefont/'
               'MaterialSymbolsRounded%5BFILL,GRAD,opsz,wght%5D.{}')
# Refined's axes: outlined, at the optical size for 16-20 px and a weight that sits with the text.
SYMBOLS_AXES = {'GRAD': 0, 'opsz': 20, 'wght': 300}

FONTS = Path('app/assets/fonts')
DART = Path('app/lib/app_icons.dart')
FIRST = 0xE000

# name, what it is (the doc comment), Material Symbols Rounded (":fill" for its filled form), Carbon.
ICONS = [
    # Actions
    ('add', 'Adds an item.', 'add', 'add'),
    ('close', 'Closes a dialog or a panel, or removes an item.', 'close', 'close'),
    ('delete', 'Removes the selection.', 'delete', 'trash-can'),
    ('reset', 'Puts values back to their defaults.', 'restart_alt', 'reset'),
    ('copy', 'Copies to the clipboard.', 'content_copy', 'copy'),
    ('undo', 'Undoes the last change.', 'undo', 'undo'),
    ('redo', 'Redoes it.', 'redo', 'redo'),
    ('check', 'Done, or the chosen item in a menu.', 'check', 'checkmark'),
    ('search', 'Searches.', 'search', 'search'),
    ('more', "Opens an item's menu.", 'more_horiz', 'overflow-menu--horizontal'),
    ('select', "A select field's arrow.", 'unfold_more', 'chevron--down'),
    ('dropDown', "A toolbar menu's arrow.", 'arrow_drop_down', 'chevron--down'),
    ('forward', 'From one value to the next.', 'arrow_forward', 'arrow--right'),
    # Files
    ('open', 'Opens a file.', 'folder_open', 'folder--open'),
    ('drop', 'A file dragged over a drop area.', 'download', 'download'),
    ('home', 'Back to the home screen.', 'home', 'home'),
    ('project', 'A project.', 'movie_filter', 'document--video'),
    ('score', 'A MusicXML score.', 'queue_music', 'music'),
    ('demo', 'Opens the demo.', 'play_circle', 'play--outline'),
    ('export', 'Exports the video.', 'movie', 'video'),
    ('assets', "The project's assets.", 'photo_library', 'image--copy'),
    # Playback
    ('play', 'Plays.', 'play_arrow:fill', 'play--filled--alt'),
    ('pause', 'Pauses.', 'pause:fill', 'pause--filled'),
    ('toStart', 'Goes to the start.', 'skip_previous:fill', 'skip--back--filled'),
    ('speed', 'The playback speed.', 'speed', 'meter'),
    ('mute', 'No sound.', 'volume_off', 'volume--mute'),
    ('music', 'Music: a sound, the engraving.', 'music_note', 'music'),
    # Lanes
    ('pointer', 'The select tool.', 'arrow_selector_tool', 'cursor--1'),
    ('draw', 'The draw tool.', 'edit', 'edit'),
    ('erase', 'The erase tool.', 'ink_eraser', 'erase'),
    ('trimStart', 'Starts the selection at the playhead.', 'first_page', 'page--first'),
    ('trimEnd', 'Ends the selection at the playhead.', 'last_page', 'page--last'),
    ('condense', 'Condensing.', 'merge_type', 'direction--merge'),
    ('tidy', 'Tidies the lanes.', 'cleaning_services', 'clean'),
    ('autoCurate', 'Curates the lanes.', 'auto_awesome', 'magic-wand'),
    ('clearLanes', 'Clears every lane.', 'layers_clear', 'row--delete'),
    ('transition', 'Animation: how long a lane takes to come and go.', 'animation', 'fade'),
    # Audio
    ('audio', 'Audio: a recording, its panel.', 'graphic_eq', 'waveform'),
    ('addAudio', 'Adds a recording.', 'audio_file', 'document--audio'),
    ('replaceAudio', 'Replaces the recording.', 'change_circle', 'renew'),
    ('tempoMap', 'A MIDI tempo map.', 'piano', 'chart--line-smooth'),
    ('tap', 'Taps anchors in time.', 'touch_app', 'touch--1'),
    ('warp', 'A jump to another bar.', 'u_turn_left', 'direction--u-turn'),
    ('repeat', 'Warps that come from the score.', 'repeat', 'repeat'),
    ('snap', 'Snaps anchors to onsets.', 'align_horizontal_center', 'align--horizontal-center'),
    ('clearAnchors', 'Removes every anchor.', 'clear_all', 'close--outline'),
    ('leadIn', 'The silence before bar 1.', 'start', 'time'),
    # View
    ('zoomIn', 'Zooms in.', 'zoom_in', 'zoom--in'),
    ('zoomOut', 'Zooms out.', 'zoom_out', 'zoom--out'),
    ('fit', 'Fits the view.', 'fit_screen', 'fit-to-screen'),
    ('frame', "The video's frame.", 'crop_16_9', 'crop'),
    ('lanes', 'The instrument lanes.', 'view_list', 'list--boxes'),
    ('scoreSize', 'The size of the score.', 'format_size', 'text--scale'),
    # Images and captions
    ('image', 'An image.', 'image', 'image'),
    ('noImage', 'No image.', 'hide_image', 'no-image'),
    ('pin', 'Pinned in place.', 'push_pin:fill', 'pin--filled'),
    ('link', 'Linked, not copied in.', 'link', 'link'),
    ('embed', 'Copied into the project.', 'inventory_2', 'box'),
    ('captions', 'Captions.', 'subtitles', 'closed-caption'),
    # Settings
    ('settings', 'Settings.', 'settings', 'settings'),
    ('general', 'General settings.', 'tune', 'settings--adjust'),
    ('appearance', 'Appearance.', 'palette', 'color-palette'),
    ('fonts', 'Fonts.', 'text_fields', 'text--font'),
    ('extensions', 'Extensions.', 'extension', 'extensions'),
    ('flags', 'Feature flags.', 'flag', 'flag'),
    ('about', 'About.', 'info', 'information'),
    ('auto', "The system's appearance.", 'brightness_auto', 'contrast'),
    ('light', 'Light.', 'light_mode', 'light'),
    ('dark', 'Dark.', 'dark_mode', 'asleep'),
    # Status
    ('done', 'Finished.', 'check_circle:fill', 'checkmark--filled'),
    ('failed', 'Failed.', 'error:fill', 'error--filled'),
    ('invalid', 'A value that is not allowed.', 'error:fill', 'warning--filled'),
]


def fetch(url):
    return subprocess.run(['curl', '-sSfL', url], check=True, capture_output=True).stdout


def glyph(pen_draw, upm, transform):
    """Records [pen_draw] as a TrueType glyph in a [upm] square, through [transform]."""
    rec = RecordingPen()
    pen_draw(TransformPen(rec, transform))
    tt = TTGlyphPen(None)
    rec.replay(Cu2QuPen(tt, max_err=0.5, reverse_direction=False))
    bounds = BoundsPen(None)
    rec.replay(bounds)
    return tt.glyph(), bounds.bounds


# Carbon: the SVGs as released, 16 px designs where there are, the 32 px masters otherwise.
STYLE_FILL = re.compile(r'fill\s*:\s*none')


def carbon_svg(svg, pen):
    root = ET.fromstring(svg)
    classes_none = set(re.findall(r'\.([\w-]+)\s*\{[^}]*fill\s*:\s*none', svg))

    def hidden(e):
        # A filled icon's inner path is transparent: there for two-tone use, a hole here.
        return (e.get('fill') == 'none' or e.get('opacity') == '0' or e.get('data-icon-path') == 'inner-path'
                or STYLE_FILL.search(e.get('style', ''))
                or any(c in classes_none for c in e.get('class', '').split())
                or 'Transparent' in (e.get('id', '') + e.get('data-name', '')))

    def walk(e, matrix):
        tag = e.tag.split('}')[-1]
        if tag in ('defs', 'style', 'title') or hidden(e):
            return
        if e.get('transform'):
            matrix = compose(matrix, parse_transform(e.get('transform')))
        d = shape(tag, e)
        if d:
            parse_path(d, TransformPen(pen, matrix))
        for child in e:
            walk(child, matrix)

    walk(root, (1, 0, 0, 1, 0, 0))


def compose(a, b):
    a0, a1, a2, a3, a4, a5 = a
    b0, b1, b2, b3, b4, b5 = b
    return (a0 * b0 + a2 * b1, a1 * b0 + a3 * b1, a0 * b2 + a2 * b3, a1 * b2 + a3 * b3,
            a0 * b4 + a2 * b5 + a4, a1 * b4 + a3 * b5 + a5)


def parse_transform(t):
    m = (1, 0, 0, 1, 0, 0)
    for name, args in re.findall(r'(\w+)\s*\(([^)]*)\)', t):
        v = [float(x) for x in re.split(r'[\s,]+', args.strip())]
        if name == 'translate':
            step = (1, 0, 0, 1, v[0], v[1] if len(v) > 1 else 0)
        elif name == 'scale':
            step = (v[0], 0, 0, v[1] if len(v) > 1 else v[0], 0, 0)
        elif name == 'matrix':
            step = tuple(v)
        elif name == 'rotate':
            import math
            a = math.radians(v[0])
            c, s = math.cos(a), math.sin(a)
            step = (c, s, -s, c, 0, 0)
            if len(v) == 3:
                step = compose(compose((1, 0, 0, 1, v[1], v[2]), step), (1, 0, 0, 1, -v[1], -v[2]))
        else:
            raise ValueError(f'transform {name}')
        m = compose(m, step)
    return m


def shape(tag, e):
    f = lambda k: float(e.get(k, 0))  # noqa: E731
    if tag == 'path':
        return e.get('d')
    if tag == 'rect':
        x, y, w, h = f('x'), f('y'), f('width'), f('height')
        if e.get('rx') or e.get('ry'):
            raise ValueError('rounded rect')
        return f'M{x},{y}h{w}v{h}h{-w}z'
    if tag in ('circle', 'ellipse'):
        cx, cy = f('cx'), f('cy')
        rx = f('r') if tag == 'circle' else f('rx')
        ry = f('r') if tag == 'circle' else f('ry')
        return (f'M{cx - rx},{cy}a{rx},{ry} 0 1,0 {2 * rx},0a{rx},{ry} 0 1,0 {-2 * rx},0z')
    if tag in ('polygon', 'polyline'):
        return 'M' + e.get('points') + ('z' if tag == 'polygon' else '')
    if tag in ('svg', 'g'):
        return None
    raise ValueError(f'element {tag}')


def build_carbon(package):
    upm = 1024
    glyphs, metrics = {}, {}
    for i, (name, _, _, carbon) in enumerate(ICONS):
        small = package / 'svg' / '16' / f'{carbon}.svg'
        path = small if small.exists() else package / 'svg' / '32' / f'{carbon}.svg'
        svg = path.read_text()
        box = float(re.search(r'viewBox="0 0 (\d+)', svg).group(1))
        s = upm / box
        g, bounds = glyph(lambda pen: carbon_svg(svg, pen), upm, (s, 0, 0, -s, 0, upm))
        glyphs[f'u{FIRST + i:04X}'] = g
        metrics[f'u{FIRST + i:04X}'] = (upm, round(bounds[0]) if bounds else 0)
    write_font('Carbon Icons', upm, glyphs, metrics, FONTS / 'CarbonIcons.ttf',
               f'IBM Carbon icons {CARBON} (Apache 2.0), as Curator uses them')


def build_symbols(variable):
    upm = 960
    instances = {}
    for fill in (0, 1):
        font = instancer.instantiateVariableFont(TTFont(io.BytesIO(variable)), {'FILL': fill, **SYMBOLS_AXES})
        # The filled forms come in through the 'rclt' substitutions the FILL axis turns on.
        subst = {}
        if fill:
            gsub = font['GSUB'].table
            for record in gsub.FeatureList.FeatureRecord:
                if record.FeatureTag == 'rclt':
                    for index in record.Feature.LookupListIndex:
                        for table in gsub.LookupList.Lookup[index].SubTable:
                            subst.update(getattr(table, 'mapping', None) or {})
        instances[fill] = (font, subst)
    codepoints = dict(line.split() for line in SYMBOLS_CODEPOINTS.splitlines())
    glyphs, metrics = {}, {}
    for i, (name, _, symbol, _) in enumerate(ICONS):
        base, _, form = symbol.partition(':')
        font, subst = instances[1 if form == 'fill' else 0]
        source = font.getBestCmap()[int(codepoints[base], 16)]
        source = subst.get(source, source)
        gs = font.getGlyphSet()

        def draw(pen, gs=gs, source=source):
            rec = DecomposingRecordingPen(gs)
            gs[source].draw(rec)
            rec.replay(pen)

        g, bounds = glyph(draw, upm, (1, 0, 0, 1, 0, 0))
        glyphs[f'u{FIRST + i:04X}'] = g
        metrics[f'u{FIRST + i:04X}'] = (upm, round(bounds[0]) if bounds else 0)
    write_font('Material Symbols Rounded', upm, glyphs, metrics, FONTS / 'MaterialSymbolsRounded.ttf',
               f'Material Symbols Rounded (Apache 2.0) at {SYMBOLS_AXES}, as Curator uses it')


def write_font(family, upm, glyphs, metrics, path, description):
    order = ['.notdef'] + sorted(glyphs)
    glyphs = {'.notdef': TTGlyphPen(None).glyph(), **glyphs}
    metrics = {'.notdef': (upm, 0), **metrics}
    fb = FontBuilder(upm, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({int(n[1:], 16): n for n in order[1:]})
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics(metrics)
    # The em is the icon: no space above or below it.
    fb.setupHorizontalHeader(ascent=upm, descent=0)
    fb.setupNameTable({'familyName': family, 'styleName': 'Regular', 'description': description})
    fb.setupOS2(sTypoAscender=upm, sTypoDescender=0, sTypoLineGap=0, usWinAscent=upm, usWinDescent=0,
                fsType=0)
    fb.setupPost()
    fb.save(path)


def write_dart():
    out = ['// Generated by Tools/make_icon_fonts.py from its ICONS table: edit there, then run it.',
           "import 'package:flutter/widgets.dart';",
           '',
           "import 'app_colors.dart';",
           '',
           '/// The app\'s icons, by what they mean. Each style draws them from its own set: Refined from',
           '/// Material Symbols Rounded, Carbon from IBM\'s Carbon icons ([of]).',
           'enum AppIcon {']
    for i, (name, doc, symbol, carbon) in enumerate(ICONS):
        out.append(f'  /// {doc} Refined: {symbol.replace(":fill", " (filled)")}; Carbon: {carbon}.')
        out.append(f'  {name}(IconData(0x{FIRST + i:04X}, fontFamily: _refined), '
                   f'IconData(0x{FIRST + i:04X}, fontFamily: _carbon)){"," if i < len(ICONS) - 1 else ";"}')
    out += ['',
            '  const AppIcon(this.refined, this.carbon);',
            '  final IconData refined;',
            '  final IconData carbon;',
            '',
            "  static const _refined = 'Material Symbols Rounded';",
            "  static const _carbon = 'Carbon Icons';",
            '',
            '  /// This icon in [style]\'s set.',
            '  IconData forStyle(UiStyle style) => style == UiStyle.carbon ? carbon : refined;',
            '',
            '  /// This icon in the set of the style around [context].',
            '  IconData of(BuildContext context) => forStyle(AppStyle.of(context).style);',
            '}',
            '']
    DART.write_text('\n'.join(out))


SYMBOLS_CODEPOINTS = ''

if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as tmp:
        with tarfile.open(fileobj=io.BytesIO(fetch(CARBON_URL))) as tar:
            tar.extractall(tmp, filter='data')
        build_carbon(Path(tmp) / 'package')
        (FONTS / 'CarbonIcons-LICENSE.txt').write_bytes((Path(tmp) / 'package' / 'LICENSE').read_bytes())
    SYMBOLS_CODEPOINTS = fetch(SYMBOLS_URL.format(SYMBOLS, 'codepoints')).decode()
    build_symbols(fetch(SYMBOLS_URL.format(SYMBOLS, 'ttf')))
    (FONTS / 'MaterialSymbols-LICENSE.txt').write_bytes(
        fetch(f'https://raw.githubusercontent.com/google/material-design-icons/{SYMBOLS}/LICENSE'))
    write_dart()
    subprocess.run(['dart', 'format', '--line-length', '120', str(DART)], check=True)
