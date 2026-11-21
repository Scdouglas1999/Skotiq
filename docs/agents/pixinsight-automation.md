# PixInsight execution, evidence, exports, and publishing

Companion to [the editing workflow](pixinsight-editing.md). These are proven local execution patterns as of October 28, 2026, with explicit limits. Reinspect paths, running processes and UI before using them.

## Existing desktop instance

Executable: `/opt/PixInsight/bin/PixInsight.sh`. Existing IPC dispatcher: `/home/scdouglas/.cache/skotiq-morning-20261028/run-pi.py`; an archival copy is in the reference packet's `execution/` folder.

The dispatcher checks for exactly one existing PixInsight process, reads only its display-related environment values, and runs:

```bash
python3 /home/scdouglas/.cache/skotiq-morning-20261028/run-pi.py /absolute/path/to/new-script.js
```

This uses PixInsight's `--execute=/absolute/script.js` IPC path. The command can return after **dispatch**, before processing completes. Completion requires a fresh success artifact and the expected images/log output. A stopped process or shell exit code alone is insufficient.

If the cache helper is missing, inspect the archived helper and adapt it. Recompute the current PID and DISPLAY/XAUTHORITY/WAYLAND_DISPLAY/XDG_RUNTIME_DIR. Do not hardcode a historical PID, print the whole environment, or open another application instance just to run a script. If multiple instances exist, identify the intended session before dispatching.

Before any mutation, list open `ImageWindow` IDs and paths and inspect which is the actual source. Work on a new copy with a unique ID and a fresh output directory. Do not rely on whichever window happens to be active after a process creates new windows.

## A bounded PJSR operation

This example illustrates the already accepted extra NoiseX pass. Adapt the source/output paths; run only when that operation is requested. Directory `out` must exist and must be new for the run, so old completion files cannot be mistaken for success.

```javascript
var source = '/absolute/path/to/accepted-full-resolution.xisf';
var out = '/absolute/path/to/new-run/';
console.beginLog(out + 'processing.log');
try {
   var w = ImageWindow.open(source)[0];
   w.mainView.id = 'Unique_Final_NoiseX';
   var p = new NoiseXTerminator;
   p.denoise = 0.60;
   p.enable_color_separation = false;
   p.enable_frequency_separation = false;
   p.detail = 0.20;
   p.iterations = 2;
   File.writeTextFile(out + 'NoiseX-settings.js', p.toSource());
   if (!p.executeOn(w.mainView, false))
      throw Error('NoiseX failed');
   if (!w.saveAs(out + 'accepted.xisf', false, false, false, false))
      throw Error('Native save failed');
   File.writeTextFile(out + 'complete.json', JSON.stringify({
      source: source,
      width: w.mainView.image.width,
      height: w.mainView.image.height,
      status: 'success'
   }));
} catch (e) {
   File.writeTextFile(out + 'error.txt', String(e));
   console.criticalln(String(e));
}
console.endLog();
```

The success marker means the saved operation completed, not that the result passed visual QA. Inspect it separately. Preserve the actual `toSource()` instance so default fields and active modes can be reconstructed.

For an unfamiliar process, inspect the installed UI and a newly exported process instance. Do not guess parameter enums or treat nonexistent properties as settings. Where applicable, use the process constants present in the installed version. For lengthy processing, save per-stage progress and checkpoints; make recovery resume from verified output rather than run the whole batch again.

## Important PJSR/processing traps from this edit

- **Process execution versus configuration:** constructing a process object or exporting its settings is not evidence it ran. Check `executeOn`/`executeGlobal`, logs, and changed/saved output.
- **Active window changes:** GraXpert, DBE, ChannelCombination and StarX can create or switch images. Track IDs explicitly and save the right model/target/stars. Detect new windows if necessary.
- **Metadata:** assigning pixel arrays to a new window does not automatically preserve all astrometry/properties. The working RGB used a calibrated image as a metadata carrier. Check dimensions and solution after channel combination or crop.
- **Range handling:** PixelMath rescale/truncate flags and FITS opening hints can change values. Set intentionally and record them. In the star-background case, explicitly subtracting the saved model from original stars avoided an unwanted pedestal from the directly corrected result.
- **Mask lifetime:** inspect the mask; attach it to the intended view; explicitly remove/disable it afterward. A forgotten mask can quietly limit a later final NoiseX pass.
- **NoiseX fields:** common denoise and separate intensity/color controls are alternate modes. Inactive default `.90` fields in a saved instance do not imply the image received `.90` reduction.
- **Geometry:** use the actual Crop process for delivery geometry, with margins/dimensions checked. `image.cropTo()` was used for throwaway QA pictures; those are not metadata-preserving delivery masters.
- **Legacy scripts:** numbered files record experimentation, not a clean dependency graph. Stage 09 provides a model but rejected stars; stage 10 provides accepted 21/22 checkpoints but a rejected later composite; stage 11 provides accepted 24 stars but an earlier comparison composite. The case study identifies accepted blocks.

## Local catalog fallback used here

PCC ran against a real cached APASS9 response, exposed by a small local HTTP adapter. The archive includes `catalog-server.py`, `APASS9-cached-source.json`, the response TSV, and PCC execution evidence. The source was retrieved for this field; it is not a general full-sky catalog.

