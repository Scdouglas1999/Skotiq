use super::*;

/// Derive the guide camera's angular sampling from physical pixel pitch and
/// focal length. Binning enlarges each centroid pixel by the same factor.
pub(crate) fn guide_pixel_scale_arcsec(
    pixel_size_um: f64,
    focal_length_mm: f64,
    binning: i32,
) -> Option<f64> {
    if !pixel_size_um.is_finite()
        || pixel_size_um <= 0.0
        || !focal_length_mm.is_finite()
        || focal_length_mm <= 0.0
        || binning <= 0
    {
        return None;
    }

    Some(206.265 * pixel_size_um * f64::from(binning) / focal_length_mm)
}

pub(crate) fn binned_guide_pixel_scale(unbinned_pixel_scale: f64, binning: i32) -> Option<f64> {
    if !unbinned_pixel_scale.is_finite() || unbinned_pixel_scale <= 0.0 || binning <= 0 {
        return None;
    }

    Some(unbinned_pixel_scale * f64::from(binning))
}

pub(crate) fn guide_offset_arcsec(offset_pixels: Vec2, pixel_scale_arcsec: f64) -> Option<Vec2> {
    if !pixel_scale_arcsec.is_finite() || pixel_scale_arcsec <= 0.0 {
        return None;
    }

    Some(Vec2 {
        x: offset_pixels.x * pixel_scale_arcsec,
        y: offset_pixels.y * pixel_scale_arcsec,
    })
}

#[derive(Clone, Debug)]
pub(crate) struct GuideReferenceStar {
    pub(crate) x: f64,
    pub(crate) y: f64,
    pub(crate) flux: f64,
    pub(crate) snr: f64,
    /// Per-star residual against this reference's expected position on the most
    /// recent matched frame, in pixels. `None` until the star is matched at
    /// least once (e.g. immediately after `select_reference_stars`). Populated
    /// by [`measure_offset`] each guide frame so the per-star UI can show how
    /// far each tracked star drifted, not just the aggregate centroid offset.
    pub(crate) last_residual: Option<Vec2>,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct GuideCalibration {
    /// Measured pixel displacement produced by one `pulse_ms` pulse on the RA+
    /// (east) axis. Direction encodes the RA axis angle; magnitude/`pulse_ms`
    /// gives the RA rate (px/ms).
    pub(crate) east: Vec2,
    /// Measured pixel displacement produced by one `pulse_ms` pulse on the Dec+
    /// (north) axis.
    pub(crate) north: Vec2,
    pub(crate) pulse_ms: f64,
    /// Dec backlash, in pulse-milliseconds: the dead-band the Dec gear takes up
    /// on the first pulse after a direction reversal. Measured during
    /// calibration as the shortfall of the first reverse pulse versus the
    /// established forward rate. 0 when no backlash was detected.
    pub(crate) dec_backlash_ms: f64,
    /// Angle between the measured RA and Dec axes, in degrees. A healthy mount is
    /// near 90°; large departures are logged as a calibration-quality warning but
    /// do not block guiding (the full 2×2 solve still applies).
    pub(crate) orthogonality_deg: f64,
}

impl GuideCalibration {
    /// RA rate in pixels per millisecond (magnitude of the east response per ms).
    pub(crate) fn ra_rate(&self) -> f64 {
        if self.pulse_ms > 0.0 {
            self.east.magnitude() / self.pulse_ms
        } else {
            0.0
        }
    }

    /// Dec rate in pixels per millisecond.
    pub(crate) fn dec_rate(&self) -> f64 {
        if self.pulse_ms > 0.0 {
            self.north.magnitude() / self.pulse_ms
        } else {
            0.0
        }
    }
}

/// Which way Dec was last commanded, so the next correction can pay the backlash
/// dead-band exactly once on a reversal (not every Dec pulse).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DecDirection {
    North,
    South,
}

#[derive(Clone, Debug)]
pub(crate) struct GuideFrame {
    pub(crate) frame: u32,
    pub(crate) image: ImageData,
    pub(crate) stars: Vec<DetectedStar>,
    /// Angular sampling for this frame's configured binning.
    pub(crate) pixel_scale_arcsec: f64,
}

#[derive(Clone, Debug)]
pub(crate) struct GuideSnapshot {
    pub(crate) frame: u32,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) pixels: Vec<u8>,
    pub(crate) crop_origin_x: i32,
    pub(crate) crop_origin_y: i32,
    /// Star position INSIDE the crop, i.e. in the 50-100 px thumbnail's own
    /// coordinates. Right for drawing crosshairs on that thumbnail; wrong for
    /// anything the operator reads as a position on the guide frame — see
    /// [`GuideSnapshot::star_frame_position`].
    pub(crate) star_x: f64,
    pub(crate) star_y: f64,
}

