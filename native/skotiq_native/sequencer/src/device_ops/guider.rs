//! What a run asks of the guider.

use super::DeviceResult;
use async_trait::async_trait;

/// Guiding status
#[derive(Debug, Clone)]
pub struct GuidingStatus {
    pub is_guiding: bool,
    pub rms_ra: f64,
    pub rms_dec: f64,
    pub rms_total: f64,
}

/// How bright a guide star measures: PHD2's signal-to-noise ratio and its
/// star mass (summed signal above background).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GuideStarQuality {
    pub snr: f64,
    pub star_mass: f64,
}

/// The least a newly selected guide star must measure to be guided on.
///
/// A star far fainter than the one the run was guiding on is not the star
/// returning: under cloud or behind trees PHD2 picks noise and hot pixels
/// (HFD near 2 px, a few percent of the guide star's mass), then drags the
/// mount after them.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct GuideStarFloor {
    pub min_snr: f64,
    /// `0.0` when there is no guide star to compare with.
    pub min_star_mass: f64,
}

impl GuideStarFloor {
    /// The least SNR a star found during a guide-star recovery may have,
    /// whatever the run guided on before.
    pub const RECOVERY_MIN_SNR: f64 = 15.0;
    /// A new star may measure no less than this fraction of the run's guide
    /// star's SNR.
    pub const MIN_SNR_FRACTION: f64 = 0.3;
    /// ... and no less than this fraction of its mass.
    pub const MIN_MASS_FRACTION: f64 = 0.1;

    /// The floor relative to the run's established guide star, with no
    /// absolute minimum. `None` without a guide star to compare with.
    pub fn relative_to(reference: Option<GuideStarQuality>) -> Option<Self> {
        let reference = reference.filter(|r| r.snr > 0.0 && r.star_mass > 0.0)?;
        Some(Self {
            min_snr: reference.snr * Self::MIN_SNR_FRACTION,
            min_star_mass: reference.star_mass * Self::MIN_MASS_FRACTION,
        })
    }

    /// The floor for a star on a field the run's guide star was not on, such
    /// as the guide camera's view after a meridian flip: the SNR floor still
    /// keeps noise out, but brightness depends on which stars the field holds,
    /// so there is no mass floor.
    pub fn for_new_field(reference: Option<GuideStarQuality>) -> Self {
        Self {
            min_snr: Self::relative_to(reference)
                .map_or(0.0, |floor| floor.min_snr)
                .max(Self::RECOVERY_MIN_SNR),
            min_star_mass: 0.0,
        }
    }

    /// The floor for a guide-star recovery: relative to the run's guide star
    /// when there is one, and never below [`Self::RECOVERY_MIN_SNR`].
    pub fn for_recovery(reference: Option<GuideStarQuality>) -> Self {
        let relative = Self::relative_to(reference);
        Self {
            min_snr: relative
                .map_or(0.0, |floor| floor.min_snr)
                .max(Self::RECOVERY_MIN_SNR),
            min_star_mass: relative.map_or(0.0, |floor| floor.min_star_mass),
        }
    }

    pub fn accepts(&self, star: &GuideStarQuality) -> bool {
        star.snr >= self.min_snr && star.star_mass >= self.min_star_mass
    }
}

impl GuidingStatus {
    /// The RMS for a log line. A total of exactly zero is an empty statistics
    /// window (guiding just started), not perfect guiding, so it says so.
    pub fn rms_summary(&self) -> String {
        if self.rms_total > 0.0 {
            format!("RMS total {:.2} px", self.rms_total)
        } else {
            "no guide samples yet".to_string()
        }
    }
}

/// Guiding calibration snapshot, surfaced for post-start quality checks.
///
/// Both axis angles are in degrees and may be `None` if the underlying
/// driver does not expose them (the older Alpaca-only path, for example).
/// When present, the absolute difference between them should sit close to
/// 90° on a well-calibrated mount; the executor uses this to catch silent
/// "looks calibrated but axes are wrong" failures (P3-7).
#[derive(Debug, Clone)]
pub struct GuidingCalibration {
    pub is_calibrated: bool,
    pub ra_angle_deg: Option<f64>,
    pub dec_angle_deg: Option<f64>,
}

#[async_trait]
pub trait GuiderOps: Send + Sync {
    /// Start dithering
    async fn guider_dither(
        &self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    ) -> DeviceResult<()>;

    /// Get guiding status
    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus>;

    /// Whether the guider may move the mount now: guiding, and also
    /// calibrating, settling, or searching for a star it lost. A move the run
    /// makes stops such a guider first. `is_guiding` alone answers false for
    /// a PHD2 in LostLock or settling after a dither, and a guider left in one
    /// of those states kept sending corrections through a Center.
    async fn guider_is_active(&self) -> DeviceResult<bool> {
        Ok(self.guider_get_status().await?.is_guiding)
    }

    /// Get calibration data for the active guider. Returns Err if the driver
    /// cannot report calibration (older Alpaca, etc.) — callers should treat
    /// that as "validation unavailable", not as a calibration failure.
    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        Err("guider_get_calibration not supported by this driver".to_string())
    }

    /// Start guiding
    async fn guider_start(
        &self,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> DeviceResult<()>;

    /// Make the guider drop the star it had and pick one afresh from a new
    /// frame. Called before every start of guiding the run makes, because the
    /// field may have changed since the guider last selected a star; an Err
    /// means no star was found. A guider that selects its own star on every
    /// start keeps this default.
    async fn guider_select_fresh_star(&self) -> DeviceResult<()> {
        Ok(())
    }

    /// [`Self::guider_select_fresh_star`], refusing a star that measures
    /// below `floor` and looking again in the next frames. An Err means no
    /// star at or above the floor was found. A guider that cannot measure
    /// the star it selects keeps this default and selects unchecked.
    async fn guider_select_fresh_star_above(&self, _floor: GuideStarFloor) -> DeviceResult<()> {
        self.guider_select_fresh_star().await
    }

    /// The star the guider is guiding on, averaged over its recent guide
    /// steps. `None` when it has no guide steps or cannot measure stars.
    async fn guider_star_quality(&self) -> DeviceResult<Option<GuideStarQuality>> {
        Ok(None)
    }

    /// Stop guiding
    async fn guider_stop(&self) -> DeviceResult<()>;

    /// Record why the run holds the guider stopped, before it stops it, so
    /// the guider's status can say so; `None` withdraws the run's reason.
    /// A successful start of guiding clears it as well.
    async fn guider_note_stop_reason(&self, _reason: Option<crate::GuidingStopReason>) {}
}