The historical server reads an old cache path and binds to localhost port 18792. For a replay, adapt it to the preserved catalog path, verify field coverage and required columns, confirm the port is available, then start a task-owned server. Check its returned rows and the actual PCC fit. Stop only that exact server afterward. A configured URL without a running service is not a working calibration path. For other fields, obtain an appropriate real catalog; do not substitute fabricated rows or quietly label PCC as SPCC.

## Full-resolution exports

Retain the native XISF. For the archival TIFF, use explicit 16-bit integer output and verify readable RGB data. For the JPEG, use the full image, quality 100 in the reference case, and embedded sRGB. Read/preserve the actual color profile; convert appropriately if the working profile differs rather than merely relabeling a different space as sRGB.

The reference `13-export.js` and `15-noisex06.js` show `FileFormatInstance`, `ImageDescription.bitsPerSample`, `ieeefpSampleFormat`, and ICC assignment. The `.render().scaledTo(...)` path was used only for clearly named small chat previews.

Reopen exported files independently and verify:

1. Dimensions, channel count, orientation, bit depth, profile, and finite native pixels.
2. JPEG appearance against native at fit-to-window and 100%, including galaxy, colored stars, sky, and corners.
3. TIFF difference from native after scaling to the same numeric range; quantization is expected, unexpected clipping or nonlinear changes are not.
4. Saturated/zero-valued samples and their spatial locations, with any intentional decisions recorded.
5. SHA-256 and file size for the actual upload/delivery source.

`verify-final.py` is a reference implementation with hardcoded NGC 891 crop and sky patches. Adapt those to the image being checked; a successful run with stale coordinates is not valid QA. Final revision B has its own `verification.json`; do not mix it with pre-final-pass statistics.

## Evaluation record template

Keep one short record per accepted stage:

```text
Stage and source checkpoint:
Actual operation, version/model and active settings:
Output paths and geometry:
Purpose / visible defect addressed:
Comparisons inspected (same scale/stretch):
Sky sample exclusions, measurements, and units:
Galaxy/halo/star changes:
New artifacts or residual limitations:
Accept/reject decision and next accepted checkpoint:
```

A final receipt should add file hashes, export checks, user-visible preview/full-resolution links, and the actual published URL/revision if upload was requested. Preserve scripts and intermediate components, not only flattened output.

## AstroBin revision through the user's browser

Sean previously requested his existing **Zen browser**, which has his session, instead of the in-app ChatGPT browser. Inspect available browser control tools first. If the task requires native Zen and only local desktop automation is available, use the existing local helper pattern within current permissions. Do not extract stored passwords or browser cookies.

Historical helpers: `/home/scdouglas/.cache/skotiq-astrobin/{desktop.py,revision-ui.py,activate-zen.js,place-zen.js}`. `desktop.py` contains a historical PID and must be refreshed. Screenshots from Spectacle active-window mode include decoration/shadow offsets and can have a different scale from full-desktop screenshots. Re-ground coordinates after dialogs, resizing, movement, or browser changes.

During this upload, a temporary `ydotoold` virtual device's pointer acceleration caused wrong clicks. Flat acceleration was applied **only to that identified task-owned virtual device**, then restored and its daemon stopped. Never reuse a historical event number or change the user's physical mouse settings. Confirm the active window and pointer behavior before sensitive clicks. Prefer a supported locator/file-upload API when available.

Observed UI flow on October 28 (reinspect for later changes):

1. Open the intended existing image: `https://app.astrobin.com/i/6vgjri` for this target.
2. Image menu → **Upload new revision**. Confirm the target title; this preserves project acquisition records.
3. Select the verified full-resolution JPEG, not `preview.jpg`. Confirm filename and size.
4. Review revision options. The accepted upload used **Mark as final**. Existing notification/activity defaults were retained.
5. Upload; wait for the revision editor. Add a concise, accurate description of processing changes. For unchanged light data, retain the existing exposure/integration records.
6. Save the revision. Verify the actual resulting revision page, image, dimensions and integration table. Record the real revision identifier rather than assuming the next letter.

This run produced revision **B**, 3800×2800, 4.72 MB, 27 h 19 m 30 s. Publishing was explicitly authorized by the user. A future request to edit an image alone does not automatically authorize publication.

## Cleanup and persistence

Keep originals, accepted deliverables, masks/components, scripts, process exports, catalog provenance and final receipts. Close only your unneeded saved views. Identify discarded generated intermediates before deletion; record what was removed. Raw data, masters, user windows and unrelated processes are outside cleanup scope.

Use the reference archive rather than relying solely on `.cache` helpers. Leave the final accepted image open/available. Stop task-owned catalog servers and input daemons; release a task-owned sleep inhibitor only after verifying its current process identity. Do not alter imaging equipment or a running Skotiq sequence to finish a desktop edit.

Vendor manuals used when establishing the processing order:

- [BlurXTerminator technical manual](https://www.rc-astro.com/blurxterminator-technical-manual/)
- [NoiseXTerminator 2 / AI3 PixInsight manual](https://www.rc-astro.com/noisexterminator-2-ai3-user-manual-pixinsight/)

For a different installed version, consult its current primary documentation before assuming new APIs or changed behavior.
