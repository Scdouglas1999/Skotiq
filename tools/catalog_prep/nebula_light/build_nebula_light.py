#!/usr/bin/env python3
"""Build the nebula light table: which OpenNGC nebulae glow in emission lines
and which only reflect starlight, from published catalogs that say so.

OpenNGC types most bright nebulae, but files many as plain "Neb" or "Cl+N"
(cluster with nebula) without saying whether the nebula is emission or
reflection. This script cross-matches every OpenNGC nebula against
catalogs that classify nebulae, and writes one row per nebula that matched.
The app reads the table when it loads OpenNGC.

Sources (raw files, provenance and licenses in sources/provenance.json):
  emission    Sharpless 1959, HII regions (VizieR VII/20), every entry
              Rodgers, Campbell & Whiteoak 1960, H-alpha emission regions
                (VizieR VII/216), every entry
              Anderson et al. 2014, WISE catalog of Galactic HII regions
                (VizieR J/ApJS/212/1), class K: ionized gas detected by
                radio recombination lines or H-alpha spectroscopy
              Cederblad 1946, bright diffuse nebulae (VizieR VII/231), a
                nebular spectrum of E or e
              Magakian 2003, merged reflection nebulae (VizieR
                J/A+A/399/141), a class with an E component
  reflection  Cederblad 1946, a nebular spectrum of C or c (continuous)
              Magakian 2003, a class with a C or CN component

The rule:
  - The OpenNGC objects considered are the nebula types Neb, Cl+N, EmN, HII
    and RfN. Planetary nebulae, supernova remnants and dark nebulae keep
    their type: the sources do not classify them.
  - A source entry matches an OpenNGC nebula when it names the nebula in its
    own identification column (RCW, WISE, Cederblad, Magakian), or when its
    position lies within the nebula's catalogued extent (half its major
    axis) plus MATCH_TOLERANCE_ARCMIN, which covers the rounding of the 1900
    and 1950 source positions (0.1 min of RA, 1 arcmin of Dec). The source's
    own extent is not used: a large shell such as Barnard's Loop (Sh2-276)
    would otherwise claim every nebula inside it.
  - An identification the source puts in parentheses (an associated object),
    marks with "?", or qualifies ("Part of", "Near") is not used; neither is
    a source position flagged uncertain or a class component marked "?".
  - A nebula with an emission match is "emission", also when it matches
    reflection sources too (M42, M20 and similar nebulae are imaged in
    narrowband). A nebula with only reflection matches is "reflection". A
    nebula with no match is left out, and the app keeps the OpenNGC type.

Positions in B1900 and B1950 are precessed to J2000 with the IAU 1976
precession (Lieske 1977), and galactic positions are rotated to J2000 with
the Hipparcos galactic pole; both agree with VizieR's own J2000 positions to
under 0.1 arcmin, far inside the match tolerance.

Usage:
  build_nebula_light.py [--openngc NGC.csv] [--sources DIR] [--out FILE] [--check]
Defaults build the table that ships in the app.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
DEFAULT_OPENNGC = REPO / "packages/skotiq_core/assets/catalogs/NGC.csv"
DEFAULT_SOURCES = HERE / "sources"
DEFAULT_OUT = REPO / "packages/skotiq_core/assets/catalogs/nebula_light.csv"

MATCH_TOLERANCE_ARCMIN = 2.0
NEBULA_TYPES = {"Neb", "Cl+N", "EmN", "HII", "RfN"}

EMISSION = "emission"
REFLECTION = "reflection"


@dataclass(frozen=True)
class SourceObject:
    """One entry of a source catalog, at J2000."""

    label: str
    ra_deg: float
    dec_deg: float
    emission: bool
    reflection: bool
    names: frozenset[str] = frozenset()


@dataclass
class Nebula:
    name: str
    type_code: str
    ra_deg: float
    dec_deg: float
    radius_arcmin: float
    emission: list[str] = field(default_factory=list)
    reflection: list[str] = field(default_factory=list)

    @property
    def light(self) -> str | None:
        if self.emission:
            return EMISSION
        if self.reflection:
            return REFLECTION
        return None


# --- positions -------------------------------------------------------------


def _besselian_to_jd(epoch: float) -> float:
    return 2415020.31352 + (epoch - 1900.0) * 365.242198781


def _precession_matrix_from_j2000(jd: float) -> list[list[float]]:
    """IAU 1976 precession matrix from J2000 to the mean equator of [jd]."""
    t = (jd - 2451545.0) / 36525.0
    arcsec = math.pi / (180.0 * 3600.0)
    zeta = (2306.2181 * t + 0.30188 * t * t + 0.017998 * t**3) * arcsec
    z = (2306.2181 * t + 1.09468 * t * t + 0.018203 * t**3) * arcsec
    theta = (2004.3109 * t - 0.42665 * t * t - 0.041833 * t**3) * arcsec
    cz, sz = math.cos(zeta), math.sin(zeta)
    cZ, sZ = math.cos(z), math.sin(z)
    ct, st = math.cos(theta), math.sin(theta)
    return [
        [cz * ct * cZ - sz * sZ, -sz * ct * cZ - cz * sZ, -st * cZ],
        [cz * ct * sZ + sz * cZ, -sz * ct * sZ + cz * cZ, -st * sZ],
        [cz * st, -sz * st, ct],
    ]


def to_j2000(ra_deg: float, dec_deg: float, besselian_epoch: float):
    """(ra, dec) in degrees at the mean equinox of [besselian_epoch], at J2000."""
    m = _precession_matrix_from_j2000(_besselian_to_jd(besselian_epoch))
    ra, dec = math.radians(ra_deg), math.radians(dec_deg)
    v = (math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec))
    # m takes J2000 to the epoch; its transpose takes the epoch back.
    x, y, zc = (sum(m[r][c] * v[r] for r in range(3)) for c in range(3))
    ra2 = math.degrees(math.atan2(y, x)) % 360.0
    dec2 = math.degrees(math.asin(max(-1.0, min(1.0, zc))))
    return ra2, dec2


# Rows are the galactic axes in ICRS (Hipparcos, ESA 1997, vol. 1, 1.5.3).
_GALACTIC_TO_ICRS_ROWS = (
    (-0.0548755604162154, -0.8734370902348850, -0.4838350155487132),
    (+0.4941094278755837, -0.4448296299600112, +0.7469822444972189),
    (-0.8676661490190047, -0.1980763734312015, +0.4559837761750669),
)


def galactic_to_j2000(lon_deg: float, lat_deg: float):
    lon, lat = math.radians(lon_deg), math.radians(lat_deg)
    g = (math.cos(lat) * math.cos(lon), math.cos(lat) * math.sin(lon), math.sin(lat))
    x, y, z = (
        sum(_GALACTIC_TO_ICRS_ROWS[r][c] * g[r] for r in range(3)) for c in range(3)
    )
    return math.degrees(math.atan2(y, x)) % 360.0, math.degrees(math.asin(z))


def separation_arcmin(ra1: float, dec1: float, ra2: float, dec2: float) -> float:
    r1, d1, r2, d2 = map(math.radians, (ra1, dec1, ra2, dec2))
    s = (
        math.sin((d2 - d1) / 2) ** 2
        + math.cos(d1) * math.cos(d2) * math.sin((r2 - r1) / 2) ** 2
    )
    return math.degrees(2 * math.asin(min(1.0, math.sqrt(s)))) * 60.0


# --- source readers ----------------------------------------------------------
# _field takes the 1-based, inclusive byte columns the ReadMe files give.


def _text(path: Path) -> str:
    data = path.read_bytes()
    if path.suffix == ".gz":
        data = gzip.decompress(data)
    return data.decode("latin-1")


def _field(line: str, first: int, last: int) -> str:
    return line[first - 1 : last].strip()


_IDENTIFICATION = re.compile(
    r"(?<![A-Za-z])(NGC|IC|N)\s*(\d+)[a-z]?((?:\s*[,/-]\s*\d+[a-z]?(?![\d.]))*)"
)
_QUALIFIER = re.compile(r"(Part of|Near)\s*$", re.IGNORECASE)


def openngc_names(text: str) -> frozenset[str]:
    """The OpenNGC names ("NGC0040", "IC0348") a source's identification
    column gives: "NGC6164,5" and "N6726-7" name two objects, a part letter
    ("IC4601a") names the object. A name in parentheses, followed by "?" or
    after "Part of" or "Near" is left out."""
    names = set()
    for m in _IDENTIFICATION.finditer(text):
        before, after = text[: m.start()], text[m.end() :]
        if before.count("(") > before.count(")"):
            continue
        if after.lstrip().startswith(("?", "(?")) or _QUALIFIER.search(before):
            continue
        prefix = "NGC" if m.group(1) in ("NGC", "N") else "IC"
        base = m.group(2)
        numbers = [base]
        for more in re.findall(r"\d+", m.group(3)):
            numbers.append(base[: len(base) - len(more)] + more)
        names.update(f"{prefix}{int(n):04d}" for n in numbers)
    return frozenset(names)


def read_sharpless(path: Path) -> list[SourceObject]:
    """VII/20 catalog.dat: B1900 positions as published."""
    out = []
    for line in _text(path).splitlines():
        if not line.strip():
            continue
        ra = 15.0 * (
            int(_field(line, 21, 22))
            + int(_field(line, 23, 24)) / 60.0
            + int(_field(line, 25, 27)) / 36000.0
        )
        dec = (
            int(_field(line, 29, 30))
            + int(_field(line, 31, 32)) / 60.0
            + int(_field(line, 33, 34)) / 3600.0
        )
        if _field(line, 28, 28) == "-":
            dec = -dec
        ra, dec = to_j2000(ra, dec, 1900.0)
        out.append(
            SourceObject(f"Sh2-{int(_field(line, 1, 4))}", ra, dec, True, False)
        )
    return out


def read_rcw(path: Path) -> list[SourceObject]:
    """VII/216 rcw.dat: B1950 positions."""
    out = []
    for line in _text(path).splitlines():
        if not line.strip():
            continue
        ra = 15.0 * (int(_field(line, 20, 21)) + float(_field(line, 23, 26)) / 60.0)
        dec = int(_field(line, 29, 30)) + int(_field(line, 32, 33)) / 60.0
        if _field(line, 28, 28) == "-":
            dec = -dec
        ra, dec = to_j2000(ra, dec, 1950.0)
        out.append(
            SourceObject(
                f"RCW {int(_field(line, 1, 3))}",
                ra,
                dec,
                True,
                False,
                openngc_names(_field(line, 48, 79)),
            )
        )
    return out


def read_cederblad(path: Path) -> list[SourceObject]:
    """VII/231 catalog.dat: B1900 positions; the nebular spectrum column says
    E/e (emission, observed/inferred) or C/c (continuous, observed/inferred)."""
    out = []
    for line in _text(path).splitlines():
        if not line.strip():
            continue
        if _field(line, 24, 24) or _field(line, 31, 31):
            continue  # position flagged uncertain
        dec_min = _field(line, 29, 30)
        if not dec_min:
            continue
        spectrum = _field(line, 87, 89)
        emission = bool(re.search("[Ee]", spectrum))
        reflection = bool(re.search("[Cc]", spectrum))
        if not (emission or reflection):
            continue
        ra = 15.0 * (int(_field(line, 17, 18)) + float(_field(line, 20, 23)) / 60.0)
        dec = int(_field(line, 26, 27)) + int(dec_min) / 60.0
        if _field(line, 25, 25) == "-":
            dec = -dec
        ra, dec = to_j2000(ra, dec, 1900.0)
        label = f"Ced {int(_field(line, 1, 3))}{_field(line, 4, 4)}"
        out.append(
            SourceObject(
                label, ra, dec, emission, reflection, openngc_names(_field(line, 6, 16))
            )
        )
    return out


_MAGAKIAN_CLASS = re.compile(r"(CN|HH|PN|gal|C|E)(\?)?")


def magakian_class(text: str) -> tuple[bool, bool]:
    """(emission, reflection) for a Magakian class such as "C+E", "CN?" or
    "C,CN?". C is a continuous-spectrum (reflection) nebula, CN a cometary
    one, E emission; a component followed by "?" is not counted."""
    emission = reflection = False
    for kind, doubt in _MAGAKIAN_CLASS.findall(text):
        if doubt:
            continue
        if kind == "E":
            emission = True
        elif kind in ("C", "CN"):
            reflection = True
    return emission, reflection


def _sexagesimal(text: str) -> float:
    parts = text.replace("+", "").replace("-", "").split()
    value = float(parts[0]) + float(parts[1]) / 60.0 + float(parts[2]) / 3600.0
    return -value if text.strip().startswith("-") else value


def _tsv_rows(path: Path) -> tuple[dict[str, int], list[list[str]]]:
    """A VizieR tab-separated export: comment lines, then column names,
    units and a line of dashes, then the data."""
    rows = [
        line.split("\t")
        for line in _text(path).splitlines()
        if line and not line.startswith("#")
    ]
    dashes = next(
        i for i, row in enumerate(rows) if all(set(f) <= {"-"} for f in row)
    )
    return {name: i for i, name in enumerate(rows[0])}, [
        row for row in rows[dashes + 1 :] if any(f.strip() for f in row)
    ]


def read_magakian(path: Path) -> list[SourceObject]:
    """J/A+A/399/141 table1 as VizieR's tab-separated export: J2000."""
    col, data = _tsv_rows(path)
    out = []
    for row in data:
        emission, reflection = magakian_class(row[col["Class"]])
        if not (emission or reflection):
            continue
        out.append(
            SourceObject(
                f"Magakian {int(row[col['Seq']])}",
                15.0 * _sexagesimal(row[col["RAJ2000"]]),
                _sexagesimal(row[col["DEJ2000"]]),
                emission,
                reflection,
                openngc_names(row[col["NGC/IC"]]),
            )
        )
    return out


