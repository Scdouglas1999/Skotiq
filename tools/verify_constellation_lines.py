#!/usr/bin/env python3
"""Compare dart vs rust constellation line counts."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DART = (
    ROOT
    / "packages/skotiq_planetarium/lib/src/catalogs/constellation_data.dart"
)
RUST = (
    ROOT
    / "native/skotiq_native/planetarium/src/catalog/constellation_lines.rs"
)

CONST_PAT = re.compile(
    r"const ConstellationData\(\s*"
    r"abbreviation: '([^']+)',\s*"
    r"name: '([^']+)',\s*"
    r"center: CelestialCoordinate\(ra: ([^,]+), dec: ([^)]+)\),\s*"
    r"lines: \[(.*?)\],\s*"
    r"\),",
    re.DOTALL,
)
LINE_PAT = re.compile(
    r"ConstellationLine\(\s*"
    r"start: CelestialCoordinate\(ra: ([^,]+), dec: ([^)]+)\).*?"
    r"end: CelestialCoordinate\(ra: ([^,]+), dec: ([^)]+)\)",
    re.DOTALL,
)
RUST_SEG_PAT = re.compile(
    r"const SEGMENTS_(\w+): &\[ConstellationSegment\] = &\[(.*?)\];",
    re.DOTALL,
)
RUST_CONST_PAT = re.compile(
    r'ConstellationLines \{ abbrev: "([^"]+)", name: "([^"]+)",'
    r" center_ra_hours: ([^,]+), center_dec_deg: ([^,]+), segments: SEGMENTS_(\w+) \}",
)


def parse_dart(text: str) -> dict[str, list]:
    lines_section = text.split("/// A boundary polygon vertex")[0]
    out: dict[str, list] = {}
    for m in CONST_PAT.finditer(lines_section):
        abbr = m.group(1)
        segments = [
            (float(a), float(b), float(c), float(d))
            for a, b, c, d in LINE_PAT.findall(m.group(5))
        ]
        out[abbr] = segments
    return out


def parse_rust(text: str) -> dict[str, list]:
    segs: dict[str, list] = {}
    for name, blob in RUST_SEG_PAT.findall(text):
        count = blob.count("ConstellationSegment {")
        segs[name] = count
    out: dict[str, list] = {}
    for abbr, _name, _cra, _cdec, seg_key in RUST_CONST_PAT.findall(text):
        out[abbr] = segs.get(seg_key, 0)
    return out


def main() -> None:
    dart = parse_dart(DART.read_text(encoding="utf-8"))
    rust_counts = parse_rust(RUST.read_text(encoding="utf-8"))
    print("dart constellations", len(dart))
    print("dart segments", sum(len(v) for v in dart.values()))
    print("rust constellations", len(rust_counts))
    print("rust segments", sum(rust_counts.values()))

    for abbr in sorted(dart):
        d = len(dart[abbr])
        r = rust_counts.get(abbr, -1)
        if d != r:
            print(f"MISMATCH {abbr}: dart={d} rust={r}")

    # lines that fail regex
    raw = DART.read_text(encoding="utf-8").split("/// A boundary polygon vertex")[0]
    all_lines = re.findall(r"ConstellationLine\(", raw)
    parsed = sum(len(v) for v in dart.values())
    print("raw ConstellationLine( count", len(all_lines), "parsed", parsed)


def emit_test_expected() -> None:
    dart = parse_dart(DART.read_text(encoding="utf-8"))
    lines = [
        "//! Constellation line catalog: count and per-constellation vertex totals vs v1.",
        "",
        "use skotiq_planetarium::catalog::{",
        "    find_by_abbreviation, line_vertex_count, ConstellationLines, CONSTELLATION_COUNT,",
        "    CONSTELLATIONS, LINE_SEGMENT_COUNT, LINE_VERTEX_COUNT,",
        "};",
        "",
        "/// Per-constellation line segment counts from v1 `constellation_data.dart`.",
        "const EXPECTED_SEGMENT_COUNTS: &[(&str, usize)] = &[",
    ]
    for abbr in sorted(dart.keys()):
        lines.append(f'    ("{abbr}", {len(dart[abbr])}),')
    lines.extend(
        [
            "];",
            "",
            "#[test]",
            "fn constellation_count_is_88() {",
            "    assert_eq!(CONSTELLATION_COUNT, 88);",
            "    assert_eq!(CONSTELLATIONS.len(), 88);",
            "    assert_eq!(EXPECTED_SEGMENT_COUNTS.len(), 88);",
            "}",
            "",
            "#[test]",
            "fn total_line_vertex_count_matches_v1() {",
            f"    assert_eq!(LINE_SEGMENT_COUNT, {sum(len(v) for v in dart.values())});",
            f"    assert_eq!(LINE_VERTEX_COUNT, {sum(len(v) for v in dart.values()) * 2});",
            "    assert_eq!(line_vertex_count(), LINE_VERTEX_COUNT);",
            "",
            "    let computed_vertices: usize = CONSTELLATIONS",
            "        .iter()",
            "        .map(|c| c.segments.len() * 2)",
            "        .sum();",
            "    assert_eq!(computed_vertices, LINE_VERTEX_COUNT);",
            "}",
            "",
            "#[test]",
            "fn per_constellation_vertex_counts_match_v1() {",
            "    for &(abbrev, expected_segments) in EXPECTED_SEGMENT_COUNTS {",
            "        let c = find_by_abbreviation(abbrev).unwrap_or_else(|| {",
            "            panic!(\"missing constellation {abbrev}\");",
            "        });",
            "        assert_eq!(",
            "            c.segments.len(),",
            "            expected_segments,",
            "            \"segment count for {abbrev}\"",
            "        );",
            "        assert_eq!(",
            "            c.segments.len() * 2,",
            "            vertex_count(c),",
            "            \"vertex count for {abbrev}\"",
            "        );",
            "    }",
            "}",
            "",
            "#[test]",
            "fn find_by_abbreviation_case_insensitive() {",
            "    let ori = find_by_abbreviation(\"ori\").expect(\"Orion\");",
            "    assert_eq!(ori.abbrev, \"Ori\");",
            "    assert_eq!(ori.name, \"Orion\");",
            "    assert_eq!(ori.segments.len(), 7);",
            "}",
            "",
            "fn vertex_count(c: &ConstellationLines) -> usize {",
            "    c.segments.len() * 2",
            "}",
            "",
        ]
    )
    out = ROOT / "native/skotiq_native/planetarium/tests/catalog_constellation_lines.rs"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    print(f"wrote {out}")


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] == "--emit-test":
        emit_test_expected()
    else:
        main()
