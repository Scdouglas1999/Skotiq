//! Judging each saved light frame against the target and the frames before
//! it: is the field where it should be, did the stars survive, and does a run
//! of starless frames look like something in front of the telescope.
//!
//! Pure bookkeeping, no devices: the trigger monitor feeds it one
//! [`FrameObservation`] per frame and acts on the [`WatchAction`]s it returns.
//!
//! * **Off target.** A solved center farther from the target than
//!   [`FrameWatchConfig::drift_limit_fraction`] of the frame's shorter side
//!   marks the frame off target (it no longer counts as integration) and asks
//!   for one recenter. Frames whose exposure began before that recenter
//!   finished are off target too, but ask for nothing more.
//! * **Collapsed.** A frame keeping less than [`COLLAPSE_RATIO`] of the stars
//!   its filter's recent accepted frames had at that airmass, or none at all.
//! * **Obstruction or cloud.** Two collapsed frames in a row are reported as a
//!   possible obstruction or cloud at the target's altitude and azimuth. Three
//!   or more while the target sinks, with failed solves, a lost guide star or
//!   a shifted sky background on at least two of them, look like the target
//!   setting behind something, and the monitor checks that with a probe frame
//!   higher in the sky. Inside a horizon point learned on an earlier night two
//!   collapsed frames are enough and no probe is needed. Starless frames on a
//!   rising or steady target are cloud: the run carries on and the frames are
//!   graded as usual.

use super::config::{FrameWatchConfig, HorizonPoint};
use crate::quality::{filter_baseline_key, FilterBaseline};
use std::collections::{HashMap, VecDeque};

/// A frame keeping less than this fraction of its baseline's stars collapsed.
pub const COLLAPSE_RATIO: f64 = 0.5;

/// Collapsed frames in a row before the operator hears of a possible
/// obstruction or cloud.
pub const POSSIBLE_OBSTRUCTION_FRAMES: usize = 2;

/// Collapsed frames in a row before an obstruction is probed for.
pub const OBSTRUCTION_FRAMES: usize = 3;

/// Frames of such a run that must also show a failed solve, a lost guide star
/// or a shifted background.
pub const OBSTRUCTION_CORROBORATING_FRAMES: usize = 2;

/// Relative change of the sky background that corroborates an obstruction.
pub const BACKGROUND_SHIFT: f64 = 0.15;

/// Frames after a probe that found cloud before another probe is tried.
pub const CLOUD_BACKOFF_FRAMES: u64 = 8;

/// How far the target must sink over a run of collapsed frames to count as
/// setting.
const SETTING_MIN_DROP_DEG: f64 = 0.2;

/// A frame keeping at least this fraction of its baseline's stars is clean.
/// Between [`COLLAPSE_RATIO`] and this a frame is partly blocked: a run of
/// collapsed frames goes on through it.
pub const RECOVERED_RATIO: f64 = 0.8;

/// Clean frames in a row that end a run of collapsed frames.
pub const CLEAN_FRAMES_TO_RECOVER: usize = 2;

/// Fewer stars than this is no field to judge or focus on, whatever the
/// baseline (the autofocus's own minimum).
pub const MIN_USABLE_STARS: u32 = 10;

/// Eccentricity at and above which a frame's stars are trails, not stars a
/// tree or cloud dimmed. Trees thin a field to noisy shapes up to about 0.9;
/// an untracked mount draws trails near 1.
pub const TRAILED_ECCENTRICITY: f64 = 0.95;

/// The longest a run of collapsed frames may pause between two of its frames,
/// as a multiple of the exposure, and never less than
/// [`STREAK_MIN_GAP_SECS`]. A frame after a longer pause starts a new run:
/// frames an hour apart say nothing together.
const STREAK_GAP_EXPOSURES: f64 = 5.0;
const STREAK_MIN_GAP_SECS: f64 = 15.0 * 60.0;

/// Prefix of the exclusion reason of an off-target frame. The app matches on
/// it.
pub const OFF_TARGET_PREFIX: &str = "Off target:";

/// Prefix of the exclusion reason of an obstructed frame. The app matches on
/// it.
pub const OBSTRUCTED_PREFIX: &str = "Obstructed:";

