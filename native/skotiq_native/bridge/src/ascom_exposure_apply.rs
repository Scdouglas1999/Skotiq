//! Platform-independent ASCOM per-frame exposure-parameter application.
//!
//! The ASCOM camera worker gets `ExposureParams` carrying
//! gain/offset/binning/subframe, and every one of those fields has to reach the
//! camera before the exposure starts: a frame shot at the camera's current
//! settings is a silent mis-acquisition on any per-filter-gain or binned night,
//! doubly silent because the FITS header records the camera's actual (unchanged)
//! value.
//!
//! The concrete `AscomCamera` COM type exists only on Windows
//! (`#[cfg(windows)] mod ascom_wrapper`), so the apply logic lives here as a
//! generic function over the small [`ExposureApplyTarget`] trait — implemented by
//! the real `AscomCamera` and by a cross-platform test spy — and is therefore
//! compiled and regression-tested on every platform.
//!
//! Order matters on ASCOM: binning must be set *before* frame geometry because
//! `NumX`/`NumY` are expressed in *binned* pixels. Gain/offset are applied only
//! when the node specified them (`None` = leave the camera's current value
//! unchanged, mirroring Alpaca/INDI/native). Binning and geometry setter errors
//! are propagated as hard failures. Gain/offset are best-effort because those
//! ASCOM properties are optional; failures are loudly logged before exposure
//! continues at the camera's current values.

use skotiq_native::camera::SubFrame;

/// The minimal camera setter/getter surface the ASCOM exposure-apply step
/// needs. The real `AscomCamera` (Windows COM) implements this, as does the
/// cross-platform test spy. Every method mirrors the ASCOM ICameraV3 property
/// it wraps and returns `Result<_, String>`.
//
// The only non-test caller — the ASCOM COM worker — is `#[cfg(windows)]`-gated,
// so on non-Windows builds this trait and `apply_exposure_params` are reached
// only by the (cfg(test)) regression suite. Allow dead_code off-Windows so the
// `-D warnings` CI gate passes while still keeping the logic compiled+tested
// everywhere.
#[cfg_attr(not(windows), allow(dead_code))]
pub trait ExposureApplyTarget {
    fn max_bin_x(&self) -> Result<i32, String>;
    fn max_bin_y(&self) -> Result<i32, String>;
    fn camera_x_size(&self) -> Result<i32, String>;
    fn camera_y_size(&self) -> Result<i32, String>;
    fn set_bin_x(&mut self, value: i32) -> Result<(), String>;
    fn set_bin_y(&mut self, value: i32) -> Result<(), String>;
    fn set_start_x(&mut self, value: i32) -> Result<(), String>;
    fn set_start_y(&mut self, value: i32) -> Result<(), String>;
    fn set_num_x(&mut self, value: i32) -> Result<(), String>;
    fn set_num_y(&mut self, value: i32) -> Result<(), String>;
    fn set_gain(&mut self, value: i32) -> Result<(), String>;
    fn set_offset(&mut self, value: i32) -> Result<(), String>;
}

