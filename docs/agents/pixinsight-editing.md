# PixInsight editing brief for future agents

This is the working procedure derived from Sean's accepted NGC 891 Ha-LRGB edit of October 28, 2026. Read it before editing his astronomical images in PixInsight, diagnosing uneven image backgrounds, or delivering/uploading an edited result. It describes an inspected, user-approved workflow, not an automated guarantee of image quality.

**Success means:** a detailed, believable galaxy; natural and reasonably vibrant stars; a clean, gently textured sky; protected faint halo; supported Ha enhancement; and verified full-resolution deliverables. A process completing successfully is only an intermediate checkpoint.

## Read only the references your task needs

- [NGC 891 reference recipe](pixinsight-ngc891-reference.md): exact accepted parameters, file lineage, rejected experiments, and final revision B. Read for this dataset or to establish a comparable starting point.
- [PixInsight execution and delivery](pixinsight-automation.md): existing-instance IPC, PJSR pitfalls, exports, cleanup, and AstroBin revision procedure. Read before operating the desktop app or scripting it.
- Preserved source scripts and evidence: `/home/scdouglas/Documents/PixInsight-Agent-Guide/reference-2026-10-28/`. Its `INDEX.md` distinguishes source evidence from runnable recipes. The files contain historical absolute paths and are **not a batch script to execute in numerical order**.

## User preferences established by the accepted edit

Preserve a generous field around the galaxy. Sean preferred the 3800 × 2800 composition over a tight crop and expects the download/upload to retain that full resolution. Use the actual PixInsight app and licensed BlurXTerminator and NoiseXTerminator. GraXpert is available and materially improved this dataset when applied to individual filters. Keep RGB, luminance, Ha, and stars independently editable until their contributions are satisfactory. Avoid green contamination in gold/orange stars, lifeless star colors, blotchy sky, uneven colored galaxy glow, and exaggerated smoothing. The final additional full-image NoiseX pass at reduction 0.60 was explicitly requested and accepted for this image; it is a reference preference, not a mandatory setting for every dataset.

## 1. Establish inputs and a recoverable workspace

1. Identify the requested target, master set, nights, calibration provenance, and whether the user wants a new edit or a refinement of the latest accepted image. Use the latest accepted checkpoint when refining; applying a new operation to an older branch can undo accepted improvements.
2. Confirm each filter's dimensions, binning, orientation, alignment, usable overlap, finite pixels, and linear/nonlinear status. Same dimensions do not prove registration: blink stars and galaxy features at the center and corners. If necessary, register the channels and select a shared valid field before processing.
3. Preserve raw data, master lights, calibration masters, and earlier accepted edits. Work in a distinct dated/versioned output directory. Record original paths, checksums where practical, and a source manifest.
4. Identify the existing PixInsight instance and available process versions/models. Record existing open windows, available RAM, free `/tmp` space, and free destination space. Full-resolution float images and process undo data can consume substantial storage.
5. Separate working images from preview copies. Label previews clearly. Save native checkpoints after expensive or consequential operations, together with actual process instances and execution logs.

**Complete when:** input lineage is explicit, geometry has been checked, and recovery does not depend on an unsaved GUI window. An editing request does not require a laptop deployment, master rebuild, or equipment change.

## 2. Diagnose the background before correcting it

Inspect R, G, B, L, and Ha independently, using both a common diagnostic stretch for fair comparison and a per-image stretch to expose subtle structure. STF is a display transform; record whether any stretch has actually been committed to pixels.

Create views of the full field, the galaxy and halo at native scale, a bright gold star, a blue star, a faint-star region, and empty sky near the center, edges, and corners. Examine R/G/B channels separately. Mark stars, halos, galaxies, extended emission, dust features, and any questionable background boundaries.

Distinguish the defect before choosing a treatment:

