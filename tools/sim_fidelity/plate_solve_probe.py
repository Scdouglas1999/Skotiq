#!/usr/bin/env python3
"""Prove that a simulated camera frame can be plate-solved.

Why this exists
---------------
`native/skotiq_native/bridge/src/sim_frame.rs` paints 45 pseudo-random
Gaussian stars and translates them as a rigid body with the mount. It does not
render the sky the mount is pointing at. Plate solving is NOT special-cased for
the simulator -- `api/plate_solve.rs` shells out to the real ASTAP binary -- so
under the simulator every plate-solve-dependent feature is unexercisable:
Slew & Center, the centering dialog, the framing wizard, mosaic tile solving,
meridian-flip recentre, blind solve, the catalog overlay (which needs a WCS),
the plate-solving settings Test button, and polar alignment's solve path.

This harness is the reference implementation and the acceptance test for fixing
that: it renders a gnomonic (TAN) projection of real catalogue stars onto the
simulated sensor geometry and hands the frame back to ASTAP. If ASTAP recovers
the commanded centre, the simulator can drive the whole automated-imaging spine
with no hardware attached.

Measured result (D05, 2026-08-09, this machine):

    field    focal   solved centre error
    Orion    1000mm  0.5"
    Cygnus   1000mm  0.5"
    Sparse   1000mm  0.5"
    Orion     400mm  1.4"
    Orion     200mm  2.7"
    Orion     135mm  3.9"

The error tracks the pixel scale (0.78"/px at 1000mm, 5.74"/px at 135mm), i.e.
sub-pixel throughout.

Two traps this harness already fell into, both worth keeping:

* **Catalogue depth is the limiter, not the projection.** Rendered from the
  app's bundled HYG catalogue (2.9 stars/deg^2), a 400mm field holds 6 stars and
  ASTAP aborts with "Only 4 stars found in image". Rendered from ASTAP's own D05
  Gaia set (500 stars/deg^2 -- the very catalogue the solver matches against) the
  same field holds 300+ and solves. Read the solver's database and the simulated
  sky cannot disagree with it by construction.

* **ASTAP's .wcs output is a FITS header**: 80-byte cards with no line
  terminators. `splitlines()` returns one giant line and a `startswith('CRVAL1')`
  scan silently finds nothing, which reads as "no solve" while ASTAP is printing
  "Solution found". An earlier version of this script reported four focal
  lengths as failures on exactly that bug.

Usage
-----
    python3 tools/sim_fidelity/plate_solve_probe.py \
        --astap ~/.local/share/skotiq-audit/astap/bin \
        --focal 400 --ra 5.59 --dec -5.39

`--astap` is a directory holding both `astap_cli` and the `*_*.1476` database
files. Nothing is installed system-wide.
"""
import argparse
import glob
import math
import os
import re
import struct
import subprocess
import sys

# The simulated sensor, as declared by device_capabilities.rs and sim_frame.rs.
SIM_W, SIM_H = 1920, 1080
PIXEL_UM = 3.76

SKY_ADU = 300.0
READ_NOISE_ADU = 12.0
MAX_ADU = 65535

DEC_SCALE = 90.0 / (128 * 256 * 256 - 1)
RA_SCALE = 24.0 / (256 * 256 * 256 - 1)


# --------------------------------------------------------------------------
# ASTAP star database (.1476, record format 5), per unit_star_database.pas
# --------------------------------------------------------------------------

def read_area(path, want=None):
    """Yield (ra_deg, dec_deg, mag) from one area file.

    110-byte text header whose byte[109] is the record size. Then 5-byte
    records: RA in three little-endian bytes, DEC in two -- its high byte comes
    from the most recent header record (RA == 0xFFFFFF), which also carries the
    magnitude for the run of stars that follows.
    """
    with open(path, 'rb') as fh:
        head = fh.read(110)
        if len(head) < 110 or head[109] != 5:
            return
        blob = fh.read()
    dec9 = 0
    mag = 0.0
    if want:
        wra, wdec, wrad = want
        cos_lim = math.cos(math.radians(wrad))
        swd, cwd = math.sin(math.radians(wdec)), math.cos(math.radians(wdec))
    for off in range(0, len(blob) - 4, 5):
        b0, b1, b2, b3, b4 = blob[off:off + 5]
        ra_raw = b0 | (b1 << 8) | (b2 << 16)
        if ra_raw == 0xFFFFFF:
            dec9 = b3 - 128
            mag = (b4 - 16) / 10.0
            continue
        dec = (b3 | (b4 << 8) | (dec9 << 16)) * DEC_SCALE
        ra = ra_raw * RA_SCALE * 15.0
        if want:
            cos_c = swd * math.sin(math.radians(dec)) + cwd * math.cos(
                math.radians(dec)) * math.cos(math.radians(ra - wra))
            if cos_c < cos_lim:
                continue
        yield ra, dec, mag


