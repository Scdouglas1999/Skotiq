"""astropy's reading of each solver `.wcs` here: RA and Dec (degrees) at the
center and the four corner pixel centers of the 4656 x 3520 frame, 0-based
pixels, `all_pix2world(.., 0)` (SIP included).

    python generate.py > astropy.json    (astropy 8.0.2)
"""
import json
import pathlib
import warnings

from astropy.io import fits
from astropy.wcs import WCS, FITSFixedWarning

warnings.simplefilter("ignore", FITSFixedWarning)
here = pathlib.Path(__file__).parent
WIDTH, HEIGHT = 4656, 3520
PIXELS = [
    ((WIDTH - 1) / 2, (HEIGHT - 1) / 2),
    (0, 0),
    (WIDTH - 1, 0),
    (0, HEIGHT - 1),
    (WIDTH - 1, HEIGHT - 1),
]
out = {}
for path in sorted(here.glob("*.wcs")):
    header = fits.Header.fromstring(path.read_bytes().decode("ascii"))
    header["NAXIS"] = 2
    header["NAXIS1"], header["NAXIS2"] = WIDTH, HEIGHT
    wcs = WCS(header)
    out[path.name] = [
        [x, y, *(float(v) for v in wcs.all_pix2world([[x, y]], 0)[0])] for x, y in PIXELS
    ]
print(json.dumps({"width": WIDTH, "height": HEIGHT, "points": out}, indent=1))
