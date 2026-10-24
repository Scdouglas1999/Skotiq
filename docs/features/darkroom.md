# Building masters across nights

Open **Darkroom → Build masters** on the computer that holds your captures.
The workflow reads captured light frames from Skotiq’s image library and exports
linear FITS masters suitable for PixInsight or another FITS editor.

1. Select a target. Frames are listed by observing night, which runs from noon
   to noon, so frames taken after midnight stay with the evening they started.
   Expand a night to inspect thumbnails and exclude frames, or uncheck the
   night. Capture-rejected frames stay excluded.
2. Select **Prepare calibration**. Skotiq groups the lights by night, camera,
   optics, geometry, filter and acquisition settings, then looks for local
   calibration-library matches. Small cooler drift within a night does not
   split a group; only a different set point does. When a filter has a flat
   on some nights and not others, that flat is used for the other nights too,
   and the group says so.
3. Review calibration per filter. **One flat for all <filter> nights** applies
   one master flat to every night of that filter. Choose existing bias, dark and
   flat masters, or use **Build from frames** to create them; masters built here
   are added to the calibration library. Building a flat requires a matching
   master bias or dark-flat. When some filters have flats and others do not,
   Skotiq names them and asks you to confirm building each one without flats.
   Missing flats leave dust and vignetting uncorrected. Confirm that flats
   belong to the same optical setup; headers cannot establish camera rotation
   or whether dust moved.
4. Choose a good alignment reference. Every filter uses that same field. Set the
   minimum overlap per frame, the maximum star eccentricity and the smallest
   common crop to accept; defaults are 95%, 0.65 and 80%.
5. Select **Check framing**. Skotiq registers every selected light from its
   stars, without integrating anything, and shows where each frame lands on the
   reference grid, colored by night or by side of the pier. The shaded
   rectangle is the crop every filter will share, with the percentage of the
   field it keeps. The frames that limit the crop are listed with how much
   would be kept without each; **Exclude** removes one and the map updates at
   once. Frames that cannot be registered or fall below the overlap limit are
   listed with their reasons.
6. Select **Build masters** and choose an output folder. The build runs in the
   background: you can close the window, and Darkroom shows its progress with a
   way back to it. The window shows the filter being built, the light count,
   an estimate of the time left, the light being processed and the filters
   finished so far. A notification is sent when the build ends. A filter that
   cannot be built is reported and the others are still built.
7. Review the completed masters and counts. **Open master** uses your operating
   system's FITS-file association; associate FITS with PixInsight to open it there.
   **Open output folder** exposes the files for copying or sharing. Completed
   masters also appear in Darkroom's Masters tab.

## Unattended builds

Skotiq can build every filter of a target from all of its nights without the
window: it uses the calibration library's matches, shares a filter's flat
across its nights, builds filters without flats when there are none, picks a
luminance light as the reference, and checks framing. Integration starts only
when the common crop keeps at least the minimum (80% by default). Otherwise
nothing is integrated, a notification names the frames that limit the crop,
and Darkroom shows the framing review so you can exclude them and build.

## Framing and linear output

Skotiq calibrates, registers and integrates each filter using star-signal weights
and online sigma rejection. It excludes frames outside your overlap limit, then
crops every exported filter to the same largest rectangle covered by every
included exposure. This removes borders with fewer contributing exposures. The
crop is known before integration from the framing check; a frame's footprint
leaves out the few edge pixels the resampling kernel cannot fully support.

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
source files or changed settings. Excluding frames or changing the smallest
acceptable crop keeps the folder: filters whose frames did not change are
reused and the others are built again. To change calibration or the per-frame
limits, start a new build.