impl GuideSnapshot {
    /// The star's position in the FULL guide frame.
    ///
    /// When `find_star` and `get_lock_position` answer in CROP coordinates,
    /// one Auto Select click logs "chose a guide star at (967.8, 724.3) px"
    /// and then "locked guide star at (24.8, 25.3) px", and the
    /// operator-facing banner shows the second — the corner of a 1920x1080
    /// guide frame for a star locked near its centre. PHD2's own `find_star`
    /// answers in frame coordinates, so the two guider backends disagree as
    /// well.
    pub(crate) fn star_frame_position(&self) -> (f64, f64) {
        (
            self.crop_origin_x as f64 + self.star_x,
            self.crop_origin_y as f64 + self.star_y,
        )
    }
}

#[derive(Clone, Debug)]
pub struct BuiltinGuideStatus {
    pub connected: bool,
    pub state: String,
    /// Current RA-axis guide error in arcseconds.
    pub rms_ra: f64,
    /// Current Dec-axis guide error in arcseconds.
    pub rms_dec: f64,
    /// Current total guide error in arcseconds.
    pub rms_total: f64,
    pub snr: f64,
    pub star_mass: f64,
    /// Guide-camera angular sampling in arcseconds per binned pixel.
    pub pixel_scale: f64,
}

impl Default for BuiltinGuideStatus {
    fn default() -> Self {
        Self {
            connected: false,
            state: "Disconnected".to_string(),
            rms_ra: 0.0,
            rms_dec: 0.0,
            rms_total: 0.0,
            snr: 0.0,
            star_mass: 0.0,
            pixel_scale: 0.0,
        }
    }
}

// Per-star tracked-star export for the guider UI
//
// The built-in guider tracks up to `GUIDE_MAX_TRACKED_STARS` reference stars,
// but `get_status()` only returns the PHD2-shaped *aggregate* `Phd2Status`
// (rms/snr/star_mass), so the 8 tracked stars never reached the Dart UI and its
// star-list panel rendered empty.
//
// These DTOs surface the per-star list. They are `#[frb(ignore)]` and serialize
// to a JSON *string* so they ride alongside the existing guiding-status path
// without changing any flutter_rust_bridge-generated struct shape (no regen).
// The same `*_json: String` convention is used by the typed event payloads in
// `event.rs` (FRB does not bridge `serde_json::Value` directly).

/// One tracked reference star, as surfaced to the per-star guider UI.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Clone, Debug, Serialize)]
pub struct BuiltinGuideTrackedStar {
    /// Stable index within the tracked-star list (0-based), used by the UI as
    /// the per-star identity / lock-star key.
    pub id: usize,
    /// Centroid X in guide-camera pixels.
    pub x: f64,
    /// Centroid Y in guide-camera pixels.
    pub y: f64,
    /// Integrated flux (star mass / brightness).
    pub flux: f64,
    /// Signal-to-noise ratio.
    pub snr: f64,
    /// Whether this is the active lock star (the centroid the corrections key
    /// off). `None` when no lock has been established yet.
    pub is_lock: bool,
    /// Per-star residual magnitude (pixels) on the most recent matched frame, or
    /// `None` before the star has been matched at least once.
    pub residual: Option<f64>,
    /// Relative weight this star carries in the sigma-clipped weighted centroid
    /// (flux/SNR derived). Higher means a brighter, cleaner star that pulls the
    /// aggregate offset harder. Surfaced so the UI can show contribution.
    pub weight: f64,
}

/// Per-star tracked-star snapshot. Serialized to JSON and exposed through the
/// guiding-status path so the Dart guider UI can populate its star list + feed
/// the same `CompactGuidingGraph` the PHD2 path uses.
#[flutter_rust_bridge::frb(ignore)]
#[derive(Clone, Debug, Serialize, Default)]
pub struct BuiltinGuideTrackedStars {
    /// Number of stars currently tracked (mirrors `stars.len()`; convenience for
    /// consumers that only need the count).
    pub count: usize,
    /// The tracked reference stars, brightest-first as selected.
    pub stars: Vec<BuiltinGuideTrackedStar>,
}

