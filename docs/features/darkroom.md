# Building masters across nights

Open **Darkroom → Build masters** on the computer that holds your captures.
The workflow reads captured light frames from Skotiq’s image library and exports
linear FITS masters suitable for PixInsight or another FITS editor.

1. Select a target. Expand **Review frames** to inspect thumbnails and exclude
   individual frames or entire nights. Capture-rejected frames stay excluded.
2. Select **Prepare calibration**. Skotiq groups the lights by night, camera,
   optics, geometry, filter and acquisition settings, then looks for local
   calibration-library matches. Expand each group to review its selections.
3. Choose existing bias, dark and flat masters, or use **Build from frames** to
   create them. Building a flat requires a matching master bias or dark-flat.
   Use **None** deliberately when a master is unavailable; missing flats leave
   dust and vignetting uncorrected. Confirm that flats belong to the same optical
   setup—headers cannot establish camera rotation or whether dust moved.
4. Choose a good alignment reference. Every filter uses that same field. Set the
   minimum overlap and maximum star eccentricity; defaults are 95% and 0.65.
   Frames failing registration, overlap or star-shape checks are excluded and
   their reasons are recorded.
5. Confirm the calibration review, select **Build and export masters**, and choose
   an output folder. Skotiq checks calibration compatibility before starting.
   Incompatible masters and broad near-black defects in flats stop the build
   with an explanation so you can choose another master or omit it explicitly.
6. Review the completed masters and counts. **Open master** uses your operating
   system’s FITS-file association; associate FITS with PixInsight to open it there.
   **Open output folder** exposes the files for copying or sharing. Completed
   masters also appear in Darkroom’s Masters tab.

## Framing and linear output

Skotiq calibrates, registers and integrates each filter using star-signal weights
and online sigma rejection. It excludes frames outside your overlap limit, then
crops every exported filter to the same largest rectangle covered by every
included exposure. This removes borders with fewer contributing exposures. If
less than 80% of the original field remains, export stops for framing review;
exclude shifted frames or tighten overlap and start a new build.

Exported masters are floating-point linear FITS files. All filters receive one
common linear scale, recorded in the FITS header. Only preview PNGs are stretched.
Full-size intermediate masters remain available in the build folder alongside
`report.json` (calibration, processing results and crop) and `frame-audit.csv`
(included and excluded frames with reasons). Source captures are never changed.

## Interrupted builds

The dialog shows the build folder while it works. After stopping or encountering
an error, use **Resume this build**. After restarting Skotiq, select **Resume saved
build** and choose that folder. Completed filters are reused; an interrupted
filter starts over without double-counting exposures. Resume refuses changed
source files or changed settings. To change calibration, framing limits or frame
selection, start a new build.
