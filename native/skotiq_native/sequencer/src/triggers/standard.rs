//! The standard triggers every run starts with, and where a trigger came from.
//!
//! One row per standard trigger: its id (the wire string checkpoints, decision
//! rows and the app carry), its condition and default action, and what the
//! run's policy needs to know about it. Policy code asks the row; it never
//! compares id strings.

use super::Trigger;
use crate::recovery::RecoveryCause;
use crate::{RecoveryAction, TriggerType};

/// A trigger the run arms without the sequence asking for it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StandardTrigger {
    HfrDegraded,
    MeridianFlip,
    GuidingFailed,
    AltitudeLimit,
    WeatherUnsafe,
    TemperatureShift,
    FilterChange,
    DawnApproaching,
    MountTrackingLost,
    DomeShutterNotOpen,
    GuideStarLost,
    FocusDrift,
    DriftLimit,
    DitherInterval,
    AutofocusInterval,
}

/// The operator's park setting that decides what a parking standard trigger
/// does when it fires.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParkSetting {
    /// "Park on unsafe weather".
    OnUnsafeWeather,
    /// "Park before dawn".
    BeforeDawn,
}

/// What the run's policy knows about a standard trigger.
#[derive(Debug)]
pub struct StandardTriggerSpec {
    /// Wire id. Checkpoints, decision rows and the app match on it.
    pub id: &'static str,
    pub name: &'static str,
    pub cooldown_secs: u64,
    /// A `ParkAndAbort` fired by this trigger ends the night, not only the
    /// run: the plan's shutdown steps run after the park, and the app reads
    /// the id as the run's stop origin to start end-of-night calibration.
    pub ends_the_night: bool,
    pub park_setting: Option<ParkSetting>,
    /// The recovery the driver runs when this trigger pauses or retries. A
    /// trigger with a cause freezes the node tree for the length of the
    /// attempt ladder; one without only pauses the run for the operator.
    pub recovery_cause: Option<RecoveryCause>,
}

/// A row with no night-ending, park or recovery policy.
const fn spec(id: &'static str, name: &'static str, cooldown_secs: u64) -> StandardTriggerSpec {
    StandardTriggerSpec {
        id,
        name,
        cooldown_secs,
        ends_the_night: false,
        park_setting: None,
        recovery_cause: None,
    }
}

// An autofocus run takes 2-4 min, so a shorter cooldown would fire again
// before the previous run could settle the HFR baseline.
static HFR_DEGRADED: StandardTriggerSpec = spec("hfr_degraded", "HFR Degradation", 300);
// A flip, recenter and refocus take 5-8 min; the cooldown is the guarantee
// against a second flip.
static MERIDIAN_FLIP: StandardTriggerSpec = spec("meridian_flip", "Meridian Flip", 600);
static GUIDING_FAILED: StandardTriggerSpec = StandardTriggerSpec {
    id: "guiding_failed",
    name: "Guiding Failure",
    cooldown_secs: 60,
    ends_the_night: false,
    park_setting: None,
    recovery_cause: Some(RecoveryCause::GuideStarLost),
};
static ALTITUDE_LIMIT: StandardTriggerSpec = spec("altitude_limit", "Altitude Limit", 60);
// No cooldown: weather must fire on every poll while it is unsafe, or a brief
// clearance could let the run resume into worsening conditions.
static WEATHER_UNSAFE: StandardTriggerSpec = StandardTriggerSpec {
    id: "weather_unsafe",
    name: "Weather Unsafe",
    cooldown_secs: 0,
    ends_the_night: false,
    park_setting: Some(ParkSetting::OnUnsafeWeather),
    recovery_cause: Some(RecoveryCause::WeatherUnsafe),
};
static TEMPERATURE_SHIFT: StandardTriggerSpec = spec("temperature_shift", "Temperature Shift", 600);
static FILTER_CHANGE: StandardTriggerSpec = spec("filter_change", "Filter Change", 0);
static DAWN_APPROACHING: StandardTriggerSpec = StandardTriggerSpec {
    id: "dawn_approaching",
    name: "Dawn Approaching",
    cooldown_secs: 0,
    ends_the_night: true,
    park_setting: Some(ParkSetting::BeforeDawn),
    recovery_cause: None,
};
static MOUNT_TRACKING_LOST: StandardTriggerSpec = StandardTriggerSpec {
    id: "mount_tracking_lost",
    name: "Mount Tracking Lost",
    cooldown_secs: 60,
    ends_the_night: false,
    park_setting: None,
    recovery_cause: Some(RecoveryCause::MountTrackingLost),
};
static DOME_SHUTTER_NOT_OPEN: StandardTriggerSpec =
    spec("dome_shutter_not_open", "Dome Shutter Not Open", 0);
