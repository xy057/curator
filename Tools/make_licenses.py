#!/usr/bin/env python3
"""Gathers the licences of the libraries the app ships compiled, which pub knows nothing of:
Verovio (and the libraries embedded in it) and PDFium (and those built into it).

They go into packages/score_engine/assets/licenses/ as one text file a library, its parts set
apart by a line of dashes; the app adds each file to its licence page (main.dart). Run it
again when Verovio's tag (Makefile) or PDFium's release (hook/build.dart) changes, from the
repository root, after `make setup`, with the PDFium archive the hook fetches:
  python3 Tools/make_licenses.py pdfium-mac-arm64.tgz
"""
import pathlib
import re
import sys
import tarfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
VEROVIO = ROOT / "packages/score_engine/third_party/verovio"
OUT = ROOT / "packages/score_engine/assets/licenses"
RULE = "-" * 80

BSD2 = """Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   and the following disclaimer in the documentation and/or other materials
   provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."""


def text(data: bytes) -> str:
    """A licence as UTF-8 text with LF line ends (FreeType's is Latin-1, Windows' have CRLF)."""
    try:
        s = data.decode("utf-8-sig")
    except UnicodeDecodeError:
        s = data.decode("latin-1")
    return "\n".join(line.rstrip() for line in s.replace("\r\n", "\n").split("\n")).strip()


def comment(path: pathlib.Path, first: str, last: str) -> str:
    """The notice in a source file's comment, from the line holding [first] to the one holding
    [last], without the comment marks."""
    lines = text(path.read_bytes()).split("\n")
    start = next(i for i, line in enumerate(lines) if first in line)
    end = next(i for i in range(start, len(lines)) if last in lines[i])
    return "\n".join(re.sub(r"^\s*(//|/?\*+/?)\s?", "", line).rstrip() for line in lines[start : end + 1]).strip()


def write(name: str, parts: list[tuple[str, str]]) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    body = f"\n{RULE}\n".join(f"{title}\n\n{licence}" for title, licence in parts)
    (OUT / name).write_text(body + "\n", encoding="utf-8")
    print(f"{name}: {len(parts)} parts, {len(body) // 1024} KB")


def verovio() -> None:
    tag = re.search(r"^VEROVIO_TAG := (\S+)", (ROOT / "Makefile").read_text(), re.M).group(1)
    inc = VEROVIO / "include"
    write("Verovio.txt", [
        (f"Verovio ({tag}), https://www.verovio.org\n"
         "Copyright (c) Authors and others. All rights reserved.\n\n"
         "Verovio is free software under the GNU Lesser General Public License, version 3 or\n"
         "(at your option) any later version, which follows; it adds to the GNU General Public\n"
         "License, version 3, which comes after it. Curator's changes to Verovio are the patches\n"
         "in its source, https://github.com/xy057/curator (patches/).",
         text((VEROVIO / "COPYING.LESSER").read_bytes())),
        ("GNU General Public License, version 3 (Verovio)", text((VEROVIO / "COPYING").read_bytes())),
        ("humlib (in Verovio), https://github.com/craigsapp/humlib",
         comment(inc / "hum/humlib.h", "Copyright (c) 2015", "EVEN IF ADVISED")),
        # Its sources carry no notice of their own: the licence of its repository (LICENSE.txt).
        ("MidiFile (in Verovio), https://github.com/craigsapp/midifile",
         f"Copyright (c) 1999-2018, Craig Stuart Sapp\nAll rights reserved.\n\n{BSD2}"),
        ("pugixml (in Verovio), https://pugixml.org",
         comment(inc / "pugi/pugixml.hpp", "Copyright (c) 2006", "OTHER DEALINGS IN THE SOFTWARE")),
        ("JSON++ (in Verovio), https://github.com/hjiang/jsonxx", text((inc / "json/LICENSE").read_bytes())),
        ("MINIZ-CPP (in Verovio), https://github.com/kkzi/miniz-cpp",
         comment(inc / "zip/zip_file.hpp", "Copyright (c) 2014-2017 Thomas Fussell", "THE SOFTWARE")),
        ("miniz (in Verovio), https://github.com/richgel999/miniz",
         comment(inc / "zip/zip_file.hpp", "Copyright 2013-2014 RAD Game Tools", "THE SOFTWARE.")),
        ("tuning-library (in Verovio), https://github.com/surge-synthesizer/tuning-library",
         text((inc / "tuning-library/LICENSE.md").read_bytes())),
        ("CRC (in Verovio)", comment(inc / "crc/crc.h", "Copyright (c) 2000 by Michael Barr", "publication or distribution")),
    ])


def pdfium(archive: str) -> None:
    with tarfile.open(archive) as tar:
        def read(name: str) -> bytes:
            return tar.extractfile(name).read()

        version = dict(line.split("=") for line in text(read("VERSION")).split("\n"))
        names = sorted(n for n in tar.getnames() if n.startswith("licenses/") and n != "licenses")
        first = "licenses/pdfium.txt"
        parts = [
            (f"PDFium (chromium/{version['BUILD']}), https://pdfium.googlesource.com/pdfium\n"
             "As built by pdfium-binaries, https://github.com/bblanchon/pdfium-binaries",
             re.sub(r"^// ?", "", text(read(first)), flags=re.M)),
            ("pdfium-binaries (the build of PDFium)", text(read("LICENSE"))),
        ]
        for name in names:
            if name == first:
                continue
            title = pathlib.PurePosixPath(name).name.rsplit(".", 1)[0]
            if name.endswith(".ijg"):
                title += " (IJG)"
            parts.append((f"{title} (in PDFium)", text(read(name))))
    write("PDFium.txt", parts)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    verovio()
    pdfium(sys.argv[1])
