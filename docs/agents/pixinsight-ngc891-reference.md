# NGC 891: accepted PixInsight reference, October 28, 2026

Read [the workflow](pixinsight-editing.md) for decisions and acceptance checks. This file records **what actually worked on this dataset**, including the final extra NoiseX pass accepted by the user. Treat pixel coordinates, coefficients, thresholds, grid sizes, and stretches as historical values. Refit them when geometry or data changes.

## Authoritative result and source locations

Let `D = /home/scdouglas/Desktop/NGC891-2026-10-28` and `F = D/Edit-Individual-Final`.

| Purpose | Location |
|---|---|
| Original master manifest | `D/Edit/input-masters.json` |
| Master lights | `D/Masters/masters-1793187373549195/` |
| Initial individually corrected branch | `D/Edit-IndividualFilters/` |
| Accepted component processing | `F/` |
| Finished image before extra NoiseX | `F/Finished/NGC891_HaLRGB_Final.xisf` |
| **Latest accepted native image** | **`F/Revision-NoiseX06/NGC891_Final_NoiseX06.xisf`** |
| **Latest accepted full-resolution upload** | **`F/Revision-NoiseX06/NGC891_Final_NoiseX06.jpg`** |
| Final extra-pass provenance | `F/Revision-NoiseX06/{NoiseX-settings.js,processing.log,complete.json,verification.json,astrobin-receipt.json}` |
| Durable small-script/evidence archive | `/home/scdouglas/Documents/PixInsight-Agent-Guide/reference-2026-10-28/` |