static GUIDE_STAR_LOST: StandardTriggerSpec = StandardTriggerSpec {
    id: "guide_star_lost",
    name: "Guide Star Lost",
    cooldown_secs: 30,
    ends_the_night: false,
    park_setting: None,
    recovery_cause: Some(RecoveryCause::GuideStarLost),
};
static FOCUS_DRIFT: StandardTriggerSpec = StandardTriggerSpec {
    id: "focus_drift",
    name: "Focus Drift",
    cooldown_secs: 600,
    ends_the_night: false,
    park_setting: None,
    recovery_cause: Some(RecoveryCause::FocusDriftCritical),
};
// Two minutes, so one recenter has time to settle.
static DRIFT_LIMIT: StandardTriggerSpec = spec("drift_limit", "Plate-Solve Drift Limit", 120);
// The two interval triggers count exposures; a time cooldown on top would
// mask the operator's cadence.
static DITHER_INTERVAL: StandardTriggerSpec = spec("dither_interval", "Dither Interval", 0);
static AUTOFOCUS_INTERVAL: StandardTriggerSpec =
    spec("autofocus_interval", "Autofocus Interval", 0);

impl StandardTrigger {
    /// Every standard trigger, in the order a run evaluates them.
    ///
    /// There is no standard humidity trigger on purpose. The humidity ceiling
    /// has one definition, the app's `maxHumidityPercent`, which reaches the
    /// run as the pushed weather verdict behind [`Self::WeatherUnsafe`]; a
    /// second threshold here would judge the same reading differently.
    pub const ALL: [StandardTrigger; 15] = [
        Self::HfrDegraded,
        Self::MeridianFlip,
        Self::GuidingFailed,
        Self::AltitudeLimit,
        Self::WeatherUnsafe,
        Self::TemperatureShift,
        Self::FilterChange,
        Self::DawnApproaching,
        Self::MountTrackingLost,
        Self::DomeShutterNotOpen,
        Self::GuideStarLost,
        Self::FocusDrift,
        Self::DriftLimit,
        Self::DitherInterval,
        Self::AutofocusInterval,
    ];

