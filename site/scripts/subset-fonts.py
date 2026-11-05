# /// script
# requires-python = ">=3.11"
# dependencies = ["fonttools==4.60.1", "brotli==1.1.0"]
# ///
"""
Cuts the site's fonts down to what the site uses, and writes them to public/fonts.

Each face becomes two files. The core file holds ASCII, the punctuation most pages use
and every other character the built pages use, and pages preload it. The ext file holds
the rest of Latin-1 and Latin Extended-A. Its unicode-range keeps the browser from
downloading it until a page shows one of its characters. The script also writes
src/styles/fonts.css.

Run it by hand from the site folder, after a build, and commit what it writes:

    pnpm build && uv run scripts/subset-fonts.py

Run it again when:
- a page, a doc or a release note uses a new character outside ASCII. Until then the
  page downloads an ext file for it, and the text around it may move slightly. A
  character outside Latin-1 and Latin Extended-A falls back to a system font. The
  changelog comes from GitHub at build time, so check after each release. The script
  prints the characters it added to the core files.
- the CSS uses a new weight or style (FACES below).
- the CSS turns on an OpenType feature, such as tabular numbers (FEATURES below).
- a source font in fonts/ changes.
"""

import io
import re
import sys
from html.parser import HTMLParser
from pathlib import Path

from fontTools import subset
from fontTools.pens.recordingPen import DecomposingRecordingPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

SITE = Path(__file__).resolve().parent.parent
SOURCES = SITE / "fonts"
DIST = SITE / "dist"
OUTPUT = SITE / "public" / "fonts"
STYLESHEET = SITE / "src" / "styles" / "fonts.css"

# Every page's text is ASCII plus a little punctuation: no-break space, middle dot,
# en and em dashes, curly quotes, bullet (list markers) and ellipsis. The core files also
# get every other character the built pages use. The browser shapes text from two files
# separately, so a word like "Rosé" set from both loses its spacing between the two
# parts, and the rest of the line moves.
CORE = set(range(0x20, 0x7F)) | {0xA0, 0xB7, 0x2013, 0x2014, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2026}
# Kept even when no page uses them yet: Latin-1 Supplement and Latin Extended-A.
EXTENDED = set(range(0xA0, 0x100)) | set(range(0x100, 0x180))

# The features the browser applies on its own, plus tnum: the browser's own ::marker
# style sets tabular-nums, so ordered list numbers use it. The fonts also have locl, but
# only for Catalan, Moldavian, Romanian, Turkish and other languages, and every page is
# lang="en". The site sets no font-feature-settings or font-variant, so the rest (case,
# frac, ss01 and so on) never apply.
FEATURES = ["calt", "ccmp", "kern", "mark", "mkmk", "tnum"]

# Timeless Variable sets the home headline at wght 800 and stickers at 700 and 800, with
# ital and STYL at 0. Its axes stay as they are. The font leaves some point deltas for the
# browser to infer. Instancing, even fixing ital and STYL at 0, stores rounded deltas for
# them instead, and the headline's edges then render a little differently.
VF_LOCATIONS = [{"wght": 700, "ital": 0, "STYL": 0}, {"wght": 800, "ital": 0, "STYL": 0}]

# family, CSS weight, CSS style (None: the rule sets none), source, output name, axes
FACES = [
    ("Timeless Sans", "400", "normal", "TimelessSans-SansRegular.woff2", "TimelessSans-SansRegular", None),
    ("Timeless Sans", "400", "italic", "TimelessSans-SansRegularItalic.woff2", "TimelessSans-SansRegularItalic", None),
    ("Timeless Sans", "500", "normal", "TimelessSans-SansMedium.woff2", "TimelessSans-SansMedium", None),
    ("Timeless Sans", "600", "normal", "TimelessSans-SansSemibold.woff2", "TimelessSans-SansSemibold", None),
    ("Timeless Grotesk", "500", "normal", "TimelessSans-GroteskMedium.woff2", "TimelessSans-GroteskMedium", None),
    ("Timeless Grotesk", "600", "normal", "TimelessSans-GroteskSemibold.woff2", "TimelessSans-GroteskSemibold", None),
    ("Timeless Variable", "300 800", None, "TimelessSansVF.woff2", "TimelessSansVF", None),
    # Google Fonts' Geist Mono 1.701, the same build Fontsource served before. Instancing
    # it at 400 and 500 gives the same outlines and metrics as Fontsource's files.
    ("Geist Mono", "400", "normal", "GeistMono[wght].ttf", "GeistMono-Regular", {"wght": 400}),
    ("Geist Mono", "500", "normal", "GeistMono[wght].ttf", "GeistMono-Medium", {"wght": 500}),
]