/// Apply per-frame acquisition parameters to an ASCOM camera *before*
/// `start_exposure`. Fails closed on binning or geometry errors; gain/offset
/// errors are logged and ignored because those ASCOM properties are optional.
///
/// Steps, in order:
/// 1. **Binning** — validated against the driver max, then `set_bin_x`/
///    `set_bin_y`. Must precede geometry because `NumX`/`NumY` are in binned
///    pixels.
/// 2. **Frame geometry** — a subframe (validated against the *binned* sensor
///    bounds) or a full frame reset to `sensor_size / bin`.
/// 3. **Gain / offset** — attempted only when `Some`; `None` leaves the
///    camera's current value untouched. A failed attempt logs the requested
///    value and continues at the camera's current value.
#[allow(clippy::too_many_arguments)]
#[cfg_attr(not(windows), allow(dead_code))]
pub fn apply_exposure_params<C: ExposureApplyTarget>(
    cam: &mut C,
    bin_x: i32,
    bin_y: i32,
    gain: Option<i32>,
    offset: Option<i32>,
    subframe: &Option<SubFrame>,
) -> Result<(), String> {
    // 1. Binning (validate against the driver max).
    let max_bin_x = cam.max_bin_x().unwrap_or(1);
    let max_bin_y = cam.max_bin_y().unwrap_or(1);
    if bin_x < 1 || bin_y < 1 {
        return Err(format!("Binning {}x{} must be >= 1", bin_x, bin_y));
    }
    if bin_x > max_bin_x || bin_y > max_bin_y {
        return Err(format!(
            "Binning {}x{} exceeds max {}x{}",
            bin_x, bin_y, max_bin_x, max_bin_y
        ));
    }
    cam.set_bin_x(bin_x)
        .and_then(|_| cam.set_bin_y(bin_y))
        .map_err(|e| format!("Failed to set binning: {}", e))?;

    // 2. Frame geometry, in binned pixels. A subframe is validated against the
    //    binned sensor size; None means full frame = sensor_size / bin.
    let bx = bin_x.max(1);
    let by = bin_y.max(1);
    let max_x = cam.camera_x_size().unwrap_or(1) / bx;
    let max_y = cam.camera_y_size().unwrap_or(1) / by;
    match subframe {
        Some(sf) => {
            if sf.start_x as i32 + sf.width as i32 > max_x
                || sf.start_y as i32 + sf.height as i32 > max_y
            {
                return Err("Subframe exceeds (binned) sensor bounds".to_string());
            }
            cam.set_start_x(sf.start_x as i32)
                .and_then(|_| cam.set_start_y(sf.start_y as i32))
                .and_then(|_| cam.set_num_x(sf.width as i32))
                .and_then(|_| cam.set_num_y(sf.height as i32))
                .map_err(|e| format!("Failed to set subframe: {}", e))?;
        }
        None => {
            cam.set_start_x(0)
                .and_then(|_| cam.set_start_y(0))
                .and_then(|_| cam.set_num_x(max_x))
                .and_then(|_| cam.set_num_y(max_y))
                .map_err(|e| format!("Failed to reset to full frame: {}", e))?;
        }
    }

    // 3. Gain / offset, only when the node specified them (None = leave the
    //    camera's current value unchanged). ICameraV3 makes these properties
    //    optional, so a driver may reject their setters even though it can
    //    still expose normally.
    if let Some(gain) = gain {
        if let Err(error) = cam.set_gain(gain) {
            tracing::warn!(
                requested_gain = gain,
                error = %error,
                "ASCOM camera could not apply the requested gain; exposure will continue at the camera's current gain"
            );
        }
    }
    if let Some(offset) = offset {
        if let Err(error) = cam.set_offset(offset) {
            tracing::warn!(
                requested_offset = offset,
                error = %error,
                "ASCOM camera could not apply the requested offset; exposure will continue at the camera's current offset"
            );
        }
    }
    Ok(())
}

// Tests — regression guard. These run on every platform (the module is
// NOT `#[cfg(windows)]`-gated, unlike the COM worker) so a future refactor that
// drops the gain/offset/binning apply, reorders binning vs. geometry, or
// mishandles a setter error is caught in the Linux/CI dev loop.
#[cfg(test)]
mod tests {
    use super::*;
    use skotiq_native::camera::SubFrame;

    /// Records every setter/getter call (in order) and lets a test force any
    /// setter to fail, so we can assert (a) the correct calls happened, (b) in
    /// the correct order, and (c) which setter failures abort before
    /// `start_exposure`.
    #[derive(Default)]
    struct SpyCamera {
        calls: Vec<String>,
        set_bin_x: Option<i32>,
        set_bin_y: Option<i32>,
        set_gain: Option<i32>,
        set_offset: Option<i32>,
        set_num_x: Option<i32>,
        set_num_y: Option<i32>,
        /// Name of a setter that should return Err when invoked.
        fail_on: Option<&'static str>,
        max_bin: i32,
        sensor_x: i32,
        sensor_y: i32,
    }

    impl SpyCamera {
        fn new() -> Self {
            SpyCamera {
                max_bin: 4,
                sensor_x: 1000,
                sensor_y: 800,
                ..Default::default()
            }
        }

        fn maybe_fail(&self, name: &'static str) -> Result<(), String> {
            if self.fail_on == Some(name) {
                Err(format!("{} forced failure", name))
            } else {
                Ok(())
            }
        }
    }