| Appearance | Investigate | Appropriate next step |
|---|---|---|
| Broad brightness/color slope | Illumination gradient or residual flat pattern | Inspect per-filter background models and calibration evidence |
| Colored clouds after stronger stretching | Low-signal chroma noise, possibly amplified by residual gradients | Correct gradients first, then targeted chroma noise reduction |
| Dark holes around small galaxies | Object included in background samples | Exclude that object, rebuild the model from the prior checkpoint |
| Blotches appear when stars return | Diffuse residual in the extracted star layer | Inspect and clean that layer before its stretch |
| Rings/doubled stars or colored rims | Misregistration, unequal PSF, deconvolution/star-removal artifacts | Correct alignment or back off the responsible operation |
| Strange color appears after LRGB | Existing RGB error amplified by luminance, or combination settings | Compare RGB-only, RGB+L, RGB+Ha, and full composition |

A monochrome L image has no green channel to inject by itself, but luminance combination can make existing RGB variation more apparent. Identify the first checkpoint where the pattern appears. Do not assign blame from the final image alone.

For a suspected flat problem, retain the distinction between **correctly applying a flat** and **the flat representing the optical illumination of these lights**. Background extraction makes a display image more usable; it does not prove calibration was correct or restore lost photometric accuracy.

**Complete when:** there is a specific defect map and an evidence-based explanation of which layer/operation carries it.

## 3. Correct each linear filter independently

Use GraXpert background extraction and/or protected DBE on each monochrome filter before RGB/LRGB combination. Save both the corrected image and the model. Begin with the least flexible model that addresses the observed gradient. The reference dataset needed another GraXpert pass and a finer residual correction; repeated passes are a response to measured residuals, not a required ritual.

Protect the main galaxy **including faint outskirts**, other galaxies, diffuse emission, bright-star halos, and image boundaries without uniform coverage. Inspect the model with a strong stretch: recognizable galaxy/dust-lane structure in it is a reason to reject the model. A smoother-looking result is not acceptable if the model removed real light.

For DBE, review sample **footprints**, not just their center points. Use clean-sky robust sample statistics. Automatic source exclusions are a starting mask requiring visual review. Increase their extent where necessary. Dense grids and low smoothing can follow calibration defects, but can also fit astronomical structure or noise; the 70-pixel reference grid is dataset-specific.

Evaluate correction with held-out sky patches distributed over the field, excluding real objects. For each channel, retain patch medians, robust dispersion, and P95−P5 spatial span. Compare before/after under the same scaling and inspect the model and target together. Keep signed floating-point data during intermediate calculations where needed; use explicit range handling rather than silently forcing the histogram to zero.

**Complete when:** the field has no obvious residual gradient at the intended stretch, the correction does not carve halos or small galaxies, and held-out measurements support the visual improvement. If a finer correction is required after star separation, return to the separate linear filter layers before the final combination.

## 4. Normalize and calibrate color while linear

Choose a clean reference channel and inspect LinearFit results. Apply suitable rejection limits and check stellar flux ratios; blindly matching whole-image medians does not establish correct color. Matching L/Ha to a broadband reference was a convenient working scale in this edit, not evidence of physical equivalence between filters.

Combine the corrected R/G/B channels. Confirm valid astrometry, then run real catalog-based calibration: SPCC when the required catalog and instrument/filter response information are actually available and valid, otherwise working PCC. Record the process, catalog, configuration, fit results, and success evidence. The accepted reference used **PCC with APASS9**, not SPCC. A process class being installed does not demonstrate that calibration ran.

Keep a photometrically calibrated, stars-in RGB checkpoint. Later independent sky corrections should preserve stellar color scaling; matching additive background pedestals is different from rescaling channel gains. Recheck color after those corrections.

**Complete when:** the catalog fit actually succeeded, stellar colors are plausible, and no arbitrary channel normalization has hidden an unresolved gradient.

## 5. Restore detail and reduce noise on RGB, L, and Ha separately

Apply BlurXTerminator to linear images before NoiseX or a committed stretch. Use a saved pre-operation checkpoint and modest settings as a starting point. Inspect the dust lane, bright stars, faint stars, and corners at 100%; stronger sharpening is not automatically better. Reject dark ringing, false star splitting, worms, unnaturally hard dust edges, and erased compact sources.

Then apply NoiseXTerminator to each still-linear image. Tune to that layer's noise and signal. Compare at identical scale and stretch, especially faint halo and small emission knots. Preserve natural texture; retain a reduced-strength alternative if the image becomes waxy or fine features disappear.

