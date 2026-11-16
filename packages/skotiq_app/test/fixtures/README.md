# Test fixtures

## `m31_l_30s_rig.png`

A 30 s luminance sub of M31 taken by the owner's rig (ZWO ASI1600MM-Cool on a
10-inch f/4 Newtonian, gain 76, -10 C) on November 16, 2026. It is the raw,
uncalibrated light frame rendered through the app's own auto-stretch
(`apiCalculateAutoStretch` and `apiApplyStretch`, the screen-transfer function
the app uses for previews), then reduced to half size (2328 x 1760) to keep the
repository small. Nothing else was done to it: the vignetting, gradient and
dust shadows are in the frame.

It is used by `test/golden/public_screenshots_test.dart` as the latest frame on
the Tonight stage, in the Imaging viewer and as the frame-strip thumbnail.

## `darkroom/`

One sub per filter from the same night (M31 and M1, L, R, G and B, 30 s each,
gain 76, -10 C), rendered through the same auto-stretch as
`m31_l_30s_rig.png`, converted to gray and reduced to a quarter (1164 x 880,
JPEG). The public screenshots register them as the previews of the Darkroom's
masters. They are single raw subs, not stacks: a caption must not call them
masters' pixels.

## `hyg_v44_bright.csv.gz`

The HYG star database v4.4 (Hipparcos, Yale Bright Star and Gliese, compiled
by David Nash, astronexus.com, CC BY-SA 4.0) cut to the 15,597 stars of V 7.0
and brighter, in the HYG CSV layout the app installs, with the columns the app
does not read left empty. The screenshots decompress it into the catalog
folder with its metadata file, as the app's catalog download leaves an
install. The cut is CC BY-SA 4.0 like its source.

## `weather_tiles/`

Esri World Dark Gray Canvas basemap tiles (Base and Reference layers, zoom 9)
around the screenshots' site, Spruce Knob, West Virginia: the tiles the Weather
map asks for at 1920 x 1080. Recorded once from services.arcgisonline.com,
which the app uses for this map. Credit: Esri, HERE, Garmin, (c) OpenStreetMap
contributors, and the GIS user community. The Base tiles are JPEG data under a
`.png` name, as the server sends them.

## `framing/ngc7331_sdss_color.jpg`

SDSS color cutout of NGC 7331 (2.0 x 1.5 degrees, 800 x 600, 9 arcsec per
pixel), the field and size the Framing screen requests from CDS hips2fits for
its SDSS Color survey. On 2026-11-16 neither CDS (hips2fits answered 404) nor
NASA SkyView (its SDSS and 2MASS back ends failed) served it, so it was taken
from the SDSS SkyServer DR18 JPEG cutout service, the same SDSS imaging.
Credit: Sloan Digital Sky Survey (SDSS).