    pub fn spec(self) -> &'static StandardTriggerSpec {
        match self {
            Self::HfrDegraded => &HFR_DEGRADED,
            Self::MeridianFlip => &MERIDIAN_FLIP,
            Self::GuidingFailed => &GUIDING_FAILED,
            Self::AltitudeLimit => &ALTITUDE_LIMIT,
            Self::WeatherUnsafe => &WEATHER_UNSAFE,
            Self::TemperatureShift => &TEMPERATURE_SHIFT,
            Self::FilterChange => &FILTER_CHANGE,
            Self::DawnApproaching => &DAWN_APPROACHING,
            Self::MountTrackingLost => &MOUNT_TRACKING_LOST,
            Self::DomeShutterNotOpen => &DOME_SHUTTER_NOT_OPEN,
            Self::GuideStarLost => &GUIDE_STAR_LOST,
            Self::FocusDrift => &FOCUS_DRIFT,
            Self::DriftLimit => &DRIFT_LIMIT,
            Self::DitherInterval => &DITHER_INTERVAL,
            Self::AutofocusInterval => &AUTOFOCUS_INTERVAL,
        }
    }

    pub fn id(self) -> &'static str {
        self.spec().id
    }

    /// The standard trigger with this id, if it is one.
    pub fn from_id(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|trigger| trigger.id() == id)
    }

    /// The condition this trigger watches, with its default thresholds.
    pub fn condition(self) -> TriggerType {
        match self {
            Self::HfrDegraded => TriggerType::HfrDegraded {
                threshold_percent: 20.0,
                absolute_threshold: 0.0,
                consecutive_frames: 3,
            },
            Self::MeridianFlip => TriggerType::MeridianFlip {
                config: crate::MeridianFlipConfig::default(),
            },
            Self::GuidingFailed => TriggerType::GuidingFailed {
                rms_threshold: 2.0,
                duration_secs: 30.0,
                rms_retention_secs: crate::default_guiding_rms_retention_secs(),
            },
            Self::AltitudeLimit => TriggerType::AltitudeLimit { min_altitude: 30.0 },
            Self::WeatherUnsafe => TriggerType::WeatherUnsafe,
            Self::TemperatureShift => TriggerType::TemperatureShift { degrees: 2.0 },
            Self::FilterChange => TriggerType::FilterChange,
            // Minutes before astronomical twilight.
            Self::DawnApproaching => TriggerType::DawnApproaching {
                minutes_before: 30.0,
            },
            Self::MountTrackingLost => TriggerType::MountTrackingLost,
            Self::DomeShutterNotOpen => TriggerType::DomeShutterNotOpen,
            Self::GuideStarLost => TriggerType::GuideStarLost,
            Self::FocusDrift => TriggerType::FocusDrift {
                window_size: crate::default_focus_drift_window_size(),
                min_increasing_count: crate::default_focus_drift_min_increasing_count(),
                min_total_increase: crate::default_focus_drift_min_total_increase(),
            },
            // Small enough to catch real drift before it ruins frames, large
            // enough to ignore the jitter of an imperfect plate solve.
            Self::DriftLimit => TriggerType::DriftLimit { max_pixels: 30.0 },
            Self::DitherInterval => TriggerType::DitherInterval { every_n_frames: 5 },
            Self::AutofocusInterval => TriggerType::AutofocusInterval {
                every_n_frames: crate::default_autofocus_interval_frames(),
            },
        }
    }

    /// What this trigger does when it fires, before the operator's park and
    /// quality settings are applied.
    pub fn default_action(self) -> RecoveryAction {
        match self {
            Self::HfrDegraded
            | Self::TemperatureShift
            | Self::FocusDrift
            | Self::AutofocusInterval => RecoveryAction::Autofocus,
            Self::MeridianFlip => {
                RecoveryAction::MeridianFlip(crate::MeridianFlipConfig::default())
            }
            Self::GuidingFailed => RecoveryAction::Retry { max_attempts: 3 },
            Self::AltitudeLimit => RecoveryAction::NextTarget,
            Self::WeatherUnsafe | Self::DawnApproaching | Self::DomeShutterNotOpen => {
                RecoveryAction::ParkAndAbort
            }
            // The focus offset for the new filter is applied by the filter
            // change itself.
            Self::FilterChange => RecoveryAction::Continue,
            Self::MountTrackingLost | Self::GuideStarLost => RecoveryAction::Pause,
            Self::DriftLimit => RecoveryAction::Recenter,
            Self::DitherInterval => RecoveryAction::Dither(crate::DitherConfig::default()),
        }
    }

    /// The trigger as a run arms it.
    pub fn build(self) -> Trigger {
        let spec = self.spec();
        Trigger::new(spec.id, spec.name, self.condition(), self.default_action())
            .with_cooldown(spec.cooldown_secs)
    }
}

/// Where a trigger came from. Policy that treats the run's own triggers
/// differently from the ones a sequence declares reads this.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TriggerOrigin {
    Standard(StandardTrigger),
    /// Declared by a Recovery node in the sequence: the operator's explicit
    /// choice for that sequence.
    RecoveryNode,
    /// Anything else: an action the frame watch decided on, or a trigger
    /// built by hand.
    #[default]
    Other,
}

impl TriggerOrigin {
    pub fn standard(self) -> Option<StandardTrigger> {
        match self {
            Self::Standard(trigger) => Some(trigger),
            _ => None,
        }
    }

    pub fn is_recovery_node(self) -> bool {
        self == Self::RecoveryNode
    }
}

const RECOVERY_NODE_TRIGGER_PREFIX: &str = "recovery_node:";

/// The id of the trigger a sequence Recovery node declares.
pub fn recovery_node_trigger_id(node_id: &str) -> String {
    format!("{RECOVERY_NODE_TRIGGER_PREFIX}{node_id}")
}