Record the **active controls**. With color/frequency separation disabled, the common `denoise` value controls the reference process. With color separation enabled, record `denoise_intensity` and `denoise_color`. A saved instance can display inactive defaults that were not the applied reduction. Record iterations, detail, model/version, and successful execution too.

**Complete when:** all three layers are inspectably improved, without new artifacts, and their pre-restoration versions remain available for signal checks.

## 6. Separate and inspect stars; finish any residual background work

If separate star processing benefits the image, run StarX while linear and preserve both stars-in and starless checkpoints. Inspect residuals around bright stars, halos, spikes, and compact galaxy structures. Check the stars-only layer with a strong stretch: it may contain diffuse background, not only stars.

In the reference case, residual RGB gradients were visible **before** L or Ha was introduced. R/G/B were therefore extracted from the calibrated/restored starless RGB, corrected individually, and recombined. L and Ha received their own residual correction. Smaller galaxies were explicitly excluded after an earlier model produced a dark hole.

If the extracted star layer contains a diffuse pattern, model it separately while protecting real stellar profiles. Compare the original star pixels and model directly. Watch for automatic range rescaling or new pedestals after subtraction. The reference's accepted path subtracted the model explicitly with PixelMath, with rescaling disabled. Clamping the isolated star residual to nonnegative values was a compositing choice, not a rule for science masters.

**Complete when:** independently stretched RGB, L, Ha, and the stars-only image are individually acceptable. Do not proceed merely because one layer will conceal another's defect.

## 7. Evaluate Ha signal and blend conservatively

Skip this branch if Ha is absent or unsupported. For broadband-continuum subtraction, use aligned linear Ha and red data on a consistent scale. Measure unsaturated, isolated stars with local-sky subtraction before AI restoration. Fit a robust continuum coefficient, reject outliers, and examine residuals against color, brightness, and position. A single coefficient is an approximation; color-dependent stellar residuals and filter bandpass differences limit it.

Define the continuum residual as `E = Ha − k*R − skyOffset`. Retain a signed diagnostic copy. Recompute the sky offset after background changes. If relative scaling changes, recompute the coefficient as well. Inspect both positive emission and negative residuals. Similar-looking structures in a denoised/deconvolved output alone do not establish real emission.

Construct a soft support mask from the pre-restoration data, with a noise estimate appropriate to the smoothing and resolution used. The reference's 3–5 sigma ramp was an empirical display mask; it was **not a statistical detection significance claim**. Use a smooth spatial mask only where appropriate for the target. Inspect boundaries for seams and compare with Ha disabled.

Blend supported emission into red with an adjustable weight, leaving broadband star colors independent. The reference used `R' = R + (0.8/k)*max(0,E)*support`; this is a display recipe for that measured coefficient and data scale, not a universal flux-calibrated mapping. Stop increasing Ha when additional weight exposes noise, creates red sheets, or turns dust into unsupported filaments.

**Complete when:** visible enhancement corresponds to signal supported by the source Ha data, and the halo, background, and stars remain natural.

## 8. Stretch RGB and L separately; control chroma before LRGB

Set conservative black points from measured sky and inspect histogram tails. Preserve faint halo and sky texture. Use separate stretches appropriate to RGB and L rather than forcing identical histograms. Keep a well-scaled RGB-only checkpoint for comparison.

If low-signal RGB still has colored mottling after gradient removal, use a soft luminance/target mask and chrominance-only multiscale reduction before LRGB combination. Inspect the mask itself. Check the transition into the faint galaxy halo so treatment does not produce a gray moat or abrupt color boundary. Change gradient models for gradients and noise controls for noise.

The reference used chrominance-only MLT across several scales; its exact layer table is in the case study. Broader-scale treatment can suppress real diffuse color, so compare several sky and halo patches, not just the central galaxy.

**Complete when:** stretched RGB is pleasing on its own; L has clean detail; both have compatible brightness; and remaining sky color is not being hidden by the later luminance layer.

## 9. Combine, refine contrast, and return stars