def read_wise_hii(path: Path) -> list[SourceObject]:
    """J/ApJS/212/1 wisecat as VizieR's tab-separated export: galactic
    positions; only class K (ionized gas detected) counts as emission."""
    col, data = _tsv_rows(path)
    out = []
    for row in data:
        if row[col["Cl"]].strip() != "K":
            continue
        ra, dec = galactic_to_j2000(float(row[col["GLON"]]), float(row[col["GLAT"]]))
        out.append(
            SourceObject(
                f"WISE {row[col['WISE']].strip()}",
                ra,
                dec,
                True,
                False,
                openngc_names(row[col["HIIName"]]),
            )
        )
    return out


READERS = {
    "sharpless_1959": read_sharpless,
    "rcw_1960": read_rcw,
    "wise_hii_2014": read_wise_hii,
    "cederblad_1946": read_cederblad,
    "magakian_2003": read_magakian,
}


# --- OpenNGC -----------------------------------------------------------------


def read_openngc_nebulae(path: Path) -> list[Nebula]:
    out = []
    lines = path.read_text(encoding="utf-8").splitlines()
    for line in lines[1:]:
        parts = line.split(";")
        if len(parts) < 7 or parts[1] not in NEBULA_TYPES:
            continue
        if not parts[2] or not parts[3]:
            continue
        h, m, s = (float(x) for x in parts[2].split(":"))
        ra = 15.0 * (h + m / 60.0 + s / 3600.0)
        dec = _sexagesimal(parts[3].replace(":", " "))
        major = float(parts[5]) if parts[5] else 0.0
        out.append(Nebula(parts[0], parts[1], ra, dec, major / 2.0))
    return out