/// What the plate solve of a frame found.
#[derive(Debug, Clone, PartialEq)]
pub enum SolveOutcome {
    NotAttempted,
    Failed,
    Solved {
        ra_deg: f64,
        dec_deg: f64,
        pixel_scale_arcsec: f64,
        rotation_deg: f64,
    },
}

impl SolveOutcome {
    pub fn failed(&self) -> bool {
        matches!(self, SolveOutcome::Failed)
    }
}

/// Everything known about one saved light frame.
#[derive(Debug, Clone)]
pub struct FrameObservation {
    pub save_path: String,
    pub target_name: Option<String>,
    pub filter: Option<String>,
    pub exposure_secs: f64,
    /// When the exposure began, in seconds on the clock
    /// [`FrameWatch::recentered`] is given.
    pub exposure_started_secs: f64,
    pub accepted_by_grader: bool,
    pub grader_reason: Option<String>,
    pub star_count: Option<u32>,
    pub hfr: Option<f64>,
    pub eccentricity: Option<f64>,
    pub altitude_deg: Option<f64>,
    pub azimuth_deg: Option<f64>,
    pub pier_side: Option<String>,
    pub solve: SolveOutcome,
    pub target_ra_deg: Option<f64>,
    pub target_dec_deg: Option<f64>,
    /// The frame's shorter side on the sky.
    pub field_short_side_arcmin: Option<f64>,
    pub background_adu: Option<f64>,
    pub guide_rms: Option<f64>,
    pub guide_rms_samples: u32,
    /// Guiding failed at this pointing: the guide star was lost, the run was
    /// imaging unguided, or guide-star recovery kept failing here. Counts as
    /// corroboration of an obstruction.
    pub guiding_lost: bool,
    /// The mount reported it was not tracking when the frame was saved: its
    /// stars are trails, whatever else dimmed them.
    pub mount_not_tracking: bool,
}

impl FrameObservation {
    /// Whether the frame's stars are trails: the mount was not tracking or
    /// the shapes are lines.
    pub fn trailed(&self) -> bool {
        self.mount_not_tracking || self.eccentricity.is_some_and(|e| e >= TRAILED_ECCENTRICITY)
    }