def build_index(db_dir, prefix):
    """A bounding CAP per area file, so a field reads a handful, not 1476.

    A RA/Dec bounding box is the wrong shape: it is torn at the RA=0 wrap and
    degenerate near the poles, and a file dropped for either reason leaves a
    blank wedge in the frame -- ASTAP then finds image stars where its database
    has none. A unit vector plus an angular radius has no seam.
    """
    index = []
    for path in sorted(glob.glob(os.path.join(db_dir, prefix + '_*.1476'))):
        sx = sy = sz = 0.0
        vecs = []
        for ra, dec, _ in read_area(path):
            r, d = math.radians(ra), math.radians(dec)
            v = (math.cos(d) * math.cos(r), math.cos(d) * math.sin(r), math.sin(d))
            vecs.append(v)
            sx += v[0]; sy += v[1]; sz += v[2]
        if not vecs:
            continue
        n = math.sqrt(sx * sx + sy * sy + sz * sz) or 1.0
        cx, cy, cz = sx / n, sy / n, sz / n
        worst = min(cx * v[0] + cy * v[1] + cz * v[2] for v in vecs)
        index.append((path, cx, cy, cz,
                      math.degrees(math.acos(max(-1.0, min(1.0, worst))))))
    return index


def field(index, ra_deg, dec_deg, radius_deg, limit=1500):
    r, d = math.radians(ra_deg), math.radians(dec_deg)
    vx, vy, vz = math.cos(d) * math.cos(r), math.cos(d) * math.sin(r), math.sin(d)
    stars = []
    for path, cx, cy, cz, cap in index:
        dot = max(-1.0, min(1.0, vx * cx + vy * cy + vz * cz))
        if math.degrees(math.acos(dot)) <= cap + radius_deg:
            stars.extend(read_area(path, want=(ra_deg, dec_deg, radius_deg)))
    # Brightest first: truncating on anything else leaves the frame complete to
    # no particular depth, which is what breaks the solver's quad match.
    stars.sort(key=lambda s: s[2])
    return stars[:limit]


# --------------------------------------------------------------------------
# Rendering
# --------------------------------------------------------------------------

def project(stars, ra0_deg, dec0_deg, scale_arcsec, rot_deg=0.0):
    ra0, dec0 = math.radians(ra0_deg), math.radians(dec0_deg)
    sin_d0, cos_d0 = math.sin(dec0), math.cos(dec0)
    scale_rad = math.radians(scale_arcsec / 3600.0)
    rot = math.radians(rot_deg)
    cos_r, sin_r = math.cos(rot), math.sin(rot)
    cx, cy = SIM_W / 2.0, SIM_H / 2.0
    out = []
    for ra_deg, dec_deg, mag in stars:
        ra, dec = math.radians(ra_deg), math.radians(dec_deg)
        cos_c = sin_d0 * math.sin(dec) + cos_d0 * math.cos(dec) * math.cos(ra - ra0)
        if cos_c <= 0.05:
            continue
        xi = math.cos(dec) * math.sin(ra - ra0) / cos_c
        eta = (cos_d0 * math.sin(dec) - sin_d0 * math.cos(dec)
               * math.cos(ra - ra0)) / cos_c
        # RA increases to the left on a sky-side-up frame.
        px, py = -xi / scale_rad, -eta / scale_rad
        x = cx + px * cos_r - py * sin_r
        y = cy + px * sin_r + py * cos_r
        if -20 <= x < SIM_W + 20 and -20 <= y < SIM_H + 20:
            out.append((x, y, mag))
    return out


def render(placed, sigma=1.8, zero_point=12.0, seed=7):
    import random
    n = SIM_W * SIM_H
    rnd = random.Random(seed)
    buf = [SKY_ADU + rnd.gauss(0.0, READ_NOISE_ADU) for _ in range(n)]
    radius = int(math.ceil(sigma * 4))
    two_sigma_sq = 2.0 * sigma * sigma
    for x, y, mag in placed:
        peak = min((MAX_ADU - SKY_ADU) * (10.0 ** (-0.4 * (mag - zero_point))),
                   MAX_ADU - SKY_ADU)
        xi, yi = int(round(x)), int(round(y))
        for dy in range(-radius, radius + 1):
            py = yi + dy
            if not 0 <= py < SIM_H:
                continue
            for dx in range(-radius, radius + 1):
                px = xi + dx
                if not 0 <= px < SIM_W:
                    continue
                v = peak * math.exp(-((px - x) ** 2 + (py - y) ** 2) / two_sigma_sq)
                if v >= 1.0:
                    buf[py * SIM_W + px] += v
    return [max(0, min(MAX_ADU, int(v))) for v in buf]


def _sexa_ra(h):
    hh = int(h); mm = int((h - hh) * 60)
    return '%02d %02d %05.2f' % (hh, mm, (h - hh - mm / 60.0) * 3600)


def _sexa_dec(d):
    sign = '-' if d < 0 else '+'
    d = abs(d); dd = int(d); mm = int((d - dd) * 60)
    return '%s%02d %02d %04.1f' % (sign, dd, mm, (d - dd - mm / 60.0) * 3600)


