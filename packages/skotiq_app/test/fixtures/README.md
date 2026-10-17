# Test fixtures

## `ic434_horsehead_uk_schmidt.png`

IC 434 (the Horsehead Nebula), photographed by the **UK Schmidt Telescope** on
1990-12-22 through an OG590 filter and digitised by the Digitized Sky Survey.
The same frame is in the repository as
`reports/tonight-readiness-*/HorseHead.fits` (891 x 893, 16-bit).

It is used by `test/golden/public_screenshots_test.dart` as the captured frame
in the Imaging and Tonight screenshots, so the published screenshots show a
real astronomical image rather than an empty viewer or a synthetic starfield.

The PNG is the FITS after one offline pass: a robust black point at the 10th
percentile, white at the 99.9th, an asinh stretch, and a vertical flip for the
FITS bottom-left origin. Doing it offline keeps a FITS decoder out of the test.

The DSS plates are made available for non-commercial use by the Space Telescope
Science Institute; the surveys were produced at STScI under U.S. Government
grant NAG W-2166, from photographic plates taken with the UK Schmidt Telescope
and the Oschin Schmidt Telescope on Palomar Mountain.