Apply LRGB combination, then moderate contrast and saturation. Inspect the main halo and smaller galaxies immediately. Use a soft galaxy/luminance mask for local histogram equalization or other local contrast work. Keep the sky and faint outskirts out of aggressive enhancement.

Stretch cleaned stars independently with a color-preserving method. Inspect a range of gold, orange, blue, white, and faint stars. Saturate selectively enough to show color without neon rims or hard cores. In the accepted edit, modest SCNR preserving lightness was restricted to the star layers; global green removal is not a substitute for calibrated RGB or clean backgrounds.

Recombine according to the representation and stretch used. Linear subtraction-based star extraction should be checked by its corresponding linear reconstruction before nonlinear editing. The accepted **nonlinear aesthetic** composition used screen blending, `1−(1−starless)*(1−stars)`, with a separate mild star-core contribution. This is not a claim of exact flux reconstruction. Inspect for doubled stars, bright rings, background lift, and saturation after compositing.

If requested or visually justified, perform a restrained final NoiseX pass on a copy of the completed full-resolution image. Preserve the preceding result. Sean accepted common reduction 0.60, detail 0.20, two iterations for the final NGC 891 revision.

**Complete when:** recombination improves the image without reintroducing the original color pattern, and galaxy detail and stellar colors survive final noise treatment.

## 10. Evaluate the actual delivery, not only the GUI

Use this same inspection set after Ha blending, LRGB, star addition, saturation, and final export:

| Check | Pass condition / corrective action |
|---|---|
| Full field at intended viewing size | No conspicuous colored sky clouds, edge seams, dark bowls, or abrupt halo boundaries. If visible, isolate the first layer introducing them. |
| Galaxy and faint halo at 100% | Fine detail remains believable; faint light is retained; no sharpened noise, halos, or subtraction scars. Reduce the responsible operation if necessary. |
| Gold/blue/white and faint stars at 100% | Natural colors, no green in orange bodies, no clipped flat cores, double edges, or patterned residuals. Revisit the star layer rather than desaturating everything. |
| Center/edge/corner sky patches | No unexplained low-frequency illumination/color step; similar noise character. Exclude astronomical signal from measurements. |
| Temporary strong stretch and individual RGB channels | Exposes residual gradients, mottling, dust signatures and seams. Use to locate defects; do not erase genuine faint signal just to make this diagnostic perfectly blank. |
| Histograms and arrays | Finite data; clipping quantified and explained. Signed linear intermediates are valid; numerical zero is not an obligatory sky level. |
| Saved JPEG versus native image | Correct dimensions, orientation, colors, profile and visual detail after reopening. A preview file is not the full-quality deliverable. |

For numerical sky QA, record patch coordinates, exclusions, patch medians per channel, P95−P5 span, robust noise, and a cross-channel residual measure. Use comparable pixel units and stretches. A reduction in spatial background span is not a measurement of improved resolution or SNR. No single numeric cutoff proves a good edit.

If an artifact remains visible at normal intended scale, fix it or disclose the limitation; do not call the image finished solely because advanced tools ran. Faint texture visible only under an extreme diagnostic stretch can remain if its removal damages real signal. Record that tradeoff honestly.

## 11. Save, deliver, and clean up

Save a native float XISF, high-bit-depth TIFF, quality JPEG in sRGB, and a separately named small chat preview. Preserve editable components and masks plus process settings/scripts; a flattened XISF alone does not preserve the whole editing recipe. Use a geometry-aware Crop process when cropping delivered data, and verify astrometry afterward if it matters. Keep an uncropped alternative when appropriate.

Write a processing record naming actual methods, versions, inputs, accepted stages, rejected alternatives and remaining limitations. Verify exports and checksums. Post the preview with the actual full-resolution download link. Upload only within the user's authorization, to the intended image/revision; preserve exposure metadata for an edit of unchanged data.

Close only your saved, unneeded working windows. Delete only identified, reproducible discarded intermediates, with a manifest. Preserve accepted images, masters, raw data, masks, settings, and logs. Release only task-owned temporary processes. Leave the final image available in PixInsight.

**Done means:** inspected exports exist, the user can see the actual image and access full resolution, any authorized upload is verified on the destination, and future work has an unambiguous accepted checkpoint.
