#!/usr/bin/env python3
"""Writes app/lib/musicxml_schema.dart: what the MusicXML editor offers as MusicXML is typed (each
element's children, attributes and their values, and the values of its text), read from the
MusicXML 4.0 schema.

The schema is the W3C Music Notation Community Group's (schema/musicxml.xsd in github.com/w3c/musicxml,
tag v4.0; Dorico, MuseScore and others ship a copy). Only names and values are taken from it, never
its documentation. Run from the repository root:
  python3 -I Tools/make_musicxml_schema.py path/to/musicxml.xsd

An element is known by its name: where the schema gives one name two types in two places (<line> in
a clef, in a staff tuning), what both hold is offered.
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

OUT = Path('app/lib/musicxml_schema.dart')
XS = '{http://www.w3.org/2001/XMLSchema}'

# Values the schema leaves as a string but writes in its documentation: offered all the same.
TEXT_EXTRAS = {
    'mode': ['major', 'minor', 'dorian', 'phrygian', 'lydian', 'mixolydian', 'aeolian', 'ionian', 'locrian', 'none'],
}
# Empty more often than not, though what they hold may be written: put in as <rest/>.
EMPTY_EXTRAS = {'rest'}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = ET.parse(sys.argv[1]).getroot()
    version = next((d.text or '' for d in root.iter(f'{XS}documentation')), '').split('\n\nVersion ')[-1].split('\n')[0]
    if not version.startswith('4.'):
        sys.exit(f'{sys.argv[1]}: not the MusicXML 4 schema (version {version!r})')

    simple = {t.get('name'): t for t in root.findall(f'{XS}simpleType')}
    complex_ = {t.get('name'): t for t in root.findall(f'{XS}complexType')}
    groups = {g.get('name'): g for g in root.findall(f'{XS}group')}
    attribute_groups = {g.get('name'): g for g in root.findall(f'{XS}attributeGroup')}

    def enumeration(type_name, seen=()):
        """The values a simple type allows, if it lists them (a union: all its members')."""
        if type_name is None or type_name.startswith('xs:') or type_name in seen:
            return []
        t = simple.get(type_name)
        if t is None:
            return []
        return enumeration_of(t, seen + (type_name,))

    def enumeration_of(t, seen=()):
        out = []
        for r in t.findall(f'{XS}restriction'):
            values = [e.get('value') for e in r.findall(f'{XS}enumeration')]
            out += values if values else enumeration(r.get('base'), seen)
        for u in t.findall(f'{XS}union'):
            for member in (u.get('memberTypes') or '').split():
                out += enumeration(member, seen)
            for inner in u.findall(f'{XS}simpleType'):
                out += enumeration_of(inner, seen)
        return out

    def attributes_of(node, seen=()):
        """(name, type) of each attribute [node] declares, attribute groups opened."""
        out = []
        for child in node:
            if child.tag == f'{XS}attribute':
                name = child.get('name') or child.get('ref')
                inline = child.find(f'{XS}simpleType')
                out.append((name, inline if inline is not None else child.get('type')))
            elif child.tag == f'{XS}attributeGroup':
                ref = child.get('ref')
                if ref in attribute_groups and ref not in seen:
                    out += attributes_of(attribute_groups[ref], seen + (ref,))
        return out

    def particles(node, seen=()):
        """(name, element) of each element [node]'s content may hold, in order, groups opened."""
        out = []
        for child in node:
            if child.tag == f'{XS}element':
                out.append((child.get('name') or child.get('ref'), child))
            elif child.tag in (f'{XS}sequence', f'{XS}choice', f'{XS}all'):
                out += particles(child, seen)
            elif child.tag == f'{XS}group':
                ref = child.get('ref')
                if ref in groups and ref not in seen:
                    out += particles(groups[ref], seen + (ref,))
        return out

    elements = {}  # name -> {'children': [], 'attributes': {name: values}, 'text': [], 'empty': bool, 'texty': bool}

    def entry(name):
        return elements.setdefault(name, {'children': [], 'attributes': {}, 'text': [], 'empty': True, 'texty': False})

    def take(name, type_node, done):
        """Element [name] of type [type_node] (a complexType, or a simple type's name)."""
        e = entry(name)
        key = (name, id(type_node) if not isinstance(type_node, str) else type_node)
        if key in done:
            return
        done.add(key)
        if isinstance(type_node, str) or type_node is None:
            # A simple type: text only.
            e['empty'] = False
            e['texty'] = True
            e['text'] += enumeration(type_node)
            return
        if type_node.tag == f'{XS}simpleType':
            e['empty'] = False
            e['texty'] = True
            e['text'] += enumeration_of(type_node)
            return
        body = type_node
        for content in type_node.findall(f'{XS}simpleContent') + type_node.findall(f'{XS}complexContent'):
            for ext in content.findall(f'{XS}extension') + content.findall(f'{XS}restriction'):
                base = ext.get('base')
                if content.tag == f'{XS}simpleContent':
                    e['empty'] = False
                    e['texty'] = True
                    if base in complex_:
                        take(name, complex_[base], done)
                    else:
                        e['text'] += enumeration(base)
                elif base in complex_:
                    take(name, complex_[base], done)
                body = ext
        for attribute, type_ in attributes_of(body):
            values = enumeration_of(type_) if not isinstance(type_, str) and type_ is not None else enumeration(type_)
            known = e['attributes'].setdefault(attribute, [])
            known += [v for v in values if v not in known]
        for child, element in particles(body):
            if child not in e['children']:
                e['children'].append(child)
            e['empty'] = False
            inline = element.find(f'{XS}complexType')
            if inline is None:
                inline = element.find(f'{XS}simpleType')
            named = complex_.get(element.get('type'))
            take(child, inline if inline is not None else named if named is not None else element.get('type'), done)

    # A partwise score only: what the editor edits (a timewise one's <measure> holds parts).
    done = set()
    top = next(e for e in root.findall(f'{XS}element') if e.get('name') == 'score-partwise')
    take('score-partwise', top.find(f'{XS}complexType'), done)

    for name, values in TEXT_EXTRAS.items():
        elements[name]['text'] += [v for v in values if v not in elements[name]['text']]

    # Each list of values once, by its place: an attribute or a text names its list.
    enums = []

    def enum_index(values):
        unique = [v for v in dict.fromkeys(values) if v]  # '' (nothing written) is offered as nothing
        if not unique:
            return None
        if unique not in enums:
            enums.append(unique)
        return enums.index(unique)

    lines = []
    for name in sorted(elements):
        e = elements[name]
        attrs = []
        for attribute, values in e['attributes'].items():
            k = enum_index(values)
            attrs.append(attribute if k is None else f'{attribute}={k}')
        k = enum_index(e['text'])
        if name in EMPTY_EXTRAS or (e['empty'] and not e['texty']):
            text = '/'
        elif k is not None:
            text = f'={k}'
        else:
            text = ''
        lines.append((name, ' '.join(e['children']), ' '.join(attrs), text))

    out = [
        '// Generated by Tools/make_musicxml_schema.py from the MusicXML 4.0 schema: do not edit by hand.',
        "part of 'musicxml_language.dart';",
        '',
        '/// Each MusicXML element by its name: the elements it holds (in the order the schema has them), its',
        "/// attributes (`name=k`: its values are [_values]' k-th list) and what its text is (`=k`: one of",
        '/// [_values]\' k-th list; `/`: it holds nothing, written `<name/>`; empty: any text, or none).',
        'const _elements = <String, (String, String, String)>{',
    ]
    for name, children, attrs, text in lines:
        out.append(f"  '{name}': ({quote(children)}, {quote(attrs)}, '{text}'),")
    out += ['};', '', '/// The lists of values attributes and texts take, each once, separated by `|`.', 'const _values = <String>[']
    for values in enums:
        out.append(f"  {quote('|'.join(values))},")
    out += ['];', '']
    OUT.write_text('\n'.join(out))
    print(f'{OUT}: {len(lines)} elements, {len(enums)} lists of values (MusicXML {version})')


def quote(text):
    return "'" + text.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$') + "'"


if __name__ == '__main__':
    main()