    impl ExposureApplyTarget for SpyCamera {
        fn max_bin_x(&self) -> Result<i32, String> {
            Ok(self.max_bin)
        }
        fn max_bin_y(&self) -> Result<i32, String> {
            Ok(self.max_bin)
        }
        fn camera_x_size(&self) -> Result<i32, String> {
            Ok(self.sensor_x)
        }
        fn camera_y_size(&self) -> Result<i32, String> {
            Ok(self.sensor_y)
        }
        fn set_bin_x(&mut self, value: i32) -> Result<(), String> {
            self.calls.push("set_bin_x".to_string());
            self.maybe_fail("set_bin_x")?;
            self.set_bin_x = Some(value);
            Ok(())
        }
        fn set_bin_y(&mut self, value: i32) -> Result<(), String> {
            self.calls.push("set_bin_y".to_string());
            self.maybe_fail("set_bin_y")?;
            self.set_bin_y = Some(value);
            Ok(())
        }
        fn set_start_x(&mut self, _value: i32) -> Result<(), String> {
            self.calls.push("set_start_x".to_string());
            self.maybe_fail("set_start_x")
        }
        fn set_start_y(&mut self, _value: i32) -> Result<(), String> {
            self.calls.push("set_start_y".to_string());
            self.maybe_fail("set_start_y")
        }
        fn set_num_x(&mut self, value: i32) -> Result<(), String> {
            self.calls.push("set_num_x".to_string());
            self.maybe_fail("set_num_x")?;
            self.set_num_x = Some(value);
            Ok(())
        }
        fn set_num_y(&mut self, value: i32) -> Result<(), String> {
            self.calls.push("set_num_y".to_string());
            self.maybe_fail("set_num_y")?;
            self.set_num_y = Some(value);
            Ok(())
        }
        fn set_gain(&mut self, value: i32) -> Result<(), String> {
            self.calls.push("set_gain".to_string());
            self.maybe_fail("set_gain")?;
            self.set_gain = Some(value);
            Ok(())
        }
        fn set_offset(&mut self, value: i32) -> Result<(), String> {
            self.calls.push("set_offset".to_string());
            self.maybe_fail("set_offset")?;
            self.set_offset = Some(value);
            Ok(())
        }
    }

    fn index_of(calls: &[String], name: &str) -> Option<usize> {
        calls.iter().position(|c| c == name)
    }

    /// (1)+(2): gain/offset/binning are actually applied, and binning is
    /// set BEFORE the frame geometry (NumX/NumY are in binned pixels).
    #[test]
    fn applies_gain_offset_binning_before_geometry() {
        let mut cam = SpyCamera::new();
        apply_exposure_params(&mut cam, 2, 2, Some(100), Some(50), &None)
            .expect("apply should succeed");

        assert_eq!(cam.set_bin_x, Some(2), "bin_x must be applied");
        assert_eq!(cam.set_bin_y, Some(2), "bin_y must be applied");
        assert_eq!(cam.set_gain, Some(100), "gain must be applied");
        assert_eq!(cam.set_offset, Some(50), "offset must be applied");

        // Full-frame geometry must be in BINNED pixels: sensor / bin.
        assert_eq!(cam.set_num_x, Some(500), "NumX must be sensor_x / bin_x");
        assert_eq!(cam.set_num_y, Some(400), "NumY must be sensor_y / bin_y");

        // Order: binning before geometry before gain/offset.
        let bin_x_idx = index_of(&cam.calls, "set_bin_x").unwrap();
        let bin_y_idx = index_of(&cam.calls, "set_bin_y").unwrap();
        let num_x_idx = index_of(&cam.calls, "set_num_x").unwrap();
        let gain_idx = index_of(&cam.calls, "set_gain").unwrap();
        assert!(
            bin_x_idx < num_x_idx && bin_y_idx < num_x_idx,
            "binning must be set before frame geometry (got {:?})",
            cam.calls
        );
        assert!(
            num_x_idx < gain_idx,
            "geometry must be set before gain (got {:?})",
            cam.calls
        );
    }

    /// (3): None gain/offset must leave the camera's current value
    /// unchanged — set_gain / set_offset are NOT called.
    #[test]
    fn none_gain_offset_leaves_camera_unchanged() {
        let mut cam = SpyCamera::new();
        apply_exposure_params(&mut cam, 1, 1, None, None, &None).expect("apply should succeed");

        assert!(
            index_of(&cam.calls, "set_gain").is_none(),
            "set_gain must NOT be called when gain is None (got {:?})",
            cam.calls
        );
        assert!(
            index_of(&cam.calls, "set_offset").is_none(),
            "set_offset must NOT be called when offset is None (got {:?})",
            cam.calls
        );
        assert_eq!(cam.set_gain, None);
        assert_eq!(cam.set_offset, None);
    }

