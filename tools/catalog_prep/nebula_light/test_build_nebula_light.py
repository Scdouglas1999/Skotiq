"""Tests for build_nebula_light.py: the matching rule on a small fixture, the
source readers' column layouts, and that the shipped table is what the
committed sources build.

Run: python3 tools/catalog_prep/nebula_light/test_build_nebula_light.py
"""

import gzip
import hashlib
import json
import math
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import build_nebula_light as build  # noqa: E402

OPENNGC_HEADER = (
    "Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;"
    "SurfBr;Hubble;Pax;Pm-RA;Pm-Dec;RadVel;Redshift;Cstar U-Mag;Cstar B-Mag;"
    "Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;Common names;NED notes;"
    "OpenNGC notes;Sources"
)


def fixed(columns: dict[int, str], width: int = 160) -> str:
    """A fixed-width line with each text starting at its 1-based column."""
    line = [" "] * width
    for start, text in columns.items():
        line[start - 1 : start - 1 + len(text)] = text
    return "".join(line).rstrip()


def openngc_row(name, type_code, ra, dec, major=""):
    fields = [name, type_code, ra, dec, "Ori", major] + [""] * 26
    return ";".join(fields)


def sexagesimal(value: float, hours: bool) -> tuple[int, float]:
    if hours:
        value /= 15.0
    whole = int(value)
    return whole, (value - whole) * 60.0


def at_epoch(ra_deg: float, dec_deg: float, epoch: float) -> tuple[float, float]:
    """The position at Besselian [epoch] whose J2000 position is given."""
    m = build._precession_matrix_from_j2000(build._besselian_to_jd(epoch))
    ra, dec = math.radians(ra_deg), math.radians(dec_deg)
    v = (math.cos(dec) * math.cos(ra), math.cos(dec) * math.sin(ra), math.sin(dec))
    x, y, z = (sum(m[r][c] * v[c] for c in range(3)) for r in range(3))
    return math.degrees(math.atan2(y, x)) % 360.0, math.degrees(math.asin(z))


def sharpless_line(number: int, ra_j2000: float, dec_j2000: float) -> str:
    ra, dec = at_epoch(ra_j2000, dec_j2000, 1900.0)
    rh, rm = sexagesimal(ra, hours=True)
    sign = "-" if dec < 0 else "+"
    dd, dm = sexagesimal(abs(dec), hours=False)
    ds = (dm - int(dm)) * 60.0
    return fixed(
        {
            1: f"{number:4d}",
            21: f"{rh:2d}",
            23: f"{int(rm):2d}",
            25: f"{round((rm - int(rm)) * 600):3d}",
            28: sign,
            29: f"{dd:2d}",
            31: f"{int(dm):2d}",
            33: f"{round(ds):2d}",
            49: "  60",
        }
    )


def cederblad_line(number, name, ra_j2000, dec_j2000, spectrum, uncertain=False):
    ra, dec = at_epoch(ra_j2000, dec_j2000, 1900.0)
    rh, rm = sexagesimal(ra, hours=True)
    sign = "-" if dec < 0 else "+"
    dd, dm = sexagesimal(abs(dec), hours=False)
    columns = {
        1: f"{number:3d}",
        6: name,
        17: f"{rh:2d}",
        20: f"{rm:4.1f}",
        25: sign,
        26: f"{dd:2d}",
        29: f"{round(dm):2d}",
        87: spectrum,
    }
    if uncertain:
        columns[24] = ":"
    return fixed(columns)


def rcw_line(number, ids, ra_j2000, dec_j2000):
    ra, dec = at_epoch(ra_j2000, dec_j2000, 1950.0)
    rh, rm = sexagesimal(ra, hours=True)
    sign = "-" if dec < 0 else "+"
    dd, dm = sexagesimal(abs(dec), hours=False)
    return fixed(
        {
            1: f"{number:3d}",
            20: f"{rh:2d}",
            23: f"{rm:4.1f}",
            28: sign,
            29: f"{dd:2d}",
            32: f"{round(dm):2d}",
            36: " 10",
            48: ids,
        }
    )


def tsv(columns: list[str], rows: list[list[str]]) -> str:
    lines = ["#", "# VizieR export"]
    lines.append("\t".join(columns))
    lines.append("\t".join(" " for _ in columns))
    lines.append("\t".join("-" for _ in columns))
    lines.extend("\t".join(r) for r in rows)
    return "\n".join(lines) + "\n"