/// Id the frame watch fires under when something (trees, a building) stands in
/// front of the telescope. Not a trigger in the manager; its `ParkAndAbort`
/// ends the night like the dawn trigger's.
pub const OBSTRUCTION_TRIGGER_ID: &str = "obstruction";

/// Whether a `ParkAndAbort` fired under this id ends the night rather than
/// only the run.
pub fn ends_the_night(trigger_id: &str) -> bool {
    trigger_id == OBSTRUCTION_TRIGGER_ID
        || StandardTrigger::from_id(trigger_id).is_some_and(|trigger| trigger.spec().ends_the_night)
}

/// The recovery cause a fired trigger hands to the recovery driver, or `None`
/// for a trigger with no automatic recovery (a filter change, a sequence's own
/// Recovery node, and the rest).
pub fn trigger_recovery_cause(trigger_id: &str) -> Option<RecoveryCause> {
    StandardTrigger::from_id(trigger_id).and_then(|trigger| trigger.spec().recovery_cause.clone())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The ids are the wire: checkpoints store them, decision rows carry them
    /// and the app matches on them (`eon_trigger.dart`,
    /// `run_stop_classification.dart`). A table edit must not change one.
    #[test]
    fn standard_trigger_ids_are_pinned() {
        let ids: Vec<&str> = StandardTrigger::ALL.iter().map(|t| t.id()).collect();
        assert_eq!(
            ids,
            [
                "hfr_degraded",
                "meridian_flip",
                "guiding_failed",
                "altitude_limit",
                "weather_unsafe",
                "temperature_shift",
                "filter_change",
                "dawn_approaching",
                "mount_tracking_lost",
                "dome_shutter_not_open",
                "guide_star_lost",
                "focus_drift",
                "drift_limit",
                "dither_interval",
                "autofocus_interval",
            ]
        );
        assert_eq!(OBSTRUCTION_TRIGGER_ID, "obstruction");
        assert_eq!(recovery_node_trigger_id("node-1"), "recovery_node:node-1");
    }

    #[test]
    fn standard_trigger_names_are_pinned() {
        let names: Vec<&str> = StandardTrigger::ALL.iter().map(|t| t.spec().name).collect();
        assert_eq!(
            names,
            [
                "HFR Degradation",
                "Meridian Flip",
                "Guiding Failure",
                "Altitude Limit",
                "Weather Unsafe",
                "Temperature Shift",
                "Filter Change",
                "Dawn Approaching",
                "Mount Tracking Lost",
                "Dome Shutter Not Open",
                "Guide Star Lost",
                "Focus Drift",
                "Plate-Solve Drift Limit",
                "Dither Interval",
                "Autofocus Interval",
            ]
        );
    }

    #[test]
    fn every_standard_trigger_is_found_by_its_id_and_knows_its_origin() {
        for trigger in StandardTrigger::ALL {
            assert_eq!(StandardTrigger::from_id(trigger.id()), Some(trigger));
            let built = trigger.build();
            assert_eq!(built.origin(), TriggerOrigin::Standard(trigger));
            assert_eq!(built.cooldown_secs, Some(trigger.spec().cooldown_secs));
        }
        assert_eq!(
            StandardTrigger::from_id("recovery_node:meridian_flip"),
            None
        );
    }

    #[test]
    fn only_dawn_and_an_obstruction_end_the_night() {
        let ending: Vec<&str> = StandardTrigger::ALL
            .iter()
            .map(|t| t.id())
            .filter(|id| ends_the_night(id))
            .collect();
        assert_eq!(ending, ["dawn_approaching"]);
        assert!(ends_the_night(OBSTRUCTION_TRIGGER_ID));
        assert!(!ends_the_night("recovery_node:dawn_approaching"));
    }

    #[test]
    fn park_settings_cover_weather_and_dawn_only() {
        for trigger in StandardTrigger::ALL {
            let expected = match trigger {
                StandardTrigger::WeatherUnsafe => Some(ParkSetting::OnUnsafeWeather),
                StandardTrigger::DawnApproaching => Some(ParkSetting::BeforeDawn),
                _ => None,
            };
            assert_eq!(trigger.spec().park_setting, expected, "{trigger:?}");
        }
    }
}
