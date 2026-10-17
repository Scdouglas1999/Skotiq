#!/usr/bin/env python3
"""Generate constellation_lines.rs from v1 constellation_data.dart."""

from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DART = (
    ROOT
    / "packages/skotiq_planetarium/lib/src/catalogs/constellation_data.dart"
)
OUT = (
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


def f32(v: float) -> str:
    s = f"{v:.6f}".rstrip("0").rstrip(".")
    if "." not in s:
        s += ".0"
    return s


def parse_constellations(text: str) -> list[tuple]:
    lines_section = text.split("/// A boundary polygon vertex")[0]
    consts = []
    for m in CONST_PAT.finditer(lines_section):
        abbr, name, cra, cdec, lines_blob = m.groups()
        segments = []
        for lm in LINE_PAT.finditer(lines_blob):
            sra, sdec, era, edec = lm.groups()
            segments.append(
                (float(sra), float(sdec), float(era), float(edec))
            )
        consts.append((abbr, name, float(cra), float(cdec), segments))
    return consts


def emit_rust(consts: list[tuple]) -> str:
    total_segs = sum(len(c[4]) for c in consts)
    total_verts = total_segs * 2

    lines: list[str] = [
        "//! IAU constellation stick-figure line segments (J2000 RA hours / Dec degrees).",
        "//!",
        "//! Ported from `packages/skotiq_planetarium/lib/src/catalogs/constellation_data.dart`.",
        "//! Boundaries are a separate table (future task).",
        "",
        "/// One line segment between two J2000 equatorial endpoints.",
        "#[derive(Debug, Clone, Copy, PartialEq)]",
        "pub struct ConstellationSegment {",
        "    /// Start right ascension (hours).",
        "    pub start_ra_hours: f32,",
        "    /// Start declination (degrees).",
        "    pub start_dec_deg: f32,",
        "    /// End right ascension (hours).",
        "    pub end_ra_hours: f32,",
        "    /// End declination (degrees).",
        "    pub end_dec_deg: f32,",
        "}",
        "",
        "/// Stick-figure lines for one IAU constellation.",
        "#[derive(Debug, Clone, Copy, PartialEq)]",
        "pub struct ConstellationLines {",
        "    /// Three-letter IAU abbreviation (e.g. `\"Ori\"`).",
        "    pub abbrev: &'static str,",
        "    /// English proper name.",
        "    pub name: &'static str,",
        "    /// Label centroid RA (hours).",
        "    pub center_ra_hours: f32,",
        "    /// Label centroid declination (degrees).",
        "    pub center_dec_deg: f32,",
        "    /// Line segments for this constellation.",
        "    pub segments: &'static [ConstellationSegment],",
        "}",
        "",
        f"/// Number of IAU constellations with stick-figure line data.",
        f"pub const CONSTELLATION_COUNT: usize = {len(consts)};",
        "",
        f"/// Total line segments across all constellations.",
        f"pub const LINE_SEGMENT_COUNT: usize = {total_segs};",
        "",
        f"/// GPU line vertices (two per segment: start + end).",
        f"pub const LINE_VERTEX_COUNT: usize = {total_verts};",
        "",
        "/// Convert J2000 equatorial coordinates to a unit ICRS direction.",
        "#[must_use]",
        "pub fn icrs_dir_from_j2000(ra_hours: f32, dec_deg: f32) -> [f32; 3] {",
        "    let ra_rad = ra_hours * (std::f32::consts::PI / 12.0);",
        "    let dec_rad = dec_deg.to_radians();",
        "    let (sin_dec, cos_dec) = dec_rad.sin_cos();",
        "    let (sin_ra, cos_ra) = ra_rad.sin_cos();",
        "    [cos_dec * cos_ra, cos_dec * sin_ra, sin_dec]",
        "}",
        "",
        "/// Total GPU vertices for constellation stick figures (2 per segment).",
        "#[must_use]",
        "pub fn line_vertex_count() -> usize {",
        "    LINE_VERTEX_COUNT",
        "}",
        "",
        "/// Look up constellation line data by IAU abbreviation (case-insensitive).",
        "#[must_use]",
        "pub fn find_by_abbreviation(abbrev: &str) -> Option<&'static ConstellationLines> {",
        "    let key = abbrev.trim();",
        "    CONSTELLATIONS.iter().find(|c| c.abbrev.eq_ignore_ascii_case(key))",
        "}",
        "",
    ]

    for abbr, name, cra, cdec, segments in consts:
        seg_name = f"SEGMENTS_{abbr.upper()}"
        lines.append(f"const {seg_name}: &[ConstellationSegment] = &[")
        for sra, sdec, era, edec in segments:
            lines.append(
                "    ConstellationSegment { "
                + f"start_ra_hours: {f32(sra)}, start_dec_deg: {f32(sdec)}, "
                + f"end_ra_hours: {f32(era)}, end_dec_deg: {f32(edec)} "
                + "},"
            )
        lines.append("];")
        lines.append("")

    lines.append("/// All IAU constellation stick-figure line tables.")
    lines.append("pub const CONSTELLATIONS: &[ConstellationLines] = &[")
    for abbr, name, cra, cdec, _ in consts:
        seg_name = f"SEGMENTS_{abbr.upper()}"
        lines.append(
            "    ConstellationLines { "
            + f'abbrev: "{abbr}", name: "{name}", '
            + f"center_ra_hours: {f32(cra)}, center_dec_deg: {f32(cdec)}, "
            + f"segments: {seg_name} "
            + "},"
        )
    lines.append("];")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    text = DART.read_text(encoding="utf-8")
    consts = parse_constellations(text)
    if len(consts) != 88:
        raise SystemExit(f"expected 88 constellations, got {len(consts)}")
    OUT.write_text(emit_rust(consts), encoding="utf-8", newline="\n")
    print(f"wrote {OUT} ({len(consts)} constellations)")


if __name__ == "__main__":
    main()