class TextCollector(HTMLParser):
    """Collects the text of a page's body. Template content counts: stickers render it."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.chars, self.skip, self.in_body = set(), 0, False

    def handle_starttag(self, tag, attrs):
        if tag == "body":
            self.in_body = True
        if tag in ("script", "style"):
            self.skip += 1

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.skip -= 1

    def handle_data(self, data):
        if self.in_body and not self.skip:
            self.chars |= {ord(c) for c in data if not c.isspace() or c == "\u00a0"}


def used_characters():
    pages = list(DIST.rglob("*.html"))
    if not pages:
        sys.exit("No built pages in dist/. Run `pnpm build` first.")
    chars = set()
    for page in pages:
        collector = TextCollector()
        collector.feed(page.read_text())
        chars |= collector.chars
    # Generated content in stylesheets, such as content: "\2022".
    for sheet in DIST.rglob("*.css"):
        for value in re.findall(r'content:\s*"((?:[^"\\]|\\.)*)"', sheet.read_text()):
            value = re.sub(r"\\([0-9a-fA-F]{1,6})\s?", lambda m: chr(int(m.group(1), 16)), value)
            chars |= {ord(c) for c in value}
    return chars


def load(source, axes):
    font = TTFont(SOURCES / source)
    if axes:
        font = instantiateVariableFont(font, axes)
        # Instancing leaves unrounded coordinates. Saving rounds them, as a served file would.
        font = reload(font)
    return font


def reload(font):
    buffer = io.BytesIO()
    font.save(buffer)
    buffer.seek(0)
    return TTFont(buffer)


def cut(font, unicodes):
    options = subset.Options()
    options.layout_features = FEATURES
    options.hinting = False
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14, 16, 17, 25]
    options.flavor = "woff2"
    # Geist Mono's meta table lists design languages. Browsers do not read it.
    options.drop_tables += ["meta"]
    subsetter = subset.Subsetter(options)
    subsetter.populate(unicodes=sorted(unicodes))
    font = reload(font)
    subsetter.subset(font)
    font.flavor = "woff2"
    buffer = io.BytesIO()
    font.save(buffer)
    return buffer.getvalue()


def ranges(codepoints):
    points, spans = sorted(codepoints), []
    start = previous = points[0]
    for point in points[1:] + [None]:
        if point is not None and point == previous + 1:
            previous = point
            continue
        spans.append(f"U+{start:X}" if start == previous else f"U+{start:X}-{previous:X}")
        if point is not None:
            start = previous = point
    return ", ".join(spans)


def outlines(font, unicodes, location=None):
    if location is not None:
        font = reload(instantiateVariableFont(reload(font), location))
    cmap, glyphs, metrics = font.getBestCmap(), font.getGlyphSet(), font["hmtx"]
    result = {}
    for u in unicodes:
        # Decomposed, since subsetting renames the glyphs that components point to.
        pen = DecomposingRecordingPen(glyphs)
        glyphs[cmap[u]].draw(pen)
        result[u] = (pen.value, metrics[cmap[u]][0])
    return result


VERTICAL = ("head.unitsPerEm", "hhea.ascent", "hhea.descent", "hhea.lineGap", "OS/2.sTypoAscender", "OS/2.sTypoDescender",
            "OS/2.sTypoLineGap", "OS/2.usWinAscent", "OS/2.usWinDescent", "OS/2.fsSelection", "post.underlinePosition")


def check(name, data, source, expected):
    """Font tools have quirks, so every file is read back and compared with its source."""
    font = TTFont(io.BytesIO(data))
    problems = []
    cmap = set(font.getBestCmap())
    if cmap != expected:
        problems.append(f"characters differ: extra {ranges(cmap - expected) if cmap - expected else '-'}, missing {ranges(expected - cmap) if expected - cmap else '-'}")
    for table in ("fpgm", "prep", "cvt ", "hdmx", "VDMX"):
        if table in font:
            problems.append(f"hinting table {table!r} remains")
    if any(getattr(font["glyf"][g], "program", None) and font["glyf"][g].program.getBytecode() for g in font.getGlyphOrder()):
        problems.append("glyph instructions remain")
    for tag in ("GSUB", "GPOS"):
        if tag in font and font[tag].table.FeatureList:
            extra = {r.FeatureTag for r in font[tag].table.FeatureList.FeatureRecord} - set(FEATURES)
            if extra:
                problems.append(f"{tag} keeps {sorted(extra)}")
    # The license does not allow renaming the Timeless fonts, and nothing needs it.
    for name_id in (1, 2, 4, 6, 16, 17):
        if font["name"].getDebugName(name_id) != source["name"].getDebugName(name_id):
            problems.append(f"name {name_id} changed to {font['name'].getDebugName(name_id)!r}")
    for path in VERTICAL:
        table, field = path.split(".")
        if getattr(font[table], field) != getattr(source[table], field):
            problems.append(f"{path} changed")
    if "fvar" in font:
        for name_id in [i.subfamilyNameID for i in font["fvar"].instances] + [a.axisNameID for a in font["fvar"].axes]:
            if font["name"].getDebugName(name_id) is None:
                problems.append(f"name {name_id}, used by fvar, was dropped")
    # Outlines and advances must match the source at every weight the site uses.
    for location in VF_LOCATIONS if "fvar" in font else [None]:
        if outlines(font, cmap, location) != outlines(source, cmap, location):
            problems.append(f"outlines or advances differ at {location or 'default'}")
    if problems:
        sys.exit(f"{name}:\n  " + "\n  ".join(problems))


def main():
    used = used_characters()
    rules, report = [], []
    OUTPUT.mkdir(parents=True, exist_ok=True)
    for stale in OUTPUT.glob("*.woff2"):
        stale.unlink()
    extras, covered = set(), set()
    for family, weight, style, source, stem, axes in FACES:
        font = load(source, axes)
        available = set(font.getBestCmap())
        covered |= available
        core = (CORE | used) & available
        parts = {"core": core, "ext": EXTENDED & available - core}
        extras |= (used - CORE) & available
        sizes = []
        for part, unicodes in parts.items():
            name = f"{stem}-{part}.woff2"
            data = cut(font, unicodes)
            check(name, data, font, unicodes)
            (OUTPUT / name).write_bytes(data)
            sizes.append(len(data))
            lines = [f'  font-family: "{family}";', f'  src: url("/fonts/{name}") format("woff2");', f"  font-weight: {weight};"]
            if style:
                lines.append(f"  font-style: {style};")
            lines += ["  font-display: swap;", f"  unicode-range: {ranges(unicodes)};"]
            rules.append("@font-face {\n" + "\n".join(lines) + "\n}")
        report.append(f"{stem:32} core {sizes[0]:>6} B   ext {sizes[1]:>6} B")

    header = (
        "/*\n * Generated by scripts/subset-fonts.py. Do not edit: change the script and run it again.\n"
        " * Timeless by timeless.co. Geist Mono by the Geist Project Authors, under the OFL.\n"
        " * The core files hold ASCII, common punctuation and every character the pages use.\n"
        " * The ext files hold the rest of Latin-1 and Latin Extended-A, and load only on pages\n"
        " * that use one of their characters.\n */\n"
    )
    STYLESHEET.write_text(header + "\n" + "\n\n".join(rules) + "\n")
    print("\n".join(report))
    missing = used - covered
    print("\nCharacters the pages use beyond the fixed core set, added to core files:", "".join(sorted(map(chr, extras))) or "none")
    print("Characters the pages use that no font has (system fonts draw them):", "".join(sorted(map(chr, missing))) or "none")


if __name__ == "__main__":
    main()