Published result: [AstroBin revision B](https://app.astrobin.com/i/6vgjri?r=B), marked final. It is 3800 × 2800 (10.64 MP), with the existing acquisition records retained. The original image and pre-extra-pass export are older comparison points, not the latest accepted result.

Data represented: 824 accepted light frames, 98,370 seconds = 27 h 19 m 30 s. L: 179×90 s; R: 185×120 s; G: 189×120 s; B: 190×120 s; Ha: 81×180 s. Broadband data spans October 20–26; Ha adds October 27. These counts come from delivery/acquisition evidence, not from guessing filenames or the number of input candidates.

## What the diagnosis established

The green/blue pattern existed in RGB before L or Ha was added. L also had spatial background variation, and the separated stars retained diffuse background. Reintroducing the stretched star layer could therefore put blotching back into an otherwise improved image. Ha was added only into red with a support mask in this recipe; it did not explain the field-wide green pattern.

The accepted remedy corrected separate filter layers and the star layer before final composition, with masked RGB chroma treatment before LRGB. It did not rely on subtracting another surface from the finished composite. Background correction compensates display defects; it does not establish that the flats matched the optical illumination or that faint flux is scientifically recoverable.

## Executed sequence and settings

### A. Initial individual-filter background extraction

Source: `D/Edit-IndividualFilters/01-individual-backgrounds.js`.

- Input geometry: 4514 × 3346. FITS open hints included `lower-range 0 upper-range 2 rescale-out-of-range`; preserve this in historical provenance, but inspect numerical ranges before copying these hints to other masters.
- GraXpert AI background model `1.0.1`; smoothing `0`; correction `Subtraction`; background extraction enabled; denoising/deconvolution disabled; create background model; replace working target; GPU enabled; batch size `4`.
- Actual integration fields: `backgroundExtractionSampleFree=false`, `backgroundExtraction=true`, app path `/home/scdouglas/.local/bin/graxpert`. Field names are version-specific: inspect the stored process instance and installed UI rather than inferring behavior from a field name alone.
- DBE following GraXpert: grid spacing 160 pixels; 80×80 median sample boxes; smoothing `0.5`; downsample `2`; normalized subtraction; model saved.
- Excluded main galaxy ellipse: center `(2271,1642)`, radii `(500,1100)`. Additional bright-star/edge-halo exclusions are in the original script.
- Saved `02_{R,G,B,L,Ha}_DBE.xisf`.

`F/01-final-filter-backgrounds.js` applied another GraXpert pass independently to these five linear files with the same AI extraction settings. This was prompted by the comparison result, not an instruction to always run two GraXpert passes. Saved `01_*_final_background.xisf/.fits` and models.

### B. Matching, PCC, restoration, separation

Source: `F/02-linear-processing.js` and individual exported process instances.

| Operation | Actual setting |
|---|---|
| LinearFit | R/B/L/Ha to G, reject low `0`, high `0.92` |
| RGB | ChannelCombination, correct R/G/B channel order |
| Color calibration | PhotometricColorCalibration, APASS catalog, fixed limiting magnitude `16`, PSF minimum SNR `20` |
| Catalog service | Local adapter at `127.0.0.1:18792` serving a real cached APASS9 catalog; preserve source/catalog provenance |
| BlurX stars | `sharpen_stars=0.20` for RGB, L and Ha |
| BlurX nonstellar | RGB `0.35`, L `0.45`, Ha `0.35` |
| Linear NoiseX | Common reduction RGB `0.60`, L `0.50`, Ha `0.50`; detail `0.20`; iterations `2`; color/frequency separation disabled |
| StarX | Stars output enabled; unscreen false; remove stars/spikes/aureoles true; reflections false; overlap `0.20` |

Execution logs identify BlurXTerminator 2.6.10 / ML 4, NoiseXTerminator 2.6.10 / ML 3.1, and StarXTerminator 2.6.10 / ML 11.

PCC genuinely ran; **SPCC did not**. The catalog server was stopped after processing and must not be assumed to still exist. Retained `02_RGB_PCC`, `02_Ha_matched`, `03_*_restored_linear`, `04_*_starless` and `04_*_stars` checkpoints.

### C. Measured Ha continuum and support

`analyze-continuum.py` measured stars in `02_RGB_PCC.fits` red and `02_Ha_matched.fits`, before BlurX/NoiseX/StarX. It used catalog coordinates with WCS, V magnitude 11.5–15.5, aperture radius 10 pixels, local annulus radii 15–25, galaxy exclusion, flux and saturation filtering. Of 341 selected measurements, 327 survived 2.5-MAD clipping of the Ha/red ratio.

- Continuum coefficient `k = 0.13981721172348108`.
- Scaled ratio MAD `0.007057741050220221`.
- Original sky offset `0.036080466608047396`.
- Support residual: original matched Ha minus `k*PCC_red` minus that sky offset.
- Gaussian support smoothing sigma `1.5`; empirical noise scale `2.9857588742743246e-5`.
- Support ramp: `clamp((residual − 3*sigma)/(2*sigma),0,1)` multiplied by `exp(-((((x−2271)/280)^2+((y−1642)/900)^2)^3))`.
- Saved support: `05_Ha_support.xisf`.

`03-compose.js` contains the accepted support-generation block, but its early composition/stretch products were superseded. Reuse that block or the existing support only with matching inputs/geometry. A sigma ramp is a practical display selection, not a proof that each retained pixel is a 3–5σ astronomical detection. The coefficient is also not a physical line-flux conversion.

### D. Protected residual correction before final combination

Source: `07b-protected-cleanup.js`.

R/G/B were extracted from `04_RGB_starless`; L and Ha came from their `04_*_starless` files. Each mono image received DBE separately:

- 70-pixel sampling grid; 40×40 sample medians; smoothing `0`; downsample `1`; normalized subtraction; ignore weights true; models retained.
- Main galaxy ellipse center `(2271,1642)`, radii `(230,950)`.
- 36 additional source-exclusion boxes from `background-object-exclusions.json`.
- Source detector: L starless blurred at sigma 4 minus sigma 45; threshold `0.000055`, component area at least 55 pixels, box expansion 45 pixels. These thresholds are tied to this image scale.
- Output: **`16_{R,G,B,L,Ha}_clean_linear.xisf/.fits`**, plus background models.

The historical script excluded sample centers and was visually reviewed. A new implementation should check entire sample footprints against expanded exclusions. Inspect small galaxies even after automatic masking; the failed earlier model had a dark depression around one of them.

381 held-out sky patches showed P95−P5 background-span reduction of R 83.4%, G 83.1%, B 84.1%, L 84.4%, Ha 61.9% relative to the restored linear inputs. This reports spatial-background improvement, not SNR gain or recovered resolution. Evidence: `precombine-final-verification.json`.

### E. RGB pedestal, Ha blend, and separate stretches

Accepted early blocks of `10-final-recombine.js` produce `21_*` and `22_*`. Its later products used an obsolete star layer and are not the final result.

| Quantity | Accepted value |
|---|---:|
| R background | 0.001072075916454196 |
| G background | 0.0010723232990130782 |
| B background | 0.0010745821055024862 |
| L background | 0.0362042561173439 |
| Ha background | 0.036228545010089874 |
| Common RGB background | 0.0010729937736565869 |
| Updated starless continuum sky offset | 0.03607865034469535 |
| RGB black point / midtone | 0.0008329937736565869 / 0.0033 |
| L black point / midtone | 0.036074256117343904 / 0.0018 |

Compute emission from corrected Ha and red **before additive RGB pedestal matching**: `E=Ha−k*R−offset`. Match RGB sky levels with additive channel offsets to the common level. Save RGB without Ha. Add `(0.8/k)*max(0,E)*support` to red only; leave G and B unchanged. Save signed emission and blended RGB. Use the separate HistogramTransformation black points/midtones above for RGB and L.

Accepted outputs: `21_Ha_emission_linear`, `21_RGB_without_Ha_linear`, `21_HaRGB_linear`, `22_RGB_before_combine`, `22_L_before_combine`. The JSON settings file `precombine-final-fit.json` is the exact numerical source.

### F. Clean and stretch the original star layer

`09-clean-stars.js` generated a useful `20_stars_background_model.xisf`, but its directly corrected target acquired unwanted range/pedestal changes. Its `20_final_stars` was rejected. Keep the model, not that result.

Model settings: original `04_RGB_stars`; 80-pixel grid, 46×46 sample boxes; source exclusions; three channels; DBE smoothing `0`; downsample `2`; normalization false. A new dataset requires fresh sample review.

Accepted `11-manual-star-model.js` processing:

1. Reload **original** `04_RGB_stars` and the saved model.
2. PixelMath `max(0,$T-max(0,Final_StarModel))`, `rescale=false`, `truncate=false`.
3. Save `24_stars_clean_linear`.
4. Arcsinh stretch `160`, black point `0`, protect highlights true, RGB working space true.
5. SCNR amount `0.35`, preserve lightness true, on stars only.
6. Star saturation points: `(0,0),(.2,.28),(.5,.64),(.8,.88),(1,1)`.
7. From the cleaned linear stars, create a separate core contribution with HistogramTransformation midtone `.035`, then the same SCNR.
8. Screen-combine stretched stars and core contribution. Save **`24_final_stars`**.

The tail of `11-manual-star-model.js` made a comparison composite; `24_complete` is not the accepted final. Its reusable product is the `24_final_stars` layer.

### G. Chroma treatment, LRGB, and finishing

Source: `12-precombine-color-noise.js`; accepted output **`26_complete.xisf`** before delivery crop.

RGB mask derived from separately stretched L: `1−clamp((L−.075)/.08,0,1)`. This exposes low-signal sky/halo and protects stronger galaxy light. Inspect the mask before use.

MLT on stretched RGB: luminance false, chrominance true, linear false, deringing true, dark `.02`, bright `0`. Layer table (scale index 0–6; all enabled, detail bias zero, noise reduction enabled, iterations two):

| Scale index | Threshold | Amount |
|---|---:|---:|
| 0 | 3 | .40 |
| 1 | 3 | .40 |
| 2 | 3 | .50 |
| 3 | 3 | .60 |
| 4 | 3 | .70 |
| 5 | 2.5 | .65 |
| 6 | 2 | .40 |

Residual layer noise reduction disabled. Save `25_RGB_ready_to_combine` and the mask.

- LRGB: L weight 1, `mL=.5`, `mc=.42`, noise reduction true, layers removed 4/protected 2.
- Contrast K curve: `(0,0),(.07,.045),(.15,.16),(.3,.42),(.6,.74),(.85,.91),(1,1)`.
- Saturation curve: `(0,0),(.2,.25),(.5,.59),(.8,.86),(1,1)`.
- Local contrast mask: soft galaxy ellipse center `(2271,1642)`, radii `(340,980)`, multiplied by average-RGB intensity ramp from `.10` to `.35`.
- LHE: radius `48`, 12-bit histogram, slope `1.5`, amount `.20`, circular kernel true.
- NoiseX on this starless composite: color separation true; intensity `.18`, color `.45`, detail `.20`, iterations `2`, frequency separation false.
- Save `26_finished_starless`.
- Screen-combine with **`24_final_stars`**: `1−(1−starless)*(1−stars)`. Save `26_complete`.

No additional background surface was subtracted from this accepted final composite. Temporary 5× diagnostic images exposed faint residual texture; preserving real halo/detail took precedence over making extreme diagnostics perfectly flat.

### H. Export and final requested extra NoiseX

`13-export.js` used PixInsight Crop rather than resampling:

- Full field: 4514×3346, 15.10 MP, saved as an alternative.
- Main crop rectangle `[371,242,4171,3042]`: **3800×2800**, 10.64 MP.
- Detail rectangle `[1721,842,2821,2442]`: 1100×1600.
- Exports: native float XISF, verification FITS, 16-bit TIFF, quality-100 JPEG, embedded sRGB profile (3024 bytes), separately scaled chat previews.

The user's last accepted refinement ran `15-noisex06.js` on **`Finished/NGC891_HaLRGB_Final.xisf`** at full 3800×2800 resolution, with no mask, crop or resampling:

- Common NoiseX `denoise=.60`.
- Detail `.20`, iterations `2`.
- Color and frequency separation disabled.
- Saved new native/FITS/TIFF/JPEG outputs under **`Revision-NoiseX06/`**, preserving the previous result.

Final JPEG SHA-256: `d0e8c591f1f50e9342738901d50add49326ef67c14d31e7b344f3a37b206b69d`.

The uploaded revision B showed 3800×2800, 4.72 MB, and retained all exposure records. JPEG file size shrinking after noise reduction does not imply lost pixel resolution.

## Validation evidence and rejected paths

The pre-extra-pass finished export had finite FITS pixels, no zero/negative final channel samples, and ~0.00069% saturated channel samples. Its 16-bit TIFF differed from native float by at most `7.66e-6`, consistent with quantization. The final extra-pass export was separately checked for finite data, 3800×2800 dimensions, embedded profile, and appearance at full field and native-resolution galaxy detail. Do not attribute every pre-extra-pass statistic to the final extra-pass file.

| Rejected/limited approach | Preserve this lesson |
|---|---|
| Correct only the combined RGB/LRGB | Separate filters carried different residuals; isolate and correct them before recombination |
| Assume L or Ha caused green/blue blotches | RGB-only inspection already showed the defect; compare actual contributions |
| Dense DBE without smaller-galaxy exclusions | Produced a dark hole; model cleanliness and source protection outrank a smooth sky statistic |
| Use the direct DBE-corrected stars from stage 09 | Range/pedestal behavior polluted the star layer; subtract the saved model from original stars explicitly |
| Hide low-frequency gradients with NoiseX | Correct illumination first; target chroma noise separately |
| Globally remove green or flatten all sky color | Damages natural stars/halo; localize the responsible component |
| Rerun numbered scripts 01–15 blindly | Several contain superseded stages or require obsolete files; use accepted checkpoints and selected blocks |
| Deliver a scaled preview as the full image | Verify dimensions independently; main upload is 10.64 MP |
| Claim scientific Ha detections or perfect background | This is an aesthetic, evidence-constrained edit with residual texture under extreme stretch |

The earlier generation of this edit reclaimed about 5.08 GiB by deleting 46 identified discarded image intermediates. `cleanup-manifest.json` documents them. Their missing output files are expected; they do not imply that the accepted final or original masters are missing.