    fn pointing(&self) -> Option<Pointing> {
        Some(Pointing {
            altitude_deg: self.altitude_deg?,
            azimuth_deg: self.azimuth_deg?,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Pointing {
    pub altitude_deg: f64,
    pub azimuth_deg: f64,
}

impl Pointing {
    pub fn describe(&self) -> String {
        format!("alt {:.1}°, az {:.1}°", self.altitude_deg, self.azimuth_deg)
    }
}

impl From<Pointing> for HorizonPoint {
    fn from(p: Pointing) -> Self {
        HorizonPoint {
            azimuth_deg: p.azimuth_deg,
            altitude_deg: p.altitude_deg,
        }
    }
}

/// What the monitor should do about a frame.
#[derive(Debug, Clone, PartialEq)]
pub enum WatchAction {
    /// Slew, solve and sync back onto the target before the next frame.
    Recenter {
        offset_arcmin: f64,
        limit_arcmin: f64,
    },
    /// Tell the operator; nothing is decided yet.
    PossibleObstructionOrCloud { at: Pointing, frames: usize },
    /// Take a probe frame higher in the sky to tell an obstruction from cloud,
    /// then report it with [`FrameWatch::probe_result`].
    Probe { onset: Pointing },
    /// Something in front of the telescope from `onset` on.
    Obstruction { onset: Pointing, learned: bool },
    /// The stars came back after a reported run of collapsed frames.
    Recovered { frames: usize },
}

/// The judgment of one frame.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FrameVerdict {
    pub offset_arcmin: Option<f64>,
    pub drift_limit_arcmin: Option<f64>,
    pub off_target: bool,
    /// Star count over the airmass-scaled baseline of its filter.
    pub star_ratio: Option<f64>,
    pub collapsed: bool,
    /// The stars are trails (see [`FrameObservation::trailed`]). A trailed
    /// frame says nothing about an obstruction.
    pub trailed: bool,
    pub obstructed: bool,
    /// Why the frame is no good to focus on, if it is not.
    pub degraded: Option<String>,
    /// Why the frame no longer counts as integration, if it does not.
    pub exclusion_reason: Option<String>,
    pub actions: Vec<WatchAction>,
}

struct StreakFrame {
    save_path: String,
    at: Option<Pointing>,
    corroborated: bool,
    /// When the frame's exposure ended, on the watch's clock.
    ended_secs: f64,
    pier_side: Option<String>,
}

/// The per-run frame judge.
pub struct FrameWatch {
    config: FrameWatchConfig,
    baselines: HashMap<String, FilterBaseline>,
    backgrounds: HashMap<String, VecDeque<f64>>,
    target: Option<String>,
    streak: Vec<StreakFrame>,
    /// Clean frames in a row since the last collapsed one of the streak.
    clean_run: usize,
    told_possible: bool,
    /// An obstruction was confirmed once and nothing else in the plan is up:
    /// the night ends only when a second check confirms it.
    confirmed_once: Option<Pointing>,
    probe_pending: bool,
    obstructed_from: Option<Pointing>,
    frames_seen: u64,
    cloud_backoff_until: u64,
    recenter_pending: bool,
    recentered_at_secs: Option<f64>,
}

impl FrameWatch {
    pub fn new(config: FrameWatchConfig) -> Self {
        Self {
            config,
            baselines: HashMap::new(),
            backgrounds: HashMap::new(),
            target: None,
            streak: Vec::new(),
            clean_run: 0,
            told_possible: false,
            confirmed_once: None,
            probe_pending: false,
            obstructed_from: None,
            frames_seen: 0,
            cloud_backoff_until: 0,
            recenter_pending: false,
            recentered_at_secs: None,
        }
    }

    pub fn config(&self) -> &FrameWatchConfig {
        &self.config
    }

    /// Add an obstruction point to the horizon this run judges with.
    pub fn learn(&mut self, point: HorizonPoint) {
        self.config.learned_horizon.push(point);
    }

    /// A recenter asked for by [`WatchAction::Recenter`] finished (or gave
    /// up) at `at_secs`. An off-target frame that began after it may ask
    /// again.
    pub fn recentered(&mut self, at_secs: f64) {
        self.recenter_pending = false;
        self.recentered_at_secs = Some(at_secs);
    }

    /// The save paths of the current run of collapsed frames.
    pub fn streak_paths(&self) -> Vec<String> {
        self.streak.iter().map(|f| f.save_path.clone()).collect()
    }

    /// Report the probe a [`WatchAction::Probe`] asked for: `stars_found` is
    /// whether the sky higher up gave a solvable frame. Stars there mean the
    /// target sits behind an obstruction; none means cloud, and no further
    /// probe is tried for [`CLOUD_BACKOFF_FRAMES`] frames.
    pub fn probe_result(&mut self, stars_found: bool) -> Option<WatchAction> {
        self.probe_pending = false;
        if !stars_found {
            self.cloud_backoff_until = self.frames_seen + CLOUD_BACKOFF_FRAMES;
            return None;
        }
        let onset = self.streak.iter().find_map(|f| f.at)?;
        self.obstructed_from = Some(onset);
        Some(WatchAction::Obstruction {
            onset,
            learned: false,
        })
    }

    /// An obstruction confirmed by a probe would end the night (nothing else
    /// in the plan is up). One 10 s probe into a gap in passing cloud is not
    /// enough for that: the first confirmation only starts a second watch,
    /// with a new run of collapsed frames and a new probe. Returns whether
    /// the night may end now, which is on the second confirmation.
    pub fn confirm_before_ending(&mut self) -> bool {
        if self.confirmed_once.is_some() {
            return true;
        }
        self.confirmed_once = self.obstructed_from.take();
        self.reset_streak();
        false
    }

    pub fn observe(&mut self, obs: &FrameObservation) -> FrameVerdict {
        if obs.target_name != self.target {
            self.target = obs.target_name.clone();
            self.reset_streak();
            self.obstructed_from = None;
            self.confirmed_once = None;
            self.recenter_pending = false;
        }
        self.frames_seen += 1;
        let mut verdict = FrameVerdict::default();
        let key = filter_baseline_key(obs.target_name.as_deref(), obs.filter.as_deref());

        self.judge_position(obs, &mut verdict);

        let expected = self
            .baselines
            .get(&key)
            .and_then(|b| b.star_count_at(obs.altitude_deg));
        verdict.star_ratio = match (obs.star_count, expected) {
            (Some(count), Some(expected)) if expected > 0.0 => Some(f64::from(count) / expected),
            _ => None,
        };
        verdict.collapsed = obs.star_count.is_some_and(|n| n < MIN_USABLE_STARS)
            || verdict.star_ratio.is_some_and(|r| r < COLLAPSE_RATIO);
        verdict.trailed = obs.trailed();

        let background_shifted = self.background_shifted(&key, obs.background_adu);
        let trailed = verdict.trailed
            || obs
                .grader_reason
                .as_deref()
                .is_some_and(|r| r.contains("eccentricity"));
        if !verdict.collapsed && !verdict.off_target && obs.accepted_by_grader {
            self.baselines.entry(key.clone()).or_default().record(
                obs.star_count,
                obs.hfr,
                obs.altitude_deg,
            );
            if let Some(bg) = obs.background_adu.filter(|b| b.is_finite() && *b > 0.0) {
                let window = self.backgrounds.entry(key).or_default();
                window.push_back(bg);
                while window.len() > crate::quality::filter_baseline::BASELINE_WINDOW {
                    window.pop_front();
                }
            }
        }

        if self.config.obstruction_detection && obs.target_name.is_some() {
            self.judge_obstruction(obs, background_shifted, &mut verdict);
        }

        verdict.degraded = if verdict.obstructed {
            Some("the target is behind an obstruction".to_string())
        } else if verdict.collapsed {
            Some("the last frame lost most of its stars".to_string())
        } else if verdict.off_target {
            Some("the last frame was off target".to_string())
        } else if trailed {
            Some("the last frame's stars were trailed".to_string())
        } else {
            None
        };
        verdict
    }

    fn judge_position(&mut self, obs: &FrameObservation, verdict: &mut FrameVerdict) {
        let SolveOutcome::Solved {
            ra_deg, dec_deg, ..
        } = obs.solve
        else {
            return;
        };
        let (Some(target_ra), Some(target_dec)) = (obs.target_ra_deg, obs.target_dec_deg) else {
            return;
        };
        let offset = angular_separation_deg(ra_deg, dec_deg, target_ra, target_dec) * 60.0;
        verdict.offset_arcmin = Some(offset);
        if self.config.drift_limit_fraction <= 0.0 {
            return;
        }
        let Some(field) = obs.field_short_side_arcmin.filter(|f| *f > 0.0) else {
            return;
        };
        let limit = self.config.drift_limit_fraction * field;
        verdict.drift_limit_arcmin = Some(limit);
        if offset <= limit {
            return;
        }
        verdict.off_target = true;
        verdict.exclusion_reason = Some(format!(
            "{OFF_TARGET_PREFIX} center {offset:.1} arcmin from the target (limit {limit:.1} arcmin)"
        ));
        let began_after_last_recenter = self
            .recentered_at_secs
            .is_none_or(|at| obs.exposure_started_secs >= at);
        if !self.recenter_pending && began_after_last_recenter {
            self.recenter_pending = true;
            verdict.actions.push(WatchAction::Recenter {
                offset_arcmin: offset,
                limit_arcmin: limit,
            });
        }
    }

    fn judge_obstruction(
        &mut self,
        obs: &FrameObservation,
        background_shifted: bool,
        verdict: &mut FrameVerdict,
    ) {
        if let Some(onset) = self.obstructed_from {
            if verdict.collapsed {
                verdict.obstructed = true;
                verdict.exclusion_reason = Some(obstructed_reason(onset));
            }
            return;
        }
        // Trails say the mount, not the sky: such a frame neither extends nor
        // ends a run of collapsed frames.
        if verdict.trailed {
            return;
        }
        let ended_secs = obs.exposure_started_secs + obs.exposure_secs;
        if let Some(last) = self.streak.last() {
            let gap_limit = (STREAK_GAP_EXPOSURES * obs.exposure_secs).max(STREAK_MIN_GAP_SECS);
            let paused = obs.exposure_started_secs - last.ended_secs > gap_limit;
            let flipped = obs.pier_side.is_some()
                && last.pier_side.is_some()
                && obs.pier_side != last.pier_side;
            if paused || flipped {
                self.reset_streak();
            }
        }
        if !verdict.collapsed {
            if self.streak.is_empty() {
                return;
            }
            // A partly blocked frame keeps the run going; only clean frames
            // in a row end it.
            let clean = verdict.star_ratio.is_none_or(|r| r >= RECOVERED_RATIO);
            self.clean_run = if clean { self.clean_run + 1 } else { 0 };
            if self.clean_run >= CLEAN_FRAMES_TO_RECOVER {
                if self.told_possible {
                    verdict.actions.push(WatchAction::Recovered {
                        frames: self.streak.len(),
                    });
                }
                self.reset_streak();
                self.confirmed_once = None;
            }
            return;
        }

        self.clean_run = 0;
        self.streak.push(StreakFrame {
            save_path: obs.save_path.clone(),
            at: obs.pointing(),
            corroborated: obs.solve.failed() || obs.guiding_lost || background_shifted,
            ended_secs,
            pier_side: obs.pier_side.clone(),
        });
        let frames = self.streak.len();
        let at = obs.pointing();

        if let Some(at) = at {
            if frames >= POSSIBLE_OBSTRUCTION_FRAMES
                && self
                    .config
                    .learned_obstruction_at(at.altitude_deg, at.azimuth_deg)
                    .is_some()
            {
                let onset = self.streak.iter().find_map(|f| f.at).unwrap_or(at);
                self.obstructed_from = Some(onset);
                verdict.obstructed = true;
                verdict.exclusion_reason = Some(obstructed_reason(onset));
                verdict.actions.push(WatchAction::Obstruction {
                    onset,
                    learned: true,
                });
                return;
            }
        }

        if frames >= POSSIBLE_OBSTRUCTION_FRAMES && !self.told_possible {
            if let Some(at) = at {
                self.told_possible = true;
                verdict
                    .actions
                    .push(WatchAction::PossibleObstructionOrCloud { at, frames });
            }
        }

        if frames >= OBSTRUCTION_FRAMES
            && !self.probe_pending
            && self.frames_seen >= self.cloud_backoff_until
        {
            let corroborating = self.streak.iter().filter(|f| f.corroborated).count();
            let first_alt = self
                .streak
                .iter()
                .find_map(|f| f.at)
                .map(|p| p.altitude_deg);
            let setting = match (first_alt, at) {
                (Some(first), Some(now)) => now.altitude_deg < first - SETTING_MIN_DROP_DEG,
                _ => false,
            };
            if corroborating >= OBSTRUCTION_CORROBORATING_FRAMES && setting {
                if let Some(onset) = self.streak.iter().find_map(|f| f.at) {
                    self.probe_pending = true;
                    verdict.actions.push(WatchAction::Probe { onset });
                }
            }
        }
    }

    fn background_shifted(&self, key: &str, background: Option<f64>) -> bool {
        let Some(bg) = background.filter(|b| b.is_finite() && *b > 0.0) else {
            return false;
        };
        let Some(window) = self.backgrounds.get(key) else {
            return false;
        };
        if window.len() < crate::quality::filter_baseline::BASELINE_MIN_SAMPLES {
            return false;
        }
        let mut sorted: Vec<f64> = window.iter().copied().collect();
        sorted.sort_by(f64::total_cmp);
        let median = sorted[sorted.len() / 2];
        median > 0.0 && (bg / median - 1.0).abs() > BACKGROUND_SHIFT
    }

    fn reset_streak(&mut self) {
        self.streak.clear();
        self.clean_run = 0;
        self.told_possible = false;
        self.probe_pending = false;
    }
}

/// The exclusion reason of a frame lost to an obstruction first seen at
/// `onset`.
pub fn obstructed_reason(onset: Pointing) -> String {
    format!(
        "{OBSTRUCTED_PREFIX} stars blocked from {} on",
        onset.describe()
    )
}

/// Great-circle distance between two equatorial positions, degrees.
pub fn angular_separation_deg(ra1: f64, dec1: f64, ra2: f64, dec2: f64) -> f64 {
    let (ra1, dec1, ra2, dec2) = (
        ra1.to_radians(),
        dec1.to_radians(),
        ra2.to_radians(),
        dec2.to_radians(),
    );
    let h = ((dec2 - dec1) / 2.0).sin().powi(2)
        + dec1.cos() * dec2.cos() * ((ra2 - ra1) / 2.0).sin().powi(2);
    (2.0 * h.sqrt().min(1.0).asin()).to_degrees()
}