def write_fits(path, pix, ra_hours, dec_deg, focal_mm):
    cards = [('SIMPLE', 'T'), ('BITPIX', 16), ('NAXIS', 2),
             ('NAXIS1', SIM_W), ('NAXIS2', SIM_H),
             ('BZERO', 32768), ('BSCALE', 1), ('EXPTIME', 10.0),
             ('XPIXSZ', PIXEL_UM), ('YPIXSZ', PIXEL_UM), ('FOCALLEN', focal_mm),
             ('OBJCTRA', _sexa_ra(ra_hours)), ('OBJCTDEC', _sexa_dec(dec_deg))]
    header = b''
    for key, value in cards:
        if value == 'T':
            val = 'T'
        elif isinstance(value, str):
            val = "'%-8s'" % value
        elif isinstance(value, float):
            val = '%.6f' % value
        else:
            val = str(value)
        header += ('%-8s= %20s' % (key, val)).ljust(80).encode()
    header += b'END'.ljust(80)
    header += b' ' * ((2880 - len(header) % 2880) % 2880)
    data = b''.join(struct.pack('>h', v - 32768) for v in pix)
    data += b'\0' * ((2880 - len(data) % 2880) % 2880)
    with open(path, 'wb') as fh:
        fh.write(header + data)


# --------------------------------------------------------------------------
# Solving
# --------------------------------------------------------------------------

def read_crval(base):
    """ASTAP's .wcs is a FITS header: 80-byte cards, no line terminators."""
    for ext in ('.wcs', '.ini'):
        path = base + ext
        if not os.path.exists(path):
            continue
        blob = open(path, 'rb').read()
        chunks = [blob[i:i + 80].decode('latin-1') for i in range(0, len(blob), 80)]
        chunks += open(path, errors='ignore').read().splitlines()
        vals = {}
        for chunk in chunks:
            m = re.match(r'\s*(CRVAL[12])\s*=\s*([-+0-9.eE]+)', chunk)
            if m:
                vals[m.group(1)] = float(m.group(2))
        if 'CRVAL1' in vals and 'CRVAL2' in vals:
            return vals['CRVAL1'], vals['CRVAL2']
    return None


def solve(astap_bin, db_dir, prefix, path, ra_hours, dec_deg, fov_h_deg):
    base = path[:-5] if path.endswith('.fits') else path
    for ext in ('.wcs', '.ini'):
        if os.path.exists(base + ext):
            os.remove(base + ext)
    result = subprocess.run(
        [astap_bin, '-f', path, '-r', '10', '-fov', '%.4f' % fov_h_deg,
         '-ra', '%.5f' % ra_hours, '-spd', '%.5f' % (dec_deg + 90.0),
         '-d', db_dir, '-D', prefix, '-o', base, '-wcs'],
        capture_output=True, text=True, timeout=600)
    return read_crval(base), result.stdout.strip().splitlines()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--astap', required=True,
                    help='directory holding astap_cli and the *.1476 database')
    ap.add_argument('--prefix', default='d05', help='star database prefix')
    ap.add_argument('--focal', type=float, action='append',
                    help='focal length in mm (repeatable, default 1000/400/200/135)')
    ap.add_argument('--ra', type=float, default=5.59, help='centre RA in hours')
    ap.add_argument('--dec', type=float, default=-5.39, help='centre Dec in degrees')
    ap.add_argument('--out', default='/tmp', help='where to write the frames')
    args = ap.parse_args()

    db_dir = os.path.expanduser(args.astap)
    astap_bin = os.path.join(db_dir, 'astap_cli')
    if not os.path.exists(astap_bin):
        print('no astap_cli in %s' % db_dir, file=sys.stderr)
        return 2

    index = build_index(db_dir, args.prefix)
    if not index:
        print('no %s_*.1476 files in %s' % (args.prefix, db_dir), file=sys.stderr)
        return 2
    print('indexed %d area files' % len(index))

    ra_deg = args.ra * 15.0
    failures = 0
    for focal in (args.focal or [1000, 400, 200, 135]):
        scale = 206.265 * PIXEL_UM / focal
        fov_w = scale * SIM_W / 3600.0
        fov_h = scale * SIM_H / 3600.0
        radius = math.hypot(fov_w, fov_h) / 2.0 * 1.15
        stars = field(index, ra_deg, args.dec, radius)
        placed = project(stars, ra_deg, args.dec, scale)
        if not placed:
            print('%5.0fmm  no stars in field' % focal)
            failures += 1
            continue
        faint = max(s[2] for s in placed)
        path = os.path.join(args.out, 'sim_sky_%d.fits' % int(focal))
        write_fits(path, render(placed, zero_point=faint - 6.0),
                   args.ra, args.dec, focal)
        got, tail = solve(astap_bin, db_dir, args.prefix, path,
                          args.ra, args.dec, fov_h)
        if got:
            err = math.hypot((got[0] - ra_deg) * math.cos(math.radians(args.dec)),
                             got[1] - args.dec) * 3600.0
            print('%5.0fmm  %5.2f"/px  stars=%4d  SOLVED  centre error %.1f"'
                  % (focal, scale, len(placed), err))
        else:
            failures += 1
            print('%5.0fmm  %5.2f"/px  stars=%4d  NO SOLVE  %s'
                  % (focal, scale, len(placed), tail[-1] if tail else '?'))
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