def hms(ra_deg: float) -> str:
    h, m = sexagesimal(ra_deg, hours=True)
    return f"{h:02d} {int(m):02d} {(m - int(m)) * 60:02.0f}"


def dms(dec_deg: float) -> str:
    sign = "-" if dec_deg < 0 else "+"
    d, m = sexagesimal(abs(dec_deg), hours=False)
    return f"{sign}{d:02d} {int(m):02d} {(m - int(m)) * 60:02.0f}"


class FixtureBuild(unittest.TestCase):
    """A small sky: five OpenNGC nebulae and one entry of each source."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        root = Path(cls.tmp.name)
        cls.openngc = root / "NGC.csv"
        cls.openngc.write_text(
            "\n".join(
                [
                    OPENNGC_HEADER,
                    # Reflection only: a Magakian C entry 1 arcmin away.
                    openngc_row("NGC0001", "Neb", "01:00:00.00", "+30:00:00.0", "4"),
                    # Both: a Sharpless region 3 arcmin away inside a 10' nebula
                    # and a Cederblad C entry.
                    openngc_row("NGC0002", "Cl+N", "02:00:00.00", "+10:00:00.0", "10"),
                    # Named by RCW far from its position: emission.
                    openngc_row("IC0003", "Neb", "03:00:00.00", "-60:00:00.0", "1"),
                    # Inside a big Sharpless region whose center is 30' away:
                    # no match (the source's extent is not used).
                    openngc_row("NGC0004", "RfN", "04:00:00.00", "+00:30:00.0", "2"),
                    # Only an uncertain Cederblad entry and a "C?" Magakian one:
                    # no match.
                    openngc_row("NGC0005", "Neb", "05:00:00.00", "+20:00:00.0", "2"),
                    # Not a nebula type: never listed.
                    openngc_row("NGC0006", "PN", "01:00:00.00", "+30:00:00.0", "1"),
                ]
            )
            + "\n"
        )
        sources = root / "sources"
        files = {
            "sharpless_1959/catalog.dat.gz": gzip.compress(
                (
                    sharpless_line(1, 30.0 + 3 / 60 / 0.985, 10.0)
                    + "\n"
                    + sharpless_line(2, 60.0, 0.0)
                    + "\n"
                ).encode()
            ),
            "rcw_1960/rcw.dat.gz": gzip.compress(
                (rcw_line(7, "IC3,5; G12", 50.0, -55.0) + "\n").encode()
            ),
            "wise_hii_2014/wisecat.tsv": tsv(
                ["WISE", "Cl", "GLON", "GLAT", "Rad", "HIIName"],
                [["G010.000+00.000", "Q", "10.000", "0.000", "100", ""]],
            ).encode(),
            "cederblad_1946/catalog.dat": (
                cederblad_line(1, "NGC 2", 30.0, 10.0, "C")
                + "\n"
                + cederblad_line(2, "", 75.0, 20.0, "C", uncertain=True)
                + "\n"
            ).encode("latin-1"),
            "magakian_2003/table1.tsv": tsv(
                ["recno", "Seq", "RAJ2000", "DEJ2000", "NGC/IC", "Class"],
                [
                    ["1", "1", hms(15.0), dms(30.0 + 1 / 60), "", "C"],
                    ["2", "2", hms(75.0), dms(20.0), "N5", "C?"],
                ],
            ).encode(),
        }
        provenance = {"sources": []}
        for source_id, data_name in [
            ("sharpless_1959", "catalog.dat.gz"),
            ("rcw_1960", "rcw.dat.gz"),
            ("wise_hii_2014", "wisecat.tsv"),
            ("cederblad_1946", "catalog.dat"),
            ("magakian_2003", "table1.tsv"),
        ]:
            path = sources / source_id / data_name
            path.parent.mkdir(parents=True)
            path.write_bytes(files[f"{source_id}/{data_name}"])
            provenance["sources"].append(
                {
                    "id": source_id,
                    "vizier": source_id,
                    "citation": source_id,
                    "data": data_name,
                    "files": [
                        {
                            "name": data_name,
                            "url": "fixture",
                            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        }
                    ],
                }
            )
        (sources / "provenance.json").write_text(json.dumps(provenance))
        cls.sources = sources
        cls.rows = {
            line.split(";")[0]: line.split(";")[1:]
            for line in build.build(cls.openngc, sources).splitlines()
            if not line.startswith("#") and not line.startswith("Name;")
        }

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def test_a_nebula_with_only_reflection_matches_is_reflection(self):
        self.assertEqual(self.rows["NGC0001"], ["reflection", "", "Magakian 1"])

    def test_a_nebula_with_emission_and_reflection_matches_is_emission(self):
        light, emission, reflection = self.rows["NGC0002"]
        self.assertEqual(light, "emission")
        self.assertEqual(emission, "Sh2-1")
        self.assertEqual(reflection, "Ced 1")

    def test_a_source_that_names_the_nebula_matches_wherever_it_lies(self):
        self.assertEqual(self.rows["IC0003"], ["emission", "RCW 7", ""])

    def test_a_large_source_does_not_claim_a_nebula_inside_it(self):
        self.assertNotIn("NGC0004", self.rows)

    def test_uncertain_positions_and_doubtful_classes_are_not_evidence(self):
        self.assertNotIn("NGC0005", self.rows)

    def test_only_nebula_types_are_considered(self):
        self.assertNotIn("NGC0006", self.rows)

    def test_a_changed_source_file_is_refused(self):
        data = self.sources / "rcw_1960" / "rcw.dat.gz"
        original = data.read_bytes()
        try:
            data.write_bytes(original + b"\n")
            with self.assertRaises(SystemExit) as raised:
                build.build(self.openngc, self.sources)
            self.assertIn("does not match provenance.json", str(raised.exception))
        finally:
            data.write_bytes(original)


class Readers(unittest.TestCase):
    def test_identifications_name_every_object_a_column_lists(self):
        self.assertEqual(
            build.openngc_names("IC2944,8; BBW26201;G42"), {"IC2944", "IC2948"}
        )
        self.assertEqual(build.openngc_names("N6726-7"), {"NGC6726", "NGC6727"})
        self.assertEqual(
            build.openngc_names("NGC3293,3324,IC2599;BBW22500;"),
            {"NGC3293", "NGC3324", "IC2599"},
        )
        self.assertEqual(build.openngc_names("N1435,IC349"), {"NGC1435", "IC0349"})
        self.assertEqual(build.openngc_names("IC 4601a"), {"IC4601"})

    def test_qualified_identifications_are_left_out(self):
        self.assertEqual(build.openngc_names("(NGC6193); BBW30402; G53"), set())
        self.assertEqual(build.openngc_names("NGC6618; (IC4706,7)"), {"NGC6618"})
        self.assertEqual(build.openngc_names("N2195(?)"), set())
        self.assertEqual(build.openngc_names("Part of NGC2736"), set())
        self.assertEqual(build.openngc_names("HS111,113;G2,3"), set())

    def test_magakian_classes(self):
        self.assertEqual(build.magakian_class("C"), (False, True))
        self.assertEqual(build.magakian_class("CN?HH?"), (False, False))
        self.assertEqual(build.magakian_class("C+E"), (True, True))
        self.assertEqual(build.magakian_class("C+E?"), (False, True))
        self.assertEqual(build.magakian_class("E+C?"), (True, False))

    def test_precession_and_galactic_rotation_agree_with_vizier(self):
        # VizieR's own J2000 position of Sh2-1, and the galactic center.
        sh2_1 = build.read_sharpless(
            HERE / "sources" / "sharpless_1959" / "catalog.dat.gz"
        )[0]
        self.assertEqual(sh2_1.label, "Sh2-1")
        self.assertLess(
            build.separation_arcmin(
                sh2_1.ra_deg, sh2_1.dec_deg, 239.713380, -26.120461
            ),
            0.1,
        )
        ra, dec = build.galactic_to_j2000(0.0, 0.0)
        self.assertLess(build.separation_arcmin(ra, dec, 266.40499, -28.93617), 0.01)


class ShippedTable(unittest.TestCase):
    def test_the_shipped_table_is_what_the_committed_sources_build(self):
        self.assertEqual(
            build.main(["--check"]),
            0,
            "packages/skotiq_core/assets/catalogs/nebula_light.csv is out of "
            "date; run tools/catalog_prep/nebula_light/build_nebula_light.py",
        )


if __name__ == "__main__":
    unittest.main()
