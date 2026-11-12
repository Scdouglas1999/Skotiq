//! The guider the rig guides with: PHD2 (an outside program reached over its
//! event socket) or the built-in multi-star guider. Both answer the same
//! operations here, and which one answers is the profile's choice
//! ([`Guider::active`]). The sequencer, the simulator and the FFI all go
//! through this one door; what only PHD2 has (its algorithm settings, its
//! calibration store) stays in [`phd2`].

pub(crate) mod phd2;
pub(crate) mod stop_reason;

use crate::device_manager::get_device_manager;
use crate::state::get_state;
use crate::device::DeviceType;
use crate::error::SkotiqError;

/// What the guider is doing and how well it guides.
#[derive(Debug, Clone)]
pub struct GuiderStatus {
    /// The guider that answered (`phd2_guider` or the built-in guider's id).
    pub device_id: String,
    pub connected: bool,
    /// "Disconnected", "Connected", "Stopped", "Calibrating", "Guiding",
    /// "Looping", "Paused", "Settling", "LostLock", or a state PHD2 names
    /// that this build does not know, as PHD2 spells it.
    pub state: String,
    /// Guide error RMS in arcseconds.
    pub rms_ra: f64,
    pub rms_dec: f64,
    pub rms_total: f64,
    pub snr: f64,
    pub star_mass: f64,
    /// Guide camera pixel scale in arcseconds per pixel. `None` when the
    /// guider has no scale to give (PHD2 without focal length and pixel size
    /// in its profile, or a failed read). Never a placeholder 0.
    pub pixel_scale: Option<f64>,
    /// Why the guider is stopped or held, as the snake_case name of a
    /// `GuidingStopReason` (`autofocus`, `meridian_flip`,
    /// `tracking_limit_hold`, `mount_move`, `pre_meridian_hold`,
    /// `sequence_step`, `dither_settle`, `run_stopped`, `operator`). `None`
    /// while guiding runs or when nothing recorded a reason.
    pub stop_reason: Option<String>,
    /// The reference stars the built-in multi-star guider tracks. PHD2
    /// guides on one star and reports none here.
    pub tracked_stars: Vec<TrackedGuideStar>,
}

/// One reference star the built-in multi-star guider tracks.
#[derive(Debug, Clone)]
pub struct TrackedGuideStar {
    /// Index within the tracked list, the star's identity in the UI.
    pub id: u32,
    /// Centroid in guide-camera pixels.
    pub x: f64,
    pub y: f64,
    pub flux: f64,
    pub snr: f64,
    /// The star the corrections key off.
    pub is_lock: bool,
    /// Distance in pixels from where the star was expected on the last
    /// matched frame; `None` before it was matched once.
    pub residual: Option<f64>,
    /// Weight the star carries in the guide offset (from flux and SNR).
    pub weight: f64,
}

/// A crop of the guide frame around the guide star.
#[derive(Debug, Clone)]
pub struct GuideStarImage {
    pub frame: u32,
    pub width: u32,
    pub height: u32,
    /// Star centroid inside the crop.
    pub star_x: f64,
    pub star_y: f64,
    /// 16-bit grayscale pixels, little endian.
    pub pixels: Vec<u8>,
}

/// The guider's calibration of the mount.
#[derive(Debug, Clone)]
pub struct GuiderCalibration {
    pub is_calibrated: bool,
    /// Axis angles in degrees.
    pub ra_angle: Option<f64>,
    pub dec_angle: Option<f64>,
    /// Guide rates in pixels per second.
    pub ra_rate: Option<f64>,
    pub dec_rate: Option<f64>,
}


/// One of the guiders this build can guide with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Guider {
    Phd2,
    Builtin,
}