# --- build -------------------------------------------------------------------


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_sources(sources_dir: Path) -> tuple[dict, list[SourceObject]]:
    """Reads every source listed in provenance.json after checking that each
    file still has the recorded checksum."""
    provenance = json.loads((sources_dir / "provenance.json").read_text())
    objects: list[SourceObject] = []
    for source in provenance["sources"]:
        for f in source["files"]:
            p = sources_dir / source["id"] / f["name"]
            actual = sha256(p)
            if actual != f["sha256"]:
                raise SystemExit(
                    f"{p}: sha256 {actual} does not match provenance.json "
                    f"({f['sha256']}); fetch it again from {f['url']}"
                )
        data_file = sources_dir / source["id"] / source["data"]
        objects.extend(READERS[source["id"]](data_file))
    return provenance, objects


def classify(nebulae: list[Nebula], objects: list[SourceObject]) -> None:
    for n in nebulae:
        reach = n.radius_arcmin + MATCH_TOLERANCE_ARCMIN
        for o in objects:
            if n.name not in o.names and (
                abs(o.dec_deg - n.dec_deg) * 60.0 > reach
                or separation_arcmin(n.ra_deg, n.dec_deg, o.ra_deg, o.dec_deg) > reach
            ):
                continue
            if o.emission:
                n.emission.append(o.label)
            if o.reflection:
                n.reflection.append(o.label)