/// Build the per-star tracked-star DTO from the current reference-star set.
///
/// The lock star is the reference nearest the active manual lock position (the
/// centroid the guider corrects to); ties fall back to the first/brightest star
/// when no lock has been set.
#[flutter_rust_bridge::frb(ignore)]
pub(crate) fn build_tracked_stars(state: &BuiltinGuiderState) -> BuiltinGuideTrackedStars {
    let lock = state.manual_lock;
    // Choose the lock-star index: the reference closest to the manual lock.
    let lock_index = lock.and_then(|target| {
        state
            .reference_stars
            .iter()
            .enumerate()
            .map(|(i, r)| {
                let dx = r.x - target.x;
                let dy = r.y - target.y;
                (i, (dx * dx + dy * dy).sqrt())
            })
            .min_by(|(_, a), (_, b)| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal))
            .map(|(i, _)| i)
    });

    let stars = state
        .reference_stars
        .iter()
        .enumerate()
        .map(|(i, r)| BuiltinGuideTrackedStar {
            id: i,
            x: r.x,
            y: r.y,
            flux: r.flux,
            snr: r.snr,
            is_lock: Some(i) == lock_index,
            residual: r.last_residual.map(|v| v.magnitude()),
            weight: guide_reference_weight(r),
        })
        .collect::<Vec<_>>();

    BuiltinGuideTrackedStars {
        count: stars.len(),
        stars,
    }
}

/// Per-star tracked-star list, serialized to a JSON string.
///
/// `#[frb(ignore)]` so it never touches the generated bridge: the JSON rides
/// through the existing guiding-status network path (the headless API embeds it
/// as a `trackedStars` array) where the Dart `Phd2Status`/`GuideStar` models
/// decode it. Returns `{"count":0,"stars":[]}` when nothing is tracked.
#[flutter_rust_bridge::frb(ignore)]
pub async fn get_tracked_stars_json() -> String {
    let guard = state().read().await;
    let dto = build_tracked_stars(&guard);
    serde_json::to_string(&dto).unwrap_or_else(|_| "{\"count\":0,\"stars\":[]}".to_string())
}

/// The tolerance an OPEN settle episode is judged by.
///
/// `start_guiding` seeds it for the post-calibration settle; `dither` REPLACES
/// it, because the caller asking for a dither passes its own settle spec (the
/// sequencer's per-dither settings) and that is the spec the dither has to be
/// measured against. Before this existed the guiding loop kept using the values
/// captured at `start_guiding`, so a sequence that dithered with a tighter
/// tolerance was told it had settled at the looser one.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct SettleSpec {
    /// Total RMS, in guide-camera pixels, the frame must be under to count.
    pub(crate) pixels: f64,
    /// How long the RMS must stay under `pixels` before the settle completes.
    pub(crate) time: f64,
    /// Wall-clock ceiling on the whole settle episode.
    pub(crate) timeout: f64,
}

impl Default for SettleSpec {
    /// Matches the historical hard defaults of the guiding panel: settle when
    /// RMS is under 1.5px for 5s, give up after 40s. Only ever observed before
    /// the first `start_guiding`, since both entry points overwrite it.
    fn default() -> Self {
        Self {
            pixels: 1.5,
            time: 5.0,
            timeout: 40.0,
        }
    }
}