    /// (4): bin 1x1 still drives the binning setters (not skipped as a
    /// "no-op") — a prior frame may have left the camera at 2x2.
    #[test]
    fn bin_one_still_calls_binning_setters() {
        let mut cam = SpyCamera::new();
        apply_exposure_params(&mut cam, 1, 1, None, None, &None).expect("apply should succeed");

        assert_eq!(cam.set_bin_x, Some(1), "set_bin_x(1) must be called");
        assert_eq!(cam.set_bin_y, Some(1), "set_bin_y(1) must be called");
        // Full sensor at 1x1 binning.
        assert_eq!(cam.set_num_x, Some(1000));
        assert_eq!(cam.set_num_y, Some(800));
    }

    /// (5): gain is optional in ASCOM, so a rejected gain must not prevent an
    /// exposure. Offset is still attempted after the gain failure.
    #[test]
    fn gain_setter_failure_is_best_effort() {
        let mut cam = SpyCamera::new();
        cam.fail_on = Some("set_gain");
        let result = apply_exposure_params(&mut cam, 2, 2, Some(100), Some(50), &None);

        assert!(
            result.is_ok(),
            "a set_gain failure must not prevent exposure: {:?}",
            result
        );
        assert_eq!(cam.set_gain, None, "failed gain must not be recorded");
        assert_eq!(
            cam.set_offset,
            Some(50),
            "offset must still be attempted after gain fails"
        );
    }

    /// Offset is also optional in ASCOM, so a rejected offset must not prevent
    /// an exposure after the requested gain was successfully applied.
    #[test]
    fn offset_setter_failure_is_best_effort() {
        let mut cam = SpyCamera::new();
        cam.fail_on = Some("set_offset");
        let result = apply_exposure_params(&mut cam, 2, 2, Some(100), Some(50), &None);

        assert!(
            result.is_ok(),
            "a set_offset failure must not prevent exposure: {:?}",
            result
        );
        assert_eq!(cam.set_gain, Some(100), "gain must still be applied");
        assert_eq!(cam.set_offset, None, "failed offset must not be recorded");
    }

    /// fail-closed on binning: a binning setter failure aborts before any
    /// geometry/gain/offset is touched.
    #[test]
    fn binning_setter_failure_aborts_before_geometry() {
        let mut cam = SpyCamera::new();
        cam.fail_on = Some("set_bin_x");
        let result = apply_exposure_params(&mut cam, 2, 2, Some(100), Some(50), &None);

        assert!(result.is_err(), "a set_bin_x failure must abort the apply");
        assert!(
            index_of(&cam.calls, "set_num_x").is_none(),
            "geometry must not run after binning fails (got {:?})",
            cam.calls
        );
        assert_eq!(cam.set_gain, None, "gain must not run after binning fails");
    }

    /// Out-of-range binning is rejected before any setter runs.
    #[test]
    fn binning_over_max_is_rejected() {
        let mut cam = SpyCamera::new();
        let result = apply_exposure_params(&mut cam, 8, 8, None, None, &None);
        assert!(
            result.is_err(),
            "8x8 binning over a 4x4 max must be rejected"
        );
        assert!(
            cam.calls.is_empty(),
            "no setter should run when binning is out of range (got {:?})",
            cam.calls
        );
    }

    /// A subframe is validated against the BINNED sensor bounds and applied via
    /// the start/num setters.
    #[test]
    fn subframe_applied_in_binned_pixels() {
        let mut cam = SpyCamera::new();
        // sensor 1000x800, bin 2 -> binned 500x400. Subframe 100,100 size
        // 200x150 fits.
        let sf = SubFrame {
            start_x: 100,
            start_y: 100,
            width: 200,
            height: 150,
        };
        apply_exposure_params(&mut cam, 2, 2, None, None, &Some(sf))
            .expect("subframe within binned bounds should apply");

        assert_eq!(cam.set_num_x, Some(200));
        assert_eq!(cam.set_num_y, Some(150));
    }

    /// A subframe exceeding the binned sensor bounds is rejected.
    #[test]
    fn subframe_out_of_binned_bounds_is_rejected() {
        let mut cam = SpyCamera::new();
        // bin 2 -> binned 500x400. start 400 + width 200 = 600 > 500.
        let sf = SubFrame {
            start_x: 400,
            start_y: 0,
            width: 200,
            height: 100,
        };
        let result = apply_exposure_params(&mut cam, 2, 2, None, None, &Some(sf));
        assert!(
            result.is_err(),
            "subframe past binned bounds must be rejected"
        );
    }
}