def render(nebulae: list[Nebula], openngc: Path, provenance: dict) -> str:
    lines = [
        "# Nebula light for OpenNGC: emission or reflection, from published catalogs.",
        "# Generated by tools/catalog_prep/nebula_light/build_nebula_light.py; do not edit.",
        f"# OpenNGC NGC.csv sha256 {sha256(openngc)}",
    ]
    for source in provenance["sources"]:
        lines.append(f"# Source: {source['citation']} ({source['vizier']})")
    lines.append(
        f"# Rule: a source entry that names the nebula, or lies within its half "
        f"major axis + {MATCH_TOLERANCE_ARCMIN:g} arcmin, matches; any emission match "
        f"is emission, only reflection matches is reflection."
    )
    lines.append("Name;Light;Emission;Reflection")
    for n in sorted(nebulae, key=lambda n: n.name):
        if n.light is None:
            continue
        lines.append(
            f"{n.name};{n.light};{','.join(n.emission)};{','.join(n.reflection)}"
        )
    return "\n".join(lines) + "\n"


def build(openngc: Path, sources_dir: Path) -> str:
    provenance, objects = load_sources(sources_dir)
    nebulae = read_openngc_nebulae(openngc)
    classify(nebulae, objects)
    return render(nebulae, openngc, provenance)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--openngc", type=Path, default=DEFAULT_OPENNGC)
    parser.add_argument("--sources", type=Path, default=DEFAULT_SOURCES)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 when --out differs from what the sources build",
    )
    args = parser.parse_args(argv)
    table = build(args.openngc, args.sources)
    if args.check:
        current = args.out.read_text() if args.out.exists() else ""
        if current != table:
            print(f"{args.out} is out of date; run {Path(__file__).name}", file=sys.stderr)
            return 1
        return 0
    args.out.write_text(table)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
