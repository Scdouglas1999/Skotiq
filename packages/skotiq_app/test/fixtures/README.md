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