impl Guider {
    /// The guider a device id names. PHD2 has several spellings in saved
    /// profiles ([`phd2::is_device_id`]); the built-in guider has one id.
    pub(crate) fn for_device(device_id: &str) -> Result<Self, SkotiqError> {
        if phd2::is_device_id(device_id) {
            return Ok(Self::Phd2);
        }
        if device_id == crate::builtin_guider::device_id() {
            return Ok(Self::Builtin);
        }
        Err(SkotiqError::OperationFailed(format!(
            "Unsupported guider device: {}",
            device_id
        )))
    }

    pub(crate) fn device_id(self) -> &'static str {
        match self {
            Self::Phd2 => phd2::DEVICE_ID,
            Self::Builtin => crate::builtin_guider::device_id(),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Phd2 => "PHD2",
            Self::Builtin => "built-in",
        }
    }

    /// The guider the rig guides with: the profile's guider when it is
    /// connected, otherwise the guider that is connected, otherwise the
    /// profile's guider (whose operations then say it is not connected).
    /// `None` when the profile names no guider and none is connected.
    pub(crate) async fn active() -> Result<Option<Self>, SkotiqError> {
        let connected: Vec<String> = get_device_manager()
            .get_connected_device_infos()
            .await
            .into_iter()
            .filter(|device| device.device_type == DeviceType::Guider)
            .map(|device| device.id)
            .collect();
        let profile_guider = get_state()
            .get_profile_device_id(DeviceType::Guider)
            .await;
        Self::choose(profile_guider.as_deref(), &connected)
    }

    fn choose(
        profile_guider: Option<&str>,
        connected: &[String],
    ) -> Result<Option<Self>, SkotiqError> {
        let profile_guider = profile_guider.map(Self::for_device).transpose()?;
        let is_connected = |guider: &Self| connected.iter().any(|id| id == guider.device_id());
        if profile_guider.as_ref().is_some_and(is_connected) {
            return Ok(profile_guider);
        }
        Ok([Self::Builtin, Self::Phd2]
            .into_iter()
            .find(is_connected)
            .or(profile_guider))
    }

    /// Start guiding and wait for it to settle. A settle that runs out while
    /// the guider still holds the star leaves it guiding; the caller judges
    /// the guide error itself.
    pub(crate) async fn start(
        self,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> Result<(), SkotiqError> {
        match self {
            Self::Phd2 => phd2::start_guiding(settle_pixels, settle_time, settle_timeout).await,
            Self::Builtin => {
                crate::builtin_guider::start_guiding(settle_pixels, settle_time, settle_timeout)
                    .await?;
                stop_reason::set(None);
                Ok(())
            }
        }
    }

    /// Stop guiding and return once the guider sends no more corrections, so
    /// the mount can be moved. The run states its reason first
    /// ([`stop_reason::set`]).
    pub(crate) async fn stop(self) -> Result<(), SkotiqError> {
        match self {
            Self::Phd2 => phd2::stop_guiding().await,
            Self::Builtin => crate::builtin_guider::stop().await,
        }
    }

    /// [`Self::stop`] from the guider controls: an operator's stop unless the
    /// run already gave a reason.
    pub(crate) async fn stop_by_operator(self) -> Result<(), SkotiqError> {
        self.stop().await?;
        stop_reason::note_operator_stop();
        Ok(())
    }

    /// Move the guide star by up to `amount` guide-camera pixels and wait for
    /// the guider to settle. A settle that fails is an error, so a run never
    /// exposes while the guider is still moving.
    pub(crate) async fn dither(
        self,
        amount: f64,
        ra_only: bool,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> Result<(), SkotiqError> {
        match self {
            Self::Phd2 => {
                phd2::dither(amount, ra_only, settle_pixels, settle_time, settle_timeout).await
            }
            Self::Builtin => {
                crate::builtin_guider::dither(
                    amount,
                    ra_only,
                    settle_pixels,
                    settle_time,
                    settle_timeout,
                )
                .await
            }
        }
    }

    /// Take guide frames without guiding.
    pub(crate) async fn loop_exposures(self) -> Result<(), SkotiqError> {
        match self {
            Self::Phd2 => phd2::loop_exposures().await,
            Self::Builtin => crate::builtin_guider::loop_exposures().await,
        }
    }

    /// Hold guide corrections while the guider keeps its star, or resume them.
    pub(crate) async fn set_paused(self, paused: bool) -> Result<(), SkotiqError> {
        match self {
            Self::Phd2 => phd2::set_paused(paused).await,
            Self::Builtin => crate::builtin_guider::set_paused(paused).await,
        }
    }

    /// Pick a guide star in the current frame, in frame pixels.
    pub(crate) async fn find_star(self) -> Result<(f64, f64), SkotiqError> {
        tracing::info!(
            "Auto Select: asking the {} guider to pick a guide star",
            self.name()
        );
        let result = match self {
            Self::Phd2 => phd2::find_star().await,
            Self::Builtin => crate::builtin_guider::find_star().await,
        };
        match &result {
            Ok((x, y)) => tracing::info!("Auto Select: locked guide star at ({x:.1}, {y:.1}) px"),
            Err(e) => tracing::warn!("Auto Select: no guide star selected ({e})"),
        }
        result
    }

    /// Drop the star the guider had and pick one from a frame taken after
    /// this call, before the run (re)starts guiding: after a slew the old
    /// lock position is empty sky. With a `floor`, a star that measures below
    /// it is refused and the search goes on. The built-in guider selects its
    /// star inside every start, so it has nothing to do here.
    pub(crate) async fn select_fresh_star(
        self,
        floor: Option<skotiq_sequencer::GuideStarFloor>,
    ) -> Result<(), SkotiqError> {
        match self {
            Self::Phd2 => phd2::select_fresh_star(floor).await.map(|_| ()),
            Self::Builtin => Ok(()),
        }
    }

    /// Lock on the star nearest (`x`, `y`); PHD2 takes the position as given
    /// when `exact`.
    pub(crate) async fn set_lock_position(
        self,
        x: f64,
        y: f64,
        exact: bool,
    ) -> Result<(), SkotiqError> {
        match self {
            Self::Phd2 => phd2::set_lock_position(x, y, exact).await,
            Self::Builtin => crate::builtin_guider::set_lock_position(x, y).await,
        }
    }

    pub(crate) async fn lock_position(self) -> Result<(f64, f64), SkotiqError> {
        match self {
            Self::Phd2 => phd2::lock_position().await,
            Self::Builtin => crate::builtin_guider::get_lock_position().await,
        }
    }

    pub(crate) async fn deselect_star(self) -> Result<(), SkotiqError> {
        match self {
            Self::Phd2 => phd2::deselect_star().await,
            Self::Builtin => crate::builtin_guider::deselect_star().await,
        }
    }

    pub(crate) async fn star_image(self, size: u32) -> Result<GuideStarImage, SkotiqError> {
        match self {
            Self::Phd2 => phd2::star_image(size).await,
            Self::Builtin => crate::builtin_guider::get_star_image(size).await,
        }
    }

    pub(crate) async fn status(self) -> Result<GuiderStatus, SkotiqError> {
        let mut status = match self {
            Self::Phd2 => phd2::status().await?,
            Self::Builtin => crate::builtin_guider::get_status().await,
        };
        status.stop_reason = stop_reason::reported(&status.state);
        Ok(status)
    }

    pub(crate) async fn calibration(self) -> Result<GuiderCalibration, SkotiqError> {
        match self {
            Self::Phd2 => phd2::calibration().await,
            Self::Builtin => Ok(crate::builtin_guider::get_calibration_data().await),
        }
    }
}

/// Whether a guider in `state` may move the mount: anything but idle,
/// looping or paused. PHD2 in LostLock keeps searching and guides again the
/// moment it finds the star; settling and calibrating move the mount; a
/// state this build does not know is treated as moving it.
pub(crate) fn state_may_move_mount(state: &str) -> bool {
    !matches!(
        state,
        "Disconnected" | "Connected" | "Stopped" | "Selected" | "Looping" | "Paused"
    )
}

/// Serializes the tests that touch the process-wide guider state: the PHD2
/// client slot, the device registries and the stop reason.
#[cfg(test)]
pub(crate) static TEST_SLOT: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[cfg(test)]
mod tests {
    use super::*;

    fn backend_name(device_id: &str) -> Result<&'static str, String> {
        match Guider::for_device(device_id) {
            Ok(guider) => Ok(guider.name()),
            Err(SkotiqError::OperationFailed(msg)) => Err(msg),
            Err(other) => panic!("unexpected error variant: {:?}", other),
        }
    }

    #[test]
    fn every_phd2_id_spelling_names_phd2() {
        for id in [
            "phd2_guider",
            "phd2",
            "phd2:localhost:4400",
            "phd2://host",
            "phd2:",
        ] {
            assert_eq!(backend_name(id), Ok("PHD2"), "id {id} must route to PHD2");
        }
    }

    #[test]
    fn the_builtin_guider_id_names_the_builtin_guider() {
        assert_eq!(
            backend_name(crate::builtin_guider::device_id()),
            Ok("built-in")
        );
    }

    #[test]
    fn any_other_id_is_an_unsupported_guider() {
        assert_eq!(
            backend_name(""),
            Err("Unsupported guider device: ".to_string())
        );
        assert_eq!(
            backend_name("phd2x-not-really-phd2"),
            Err("Unsupported guider device: phd2x-not-really-phd2".to_string())
        );
        assert_eq!(
            backend_name("ascom:ASCOM.Simulator.Camera"),
            Err("Unsupported guider device: ascom:ASCOM.Simulator.Camera".to_string())
        );
        assert_eq!(
            backend_name("PHD2_GUIDER"),
            Err("Unsupported guider device: PHD2_GUIDER".to_string())
        );
    }

    #[test]
    fn the_active_guider_is_the_profiles_when_connected_else_the_connected_one() {
        let builtin = crate::builtin_guider::device_id();
        let connected = |ids: &[&str]| ids.iter().map(|id| id.to_string()).collect::<Vec<_>>();

        let both = connected(&[builtin, phd2::DEVICE_ID]);
        assert_eq!(
            Guider::choose(Some("phd2:localhost:4400"), &both).unwrap(),
            Some(Guider::Phd2),
            "any PHD2 spelling in the profile names the connected PHD2"
        );
        assert_eq!(
            Guider::choose(Some(phd2::DEVICE_ID), &both).unwrap(),
            Some(Guider::Phd2),
            "the profile's guider wins when both are connected"
        );
        assert_eq!(
            Guider::choose(Some(builtin), &connected(&[phd2::DEVICE_ID])).unwrap(),
            Some(Guider::Phd2),
            "a connected guider answers when the profile's is not connected"
        );
        assert_eq!(
            Guider::choose(Some(builtin), &[]).unwrap(),
            Some(Guider::Builtin),
            "with nothing connected the profile's guider answers, as not connected"
        );
        assert_eq!(Guider::choose(None, &[]).unwrap(), None);
        assert!(
            Guider::choose(Some("alpaca:guider"), &connected(&[builtin])).is_err(),
            "a profile guider this build cannot drive is an error, not a silent fallback"
        );
    }

    #[test]
    fn a_guider_that_may_move_the_mount_is_any_but_idle_looping_or_paused() {
        for state in [
            "Guiding",
            "Calibrating",
            "Settling",
            "LostLock",
            "GuidingPaused",
        ] {
            assert!(state_may_move_mount(state), "{state}");
        }
        for state in [
            "Disconnected",
            "Connected",
            "Stopped",
            "Selected",
            "Looping",
            "Paused",
        ] {
            assert!(!state_may_move_mount(state), "{state}");
        }
    }
}
