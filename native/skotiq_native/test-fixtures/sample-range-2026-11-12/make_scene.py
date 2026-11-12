"""Synthetic star field in the conventions under test. numpy only."""
import numpy as np, struct, sys, os
out = sys.argv[1]
rng = np.random.default_rng(20261112)
W, H = 400, 300
yy, xx = np.mgrid[0:H, 0:W].astype(np.float64)
img = 1000.0 + 0.15 * xx + rng.normal(0, 18.0, (H, W))
stars = []
for i in range(45):
    x = rng.uniform(15, W - 15); y = rng.uniform(15, H - 15)
    sigma = rng.uniform(1.4, 2.6)
    peak = 10 ** rng.uniform(2.5, 4.6)
    stars.append((x, y, sigma, peak))
    img += peak * np.exp(-((xx - x) ** 2 + (yy - y) ** 2) / (2 * sigma * sigma))
# Two stars that saturate a 16-bit sensor.
for (x, y) in [(120.3, 200.7), (300.2, 90.4)]:
    img += 300000.0 * np.exp(-((xx - x) ** 2 + (yy - y) ** 2) / (2 * 2.2 * 2.2))
u16 = np.clip(np.rint(img), 0, 65535).astype(np.uint16)

def card(k, v, c=None):
    s = f"{k:<8}= {v:>20}"
    if c: s += f" / {c}"
    return s.ljust(80)[:80]

def fits(path, data, bitpix, extra=()):
    cards = [card("SIMPLE", "T"), card("BITPIX", bitpix), card("NAXIS", 2),
             card("NAXIS1", data.shape[1]), card("NAXIS2", data.shape[0])]
    if bitpix == 16:
        cards += [card("BZERO", 32768), card("BSCALE", 1)]
        body = (data.astype(np.int32) - 32768).astype(">i2").tobytes()
    elif bitpix == -32:
        body = data.astype(">f4").tobytes()
    cards += [card(k, v) for k, v in extra]
    cards += [card("EXPTIME", "60.0"), card("IMAGETYP", "'Light   '"), "END".ljust(80)]
    head = "".join(cards).encode()
    head += b" " * (-len(head) % 2880)
    body += b"\0" * (-len(body) % 2880)
    open(path, "wb").write(head + body)

def xisf(path, data, bounds):
    raw = data.astype("<f4").tobytes()
    def xml(pos):
        return (f'<?xml version="1.0" encoding="UTF-8"?><xisf version="1.0" xmlns="http://www.pixinsight.com/xisf" '
                f'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.pixinsight.com/xisf http://pixinsight.com/xisf/xisf-1.0.xsd">'
                f'<Image geometry="{data.shape[1]}:{data.shape[0]}:1" sampleFormat="Float32" bounds="{bounds}" colorSpace="Gray" '
                f'location="attachment:{pos}:{len(raw)}"/></xisf>').encode()
    pos = 16 + len(xml(10 ** 7)) + 64
    x = xml(pos)
    head = b"XISF0100" + struct.pack("<I", len(x)) + b"\0\0\0\0" + x
    head += b"\0" * (pos - len(head))
    open(path, "wb").write(head + raw)

f = u16.astype(np.float32)
fits(f"{out}/scene_u16.fits", u16, 16)
fits(f"{out}/scene_f32_adu.fits", f, -32)
fits(f"{out}/scene_f32_unit.fits", f / 65535.0, -32)
fits(f"{out}/scene_f32_adu_datamax.fits", f, -32, [("DATAMIN", "0.0"), ("DATAMAX", "65535.0")])
xisf(f"{out}/scene_f32_bounds_adu.xisf", f, "0:65535")
g = f.copy(); g[0, 0] = -500.0; g[0, 1] = 70000.0
xisf(f"{out}/scene_f32_bounds_adu_outliers.xisf", g, "0:65535")
np.save(f"{out}/scene_u16.npy", u16)
print("median", np.median(u16), "max", u16.max(), "n_sat", int((u16 == 65535).sum()))
