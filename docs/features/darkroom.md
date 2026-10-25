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

When **Auto-integrate** is on, the end of a night starts this build for each
target the night imaged: a run that completes its plan, a run ended by the
dawn park or an obstruction, and a night the operator stopped and then closed
with **Run now** in end-of-night calibration. The build waits for that
night's calibration frames, so tonight's darks and bias are in the library
when it matches them.

## Framing and linear output

Skotiq calibrates each light in 32-bit floating point, registers it onto the
reference and weights it by its star signal. Frames outside your overlap limit
are left out. A dark whose exposure differs from the light's is scaled to it
when a bias is available.

Each filter is then integrated in one pass over all of its subs, with the
rejection PixInsight picks by default for the number of frames:

- fewer than 8 subs: percentile clipping (low 0.2, high 0.1);
- 8 to 19 subs: Winsorized sigma clipping (low 4, high 3 sigma);
- 20 or more subs: generalized extreme Studentized deviate (ESD), with an
  outlier fraction of 0.3, significance 0.05 and a low relaxation of 1.5.

The rejected samples are combined with a weighted mean. Registered subs are
held in memory when a filter's subs fit in 1 GB; otherwise they are written to
a working folder beside the master and removed when the filter is done, which
takes about 65 MB per full-size sub. The build checks the free space on that
drive before it starts and stops at once, naming the space needed and the
space free, when it would not fit.

Every exported filter is cropped to the same largest rectangle covered by
every included exposure. This removes borders with fewer contributing
exposures. The crop is known before integration from the framing check; a
frame's footprint leaves out the few edge pixels the resampling kernel cannot
fully support.

Exported masters are linear floating-point FITS files with nothing clipped. By
default every filter is written as its calibrated ADU divided by 65535, so the
filters keep their ratios and zero point; the per-filter option instead spans
each filter from its own minimum to its maximum. The headers carry the optics,
the number of combined subs, the total exposure, the rejection used and a WCS.
When R, G and B masters are built, a linear RGB composite is written as well,
and with an L master a linear LRGB composite, as FITS and XISF; neither has
color calibration or background extraction. Only preview PNGs are stretched.
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