pub(crate) struct BuiltinGuiderState {
    pub(crate) connected: bool,
    pub(crate) guiding: bool,
    pub(crate) looping: bool,
    pub(crate) calibrating: bool,
    pub(crate) camera_id: Option<String>,
    pub(crate) mount_id: Option<String>,
    pub(crate) reference_stars: Vec<GuideReferenceStar>,
    pub(crate) manual_lock: Option<Vec2>,
    pub(crate) desired_offset: Vec2,
    pub(crate) calibration: Option<GuideCalibration>,
    pub(crate) last_frame: Option<GuideFrame>,
    pub(crate) last_snapshot: Option<GuideSnapshot>,
    pub(crate) last_status: BuiltinGuideStatus,
    pub(crate) settle_deadline: Option<Instant>,
    /// Absolute deadline after which settling is considered failed
    pub(crate) settle_timeout_deadline: Option<Instant>,
    /// Tolerance the open settle episode is judged by — see [`SettleSpec`].
    pub(crate) settle_spec: SettleSpec,
    /// Whether a settle EPISODE is open — the initial settle after calibration,
    /// or the one a dither asked for. Steady guiding is not settling, so once an
    /// episode completes nothing re-opens it until something asks again.
    pub(crate) settling: bool,
    pub(crate) dither_pending: bool,
    /// Offset the pending dither started from, restored when that dither has to
    /// be abandoned so an unsatisfiable dither leaves guiding where it was.
    pub(crate) dither_origin: Vec2,
    /// Consecutive frames the pending dither has failed to match stars on.
    pub(crate) dither_misses: u32,
    /// Set when a pending dither was abandoned (rolled back) instead of settled,
    /// so the waiting `dither()` reports failure while guiding keeps running.
    pub(crate) dither_abandoned: bool,
    /// Last Dec direction actually pulsed, used to apply backlash compensation
    /// exactly on a reversal. `None` until the first Dec correction.
    pub(crate) last_dec_direction: Option<DecDirection>,
    /// Signed per-axis correction demand (ms) that was too short for the mount
    /// to honour and is being carried into the next frame. See [`PulseDebt`].
    pub(crate) pulse_debt: PulseDebt,
    /// Index into the bounded dither pattern, advanced once per dither and wrapped
    /// by [`DITHER_PATTERN_POINTS`] so successive dithers walk to fresh pixels
    /// without walking away from the target.
    pub(crate) dither_step: u32,
    /// Recent per-frame total RMS (pixels), newest last, capped in length. Drives
    /// adaptive dither settle tolerance (poorer seeing -> looser settle).
    pub(crate) rms_history: Vec<f64>,
    /// Recent per-axis guide errors in ARCSEC, newest last, capped in length.
    ///
    /// Backs the `rms_ra`/`rms_dec`/`rms_total` this guider reports. Those fields
    /// live on a PHD2-shaped status struct that PHD2 fills with a genuine
    /// root-mean-square, so they must be an RMS over this window too: the current
    /// frame's absolute offset under the same "RMS Tot" label is a strictly
    /// noisier statistic, and makes this guider look worse than PHD2 for free.
    pub(crate) rms_samples_arcsec: Vec<Vec2>,
    /// Native, unbinned guide-camera sampling in arcsec/pixel. Derived from the
    /// active profile focal length and the selected camera's physical pixel size.
    /// Kept separately so a live binning config change can update the reported
    /// scale without re-querying hardware.
    pub(crate) unbinned_pixel_scale: Option<f64>,
    pub(crate) stop_flag: Option<Arc<std::sync::atomic::AtomicBool>>,
    pub(crate) task: Option<JoinHandle<()>>,
    pub(crate) config: GuiderConfig,
}

impl Default for BuiltinGuiderState {
    fn default() -> Self {
        Self {
            connected: false,
            guiding: false,
            looping: false,
            calibrating: false,
            camera_id: None,
            mount_id: None,
            reference_stars: Vec::new(),
            manual_lock: None,
            desired_offset: Vec2::default(),
            calibration: None,
            last_frame: None,
            last_snapshot: None,
            last_status: BuiltinGuideStatus::default(),
            settle_deadline: None,
            settle_timeout_deadline: None,
            settle_spec: SettleSpec::default(),
            settling: false,
            dither_pending: false,
            dither_origin: Vec2::default(),
            dither_misses: 0,
            dither_abandoned: false,
            last_dec_direction: None,
            pulse_debt: PulseDebt::default(),
            dither_step: 0,
            rms_history: Vec::new(),
            rms_samples_arcsec: Vec::new(),
            unbinned_pixel_scale: None,
            stop_flag: None,
            task: None,
            config: GuiderConfig::default(),
        }
    }
}

/// Maximum number of recent RMS samples retained for adaptive dither.
pub(crate) const RMS_HISTORY_LEN: usize = 20;

pub(crate) static BUILTIN_GUIDER: OnceLock<Arc<RwLock<BuiltinGuiderState>>> = OnceLock::new();

pub(crate) fn state() -> &'static Arc<RwLock<BuiltinGuiderState>> {
    BUILTIN_GUIDER.get_or_init(|| Arc::new(RwLock::new(BuiltinGuiderState::default())))
}

/// Serializes the loop-lifecycle entry points (`start_guiding`, `loop_exposures`,
/// `stop`, `disconnect`) so a start and a concurrent stop can never interleave.
///
/// The per-operation `state()` write-lock is released between "set guiding=true"
/// and "spawn the loop", so it alone cannot make start/stop atomic. Without this
/// mutex a `stop()` landing in the window after the loop is spawned but before its
/// `JoinHandle`/`stop_flag` is recorded would take `None`, signal nothing, return
/// Ok, and orphan a mount-pulsing loop. Holding this mutex
/// across the whole start (lock → spawn → record handle) and the whole stop
/// guarantees stop always observes a live loop and cancels it.
pub(crate) static GUIDER_OP_LOCK: OnceLock<Arc<Mutex<()>>> = OnceLock::new();

pub(crate) fn op_lock() -> &'static Arc<Mutex<()>> {
    GUIDER_OP_LOCK.get_or_init(|| Arc::new(Mutex::new(())))
}
