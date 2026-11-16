# Test fixtures

## `m31_dss2_gray.png`

M31 from the Digitized Sky Survey (the DSS2 color survey, through the CDS HiPS
service), the same survey pixels as `hips/` (see `hips/README.md` for
provenance and attribution). It is the center 735 x 491 of
`hips/goldens/hips_fixture_m31_mosaic.png` (a 3 x 2 degree field), which is the
field a 6248 x 4176 sensor at 1.41"/px covers, converted to grayscale with a
light black-point and gamma adjustment.

It is used by `test/golden/public_screenshots_test.dart` as the luminance frame
on the Tonight stage and in the Imaging viewer, so the published screenshots
of the M31 run show a real image of M31.

The DSS plates are made available for non-commercial use by the Space Telescope
Science Institute; the surveys were produced at STScI under U.S. Government
grant NAG W-2166, from photographic plates taken with the UK Schmidt Telescope
and the Oschin Schmidt Telescope on Palomar Mountain.
