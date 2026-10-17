// Which HFR a frame-preview response is carrying.
//
// One physical frame is measured twice by this app, by two different
// estimators over the same detected-star population, and the two numbers
// differ by 8–19% on the sim rig:
//
//   * The LIVE-PREVIEW HFR — `CapturedImageResult.stats.hfr`, built native-side
//     by `frame_stats_result` → `frame_metric_median`, which takes the MEDIAN
//     of the brightest half of the detected stars (capped at 50 samples). This
//     is what `/api/run-watch/frame-thumbnail` and `/api/camera/last-image*`
//     publish on `x-frame-hfr`, and what the Run-Watch "Last frame" card and
//     the dashboard camera panel show.
//
//   * The GRADED HFR — computed by the sequencer's grader through
//     `DeviceOps::calculate_image_hfr`, which takes the arithmetic MEAN over
//     EVERY detected star. This is the number written to `captured_images.hfr`,
//     and therefore the number the session report, the reject threshold, the
//     Analytics "Mean HFR" and the Darkroom sub-selection all read.
//
// They answer the same question with two estimators, so they are not two
// statistics an operator should be reconciling — but until they are one number
// (the estimators live in `native/skotiq_native`, not here), a surface must
// not present either as "the frame's HFR" unqualified: an operator who sets an
// HFR reject threshold from what Run-Watch shows is calibrating against the
// wrong scale. Every preview response therefore names its own measurement on
// [kFrameHfrBasisHeader], and the clients render the name beside the number.

/// Response header naming which HFR measurement `x-frame-hfr` carries.
const String kFrameHfrBasisHeader = 'x-frame-hfr-basis';

/// Value of [kFrameHfrBasisHeader] on every live-preview response: the median
/// of the brightest half of the stars detected in the buffered frame.
const String kFrameHfrBasisLivePreview = 'live-preview-median-brightest-half';
