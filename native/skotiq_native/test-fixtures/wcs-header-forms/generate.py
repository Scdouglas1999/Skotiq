"""Sky positions astropy gives for each WCS header form, as the fixture
imaging/tests/wcs_header_forms.rs checks SipWcs::from_header against.

Run: python generate.py > astropy.json (astropy and numpy installed).

Pixels are 0-based (astropy origin 0), the convention of SipWcs::pixel_to_world.
"""
import json
import math
import re
import warnings
from astropy.io import fits
from astropy.wcs import WCS, FITSFixedWarning

warnings.simplefilter("ignore", FITSFixedWarning)

S = 1.9 / 3600.0
R = math.radians(33.0)
C, N = math.cos(R), math.sin(R)

BASE = dict(NAXIS=2, NAXIS1=4656, NAXIS2=3520, CTYPE1="RA---TAN", CTYPE2="DEC--TAN",
            CRVAL1=35.6391, CRVAL2=42.3491, CRPIX1=2328.5, CRPIX2=1760.5)

SIP = dict(CTYPE1="RA---TAN-SIP", CTYPE2="DEC--TAN-SIP", A_ORDER=3, B_ORDER=3,
           A_2_0=1.2e-6, A_1_1=-8.0e-7, A_0_2=5.0e-7, A_3_0=4.0e-10, A_1_2=-2.0e-10,
           B_2_0=-6.0e-7, B_1_1=9.0e-7, B_0_2=-1.1e-6, B_0_3=3.0e-10, B_2_1=1.5e-10)

CASES = [
    ("cd", dict(CD1_1=-S * C, CD1_2=S * N, CD2_1=S * N, CD2_2=S * C)),
    ("cd_off_diagonal_only", dict(CD1_2=-S, CD2_1=-S)),
    ("pc_cdelt", dict(CDELT1=-S, CDELT2=S, PC1_1=C, PC1_2=-N, PC2_1=N, PC2_2=C)),
    ("pc_partial", dict(CDELT1=-S, CDELT2=S, PC1_2=-0.2)),
    ("cdelt", dict(CDELT1=-S, CDELT2=S)),
    ("cdelt_crota2", dict(CDELT1=-S, CDELT2=S, CROTA2=-33.0)),
    ("cd_wins_over_crota", dict(CD1_1=-S * C, CD1_2=S * N, CD2_1=S * N, CD2_2=S * C,
                                CDELT1=-2 * S, CDELT2=2 * S, CROTA2=10.0)),
    ("pc_wins_over_cd", dict(CD1_1=-2 * S, CD2_2=2 * S, CDELT1=-S, CDELT2=S,
                             PC1_1=C, PC1_2=-N, PC2_1=N, PC2_2=C)),
    ("pc_wins_over_crota", dict(CDELT1=-S, CDELT2=S, PC1_1=C, PC1_2=-N, PC2_1=N, PC2_2=C,
                                CROTA2=10.0)),
    ("cd_sip", dict(CD1_1=-S * C, CD1_2=S * N, CD2_1=S * N, CD2_2=S * C, **SIP)),
    ("pc_sip", dict(CDELT1=-S, CDELT2=S, PC1_1=C, PC1_2=-N, PC2_1=N, PC2_2=C, **SIP)),
    ("crota_near_pole", dict(CRVAL1=359.95, CRVAL2=88.7, CDELT1=-S, CDELT2=S, CROTA2=120.0)),
]

PIXELS = [(0.0, 0.0), (4655.0, 0.0), (0.0, 3519.0), (4655.0, 3519.0), (2327.5, 1759.5),
          (1234.25, 2987.75)]

out = {
    "generator": "generate.py, astropy " + __import__("astropy").__version__,
    "pixel_origin": 0,
    "forms": [],
}
for name, cards in CASES:
    header = {**BASE, **cards}
    h = fits.Header()
    for k, v in header.items():
        h[k] = v
    w = WCS(h)
    sky = [[x, y, *map(float, w.all_pix2world([[x, y]], 0)[0])] for x, y in PIXELS]
    out["forms"].append({
        "name": name,
        "cards": {k: v for k, v in header.items() if k != "NAXIS"},
        "sky": sky,
    })
text = json.dumps(out, indent=1)
# One line per sampled pixel.
print(re.sub(r"\[\s+([^\[\]{}]+?)\s+\]",
             lambda m: "[" + ", ".join(v.strip() for v in m.group(1).split(",")) + "]", text))
