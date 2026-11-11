//! The operator's settings for runs, and the one path that changes them.
//!
//! [`RunConfig`] is every setting the app pushes. [`RunConfigStore`] holds the
//! current value for the executor, the run's tasks and the trigger-run
//! instructions, and [`RunConfigStore::apply`] is the only way it changes:
//! diff against the current value, store, carry each changed section to the
//! places that keep a copy derived from it, and announce each changed section
//! once. An idle executor and a running one take the same path.
//!
//! Not settings, and not here: what one start consumes ([`RunStaging`]), what
//! is read from the loaded sequence (the trigger autofocus tuning of its first
//! Autofocus node, kept beside the config because the operator's tuning takes
//! precedence over it), the live sky readings the app feeds in ([`SkyFeed`]),
//! and the defect map, which the host loads from a file and hands over whole.

use super::{ExecutorEvent, ObserverProfile, ParkPolicy, RunCell};
use crate::instructions::{DeviceRetryHandle, DeviceRetryPolicy};
use crate::node::context::{CloudMotionSnapshot, TransparencyBackupPlan};
use crate::scheduling::{
    AdaptiveExposureConfig, BudgetRegistry, BudgetRegistrySnapshot, ConditionsScore,
};
use crate::triggers::{TriggerManager, TriggerState};
use crate::{AutofocusConfig, GuiderSettle, MeridianFlipConfig, SafetyFailMode, TriggerType};
use parking_lot::RwLock as StdRwLock;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use tokio::sync::RwLock;

/// Every operator setting a run reads. A field the app has not pushed keeps
/// its default, so a partial value (or one written by an older app) loads.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct RunConfig {
    /// Dither size and settle for trigger-driven dithers and Dither nodes
    /// that carry no values of their own.
    pub dither: crate::DitherConfig,
    /// The operator's autofocus tuning for trigger-fired refocus. `None`
    /// leaves it to the sequence's first Autofocus node, then to library
    /// defaults; see [`RunConfigStore::trigger_autofocus`].
    pub autofocus: Option<AutofocusConfig>,
    /// Cadence of the standard autofocus-interval trigger. `None` keeps the
    /// trigger's own value.
    pub autofocus_interval_frames: Option<u32>,
    /// Observer location in degrees. `None` means not configured; (0, 0) is
    /// how an unset site arrives and is stored as `None`.
    pub latitude: Option<f64>,
    pub longitude: Option<f64>,
    /// Highest Sun altitude at which a light frame may be taken. Read it
    /// through [`RunConfig::max_sun_altitude`], which resolves the default.
    pub max_sun_altitude_degrees: Option<f64>,
    /// Filter name -> focus offset in steps.
    pub filter_focus_offsets: HashMap<String, i32>,
    /// What missing safety data means.
    pub safety_fail_mode: SafetyFailMode,
    /// Cadence of safety and humidity device polls. `0` is the default
    /// cadence.
    pub safety_check_interval_secs: u64,
    /// How long an unsafe verdict from the app may go without a refresh
    /// before it counts as stale. `0` is the default window.
    pub weather_verdict_staleness_secs: u64,
    /// How long the sky must read safe before a weather hold ends. `None` is
    /// [`super::DEFAULT_WEATHER_RESUME_AFTER_SAFE_SECS`].
    pub weather_resume_after_safe_secs: Option<u64>,
    /// Grading thresholds for exposures without their own. `None` turns
    /// grading off for them.
    pub default_quality_check: Option<crate::quality::ImageQualityCheck>,
    /// Where rejected frames go. `None` is a `Reject/` folder beside the
    /// frames.
    pub reject_folder_path: Option<String>,
    /// Observer and equipment names for the FITS header.
    pub observer_profile: ObserverProfile,
    /// Retry cadence and budget of the recovery ladder, and what a run that
    /// gives up may do to the rig.
    pub recovery: crate::recovery::RecoveryRuntimeConfig,
    /// Sky-brightness adaptive exposure for exposures without their own.
    pub default_adaptive_exposure: Option<AdaptiveExposureConfig>,
    /// Whether the standard weather and dawn triggers may park.
    pub park_policy: ParkPolicy,
    /// Camera and filter-wheel retries.
    pub device_retry: DeviceRetryPolicy,
    /// The operator's meridian-flip settings for the standard flip trigger.
    /// `None` leaves the trigger as it is.
    pub meridian_flip: Option<MeridianFlipConfig>,
    /// Whether a quality problem the software judges stops the run. Off by
    /// default: only a risk to the hardware stops a run by itself.
    pub stop_on_quality_problems: bool,
    /// Whether decisions are written to the replay log.
    pub decision_logging_enabled: bool,
}

impl Default for RunConfig {
    fn default() -> Self {
        Self {
            dither: crate::DitherConfig::default(),
            autofocus: None,
            autofocus_interval_frames: None,
            latitude: None,
            longitude: None,
            max_sun_altitude_degrees: None,
            filter_focus_offsets: HashMap::new(),
            safety_fail_mode: SafetyFailMode::default(),
            safety_check_interval_secs: 0,
            weather_verdict_staleness_secs: 0,
            weather_resume_after_safe_secs: None,
            default_quality_check: None,
            reject_folder_path: None,
            observer_profile: ObserverProfile::default(),
            recovery: crate::recovery::RecoveryRuntimeConfig::default(),
            default_adaptive_exposure: None,
            park_policy: ParkPolicy::default(),
            device_retry: DeviceRetryPolicy::default(),
            meridian_flip: None,
            stop_on_quality_problems: false,
            decision_logging_enabled: true,
        }
    }
}

impl RunConfig {
    /// The daylight gate's limit: the pushed value, or nautical darkness
    /// when nothing usable was pushed, so the native gate is never weaker
    /// than the app's gate it backstops.
    pub fn max_sun_altitude(&self) -> f64 {
        match self.max_sun_altitude_degrees {
            Some(degrees) if degrees.is_finite() => degrees,
            _ => crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES,
        }
    }

    /// The value as it is stored: an unset site as `None`, the safety poll
    /// cadence and the retry counts inside their limits.
    fn sanitized(mut self) -> Self {
        (self.latitude, self.longitude) =
            crate::node::context::normalized_observer_location(self.latitude, self.longitude);
        if self.safety_check_interval_secs != 0 {
            self.safety_check_interval_secs =
                super::effective_safety_check_interval_secs(self.safety_check_interval_secs);
        }
        self.device_retry = self.device_retry.clamped();
        self
    }
}

/// A part of [`RunConfig`] that changes, is carried to its derived copies and
/// is announced as one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Section {
    Dither,
    Autofocus,
    AutofocusInterval,
    Location,
    MaxSunAltitude,
    FilterOffsets,
    SafetyFailMode,
    SafetyCheckInterval,
    WeatherVerdictStaleness,
    WeatherResumeAfterSafe,
    DefaultQualityCheck,
    RejectFolderPath,
    ObserverProfile,
    Recovery,
    DefaultAdaptiveExposure,
    ParkPolicy,
    DeviceRetries,
    MeridianFlip,
    StopOnQualityProblems,
    DecisionLogging,
}

impl Section {
    const ALL: [Section; 20] = [
        Section::Dither,
        Section::Autofocus,
        Section::AutofocusInterval,
        Section::Location,
        Section::MaxSunAltitude,
        Section::FilterOffsets,
        Section::SafetyFailMode,
        Section::SafetyCheckInterval,
        Section::WeatherVerdictStaleness,
        Section::WeatherResumeAfterSafe,
        Section::DefaultQualityCheck,
        Section::RejectFolderPath,
        Section::ObserverProfile,
        Section::Recovery,
        Section::DefaultAdaptiveExposure,
        Section::ParkPolicy,
        Section::DeviceRetries,
        Section::MeridianFlip,
        Section::StopOnQualityProblems,
        Section::DecisionLogging,
    ];

    /// The name the change is announced under in
    /// [`ExecutorEvent::RuntimeConfigUpdated`].
    pub(crate) fn what(self) -> &'static str {
        match self {
            Section::Dither => "dither",
            Section::Autofocus => "autofocus",
            Section::AutofocusInterval => "autofocus_interval",
            Section::Location => "location",
            Section::MaxSunAltitude => "max_sun_altitude",
            Section::FilterOffsets => "filter_offsets",
            Section::SafetyFailMode => "safety_fail_mode",
            Section::SafetyCheckInterval => "safety_check_interval",
            Section::WeatherVerdictStaleness => "weather_verdict_staleness",
            Section::WeatherResumeAfterSafe => "weather_resume_after_safe",
            Section::DefaultQualityCheck => "default_quality_check",
            Section::RejectFolderPath => "reject_folder_path",
            Section::ObserverProfile => "observer_profile",
            Section::Recovery => "recovery_config",
            Section::DefaultAdaptiveExposure => "default_adaptive_exposure",
            Section::ParkPolicy => "park_policy",
            Section::DeviceRetries => "device_retries",
            Section::MeridianFlip => "meridian_flip_config",
            Section::StopOnQualityProblems => "stop_on_quality_problems",
            Section::DecisionLogging => "decision_logging",
        }
    }
}

/// The sections in which `new` differs from `old`.
fn changed_sections(old: &RunConfig, new: &RunConfig) -> Vec<Section> {
    // Destructured so a new field cannot be added without naming its section.
    let RunConfig {
        dither,
        autofocus,
        autofocus_interval_frames,
        latitude,
        longitude,
        max_sun_altitude_degrees,
        filter_focus_offsets,
        safety_fail_mode,
        safety_check_interval_secs,
        weather_verdict_staleness_secs,
        weather_resume_after_safe_secs,
        default_quality_check,
        reject_folder_path,
        observer_profile,
        recovery,
        default_adaptive_exposure,
        park_policy,
        device_retry,
        meridian_flip,
        stop_on_quality_problems,
        decision_logging_enabled,
    } = new;
    [
        (Section::Dither, *dither != old.dither),
        (Section::Autofocus, *autofocus != old.autofocus),
        (
            Section::AutofocusInterval,
            *autofocus_interval_frames != old.autofocus_interval_frames,
        ),
        (
            Section::Location,
            *latitude != old.latitude || *longitude != old.longitude,
        ),
        (
            Section::MaxSunAltitude,
            *max_sun_altitude_degrees != old.max_sun_altitude_degrees,
        ),
        (
            Section::FilterOffsets,
            *filter_focus_offsets != old.filter_focus_offsets,
        ),
        (
            Section::SafetyFailMode,
            *safety_fail_mode != old.safety_fail_mode,
        ),
        (
            Section::SafetyCheckInterval,
            *safety_check_interval_secs != old.safety_check_interval_secs,
        ),
        (
            Section::WeatherVerdictStaleness,
            *weather_verdict_staleness_secs != old.weather_verdict_staleness_secs,
        ),
        (
            Section::WeatherResumeAfterSafe,
            *weather_resume_after_safe_secs != old.weather_resume_after_safe_secs,
        ),
        (
            Section::DefaultQualityCheck,
            *default_quality_check != old.default_quality_check,
        ),
        (
            Section::RejectFolderPath,
            *reject_folder_path != old.reject_folder_path,
        ),
        (
            Section::ObserverProfile,
            *observer_profile != old.observer_profile,
        ),
        (Section::Recovery, *recovery != old.recovery),
        (
            Section::DefaultAdaptiveExposure,
            *default_adaptive_exposure != old.default_adaptive_exposure,
        ),
        (Section::ParkPolicy, *park_policy != old.park_policy),
        (Section::DeviceRetries, *device_retry != old.device_retry),
        (Section::MeridianFlip, *meridian_flip != old.meridian_flip),
        (
            Section::StopOnQualityProblems,
            *stop_on_quality_problems != old.stop_on_quality_problems,
        ),
        (
            Section::DecisionLogging,
            *decision_logging_enabled != old.decision_logging_enabled,
        ),
    ]
    .into_iter()
    .filter_map(|(section, changed)| changed.then_some(section))
    .collect()
}

/// When a projection runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Projection {
    /// A run is starting on trigger state that was just reset.
    Start,
    /// The operator changed a setting.
    Change,
}

/// Copies of settings that the node tree's contexts hold as shared handles.
/// A run's context takes clones of these, so a change reaches a running
/// sequence without the context being rebuilt.
#[derive(Clone)]
pub(crate) struct ConfigSlots {
    pub device_retry: DeviceRetryHandle,
    pub safety_fail_mode: Arc<StdRwLock<SafetyFailMode>>,
    pub default_adaptive_exposure: Arc<RwLock<Option<AdaptiveExposureConfig>>>,
    pub decision_logging_enabled: Arc<AtomicBool>,
}

/// The current [`RunConfig`], shared by the executor, the run's tasks and
/// the trigger-run instructions.
#[derive(Clone)]
pub struct RunConfigStore {
    inner: Arc<StoreInner>,
}

struct StoreInner {
    config: StdRwLock<RunConfig>,
    /// Autofocus tuning of the loaded sequence's first Autofocus node, read
    /// at each start.
    sequence_autofocus: StdRwLock<Option<AutofocusConfig>>,
    slots: ConfigSlots,
    /// Held across read-modify-apply so two setters cannot lose each
    /// other's change.
    applying: tokio::sync::Mutex<()>,
}

impl Default for RunConfigStore {
    fn default() -> Self {
        Self::new(RunConfig::default())
    }
}

impl RunConfigStore {
    pub fn new(config: RunConfig) -> Self {
        let config = config.sanitized();
        let slots = ConfigSlots {
            device_retry: DeviceRetryHandle::new(config.device_retry),
            safety_fail_mode: Arc::new(StdRwLock::new(config.safety_fail_mode)),
            default_adaptive_exposure: Arc::new(RwLock::new(
                config.default_adaptive_exposure.clone(),
            )),
            decision_logging_enabled: Arc::new(AtomicBool::new(config.decision_logging_enabled)),
        };
        Self {
            inner: Arc::new(StoreInner {
                config: StdRwLock::new(config),
                sequence_autofocus: StdRwLock::new(None),
                slots,
                applying: tokio::sync::Mutex::new(()),
            }),
        }
    }

    /// The current settings. Hold the guard for a field read, not across an
    /// await.
    pub fn read(&self) -> parking_lot::RwLockReadGuard<'_, RunConfig> {
        self.inner.config.read()
    }

    pub fn snapshot(&self) -> RunConfig {
        self.inner.config.read().clone()
    }

    pub(crate) fn slots(&self) -> &ConfigSlots {
        &self.inner.slots
    }

    /// The tuning a trigger-fired autofocus uses: the operator's settings
    /// when the app pushed them, else the loaded sequence's first Autofocus
    /// node, else `None` (library defaults).
    pub(crate) fn trigger_autofocus(&self) -> Option<AutofocusConfig> {
        self.inner
            .config
            .read()
            .autofocus
            .clone()
            .or_else(|| self.inner.sequence_autofocus.read().clone())
    }

    /// Record the starting sequence's own autofocus tuning.
    pub(crate) fn set_sequence_autofocus(&self, config: Option<AutofocusConfig>) {
        *self.inner.sequence_autofocus.write() = config;
    }

    /// Make `new` the settings: store it, carry each changed section to its
    /// derived copies and announce each changed section once. A value equal
    /// to the current one does nothing.
    pub(crate) async fn apply(
        &self,
        new: RunConfig,
        triggers: &Arc<RwLock<TriggerManager>>,
        run: &RunCell,
    ) {
        let _applying = self.inner.applying.lock().await;
        self.apply_locked(new, triggers, run).await;
    }

    /// Change the settings in place; see [`Self::apply`].
    pub(crate) async fn update(
        &self,
        triggers: &Arc<RwLock<TriggerManager>>,
        run: &RunCell,
        edit: impl FnOnce(&mut RunConfig),
    ) {
        let _applying = self.inner.applying.lock().await;
        let mut new = self.snapshot();
        edit(&mut new);
        self.apply_locked(new, triggers, run).await;
    }

    async fn apply_locked(
        &self,
        new: RunConfig,
        triggers: &Arc<RwLock<TriggerManager>>,
        run: &RunCell,
    ) {
        let new = new.sanitized();
        let changed = changed_sections(&self.inner.config.read(), &new);
        if changed.is_empty() {
            return;
        }
        *self.inner.config.write() = new.clone();
        self.project_slots(&new, &changed).await;
        {
            let mut manager = triggers.write().await;
            project_onto_triggers(&mut manager, &new, &changed, Projection::Change).await;
        }
        for section in changed {
            tracing::info!("Run setting changed: {}", section.what());
            run.emit(ExecutorEvent::RuntimeConfigUpdated {
                what: section.what().to_string(),
            });
        }
    }

    /// Carry every setting onto the trigger state and triggers of a run that
    /// is starting. Nothing is announced: nothing changed.
    pub(crate) async fn project_at_start(&self, manager: &mut TriggerManager) {
        let config = self.snapshot();
        project_onto_triggers(manager, &config, &Section::ALL, Projection::Start).await;
    }

    async fn project_slots(&self, config: &RunConfig, sections: &[Section]) {
        let slots = &self.inner.slots;
        for section in sections {
            match section {
                Section::DeviceRetries => slots.device_retry.set(config.device_retry),
                Section::SafetyFailMode => {
                    *slots.safety_fail_mode.write() = config.safety_fail_mode
                }
                Section::DefaultAdaptiveExposure => {
                    *slots.default_adaptive_exposure.write().await =
                        config.default_adaptive_exposure.clone()
                }
                Section::DecisionLogging => slots
                    .decision_logging_enabled
                    .store(config.decision_logging_enabled, Ordering::Relaxed),
                _ => {}
            }
        }
    }
}

/// Carry `sections` of `config` onto the standard triggers and the trigger
/// state.
async fn project_onto_triggers(
    manager: &mut TriggerManager,
    config: &RunConfig,
    sections: &[Section],
    projection: Projection,
) {
    if sections.contains(&Section::AutofocusInterval) {
        if let Some(every_n_frames) = config.autofocus_interval_frames {
            if let Some(trigger) = manager.get_trigger_mut("autofocus_interval") {
                if let TriggerType::AutofocusInterval {
                    every_n_frames: live,
                } = &mut trigger.trigger_type
                {
                    *live = every_n_frames;
                }
            }
        }
    }
    // A start leaves the flip trigger as it stands: the trigger has held the
    // operator's settings since they were pushed.
    if projection == Projection::Change && sections.contains(&Section::MeridianFlip) {
        if let Some(flip) = &config.meridian_flip {
            if !manager.set_meridian_flip_config(flip.clone()) {
                tracing::warn!(
                    "Meridian-flip settings could not be applied: no 'meridian_flip' trigger \
                     is registered. The flip would run on Rust defaults."
                );
            }
        }
    }
    let trigger_flip_settle = manager.meridian_flip_config().map(GuiderSettle::from);
    let state = manager.state();
    let mut state = state.write().await;
    project_onto_trigger_state(&mut state, config, sections, projection, trigger_flip_settle);
}

/// The one writer of the operator settings that `TriggerState` carries for
/// the trigger monitor and the instructions.
fn project_onto_trigger_state(
    state: &mut TriggerState,
    config: &RunConfig,
    sections: &[Section],
    projection: Projection,
    trigger_flip_settle: Option<GuiderSettle>,
) {
    for section in sections {
        match section {
            Section::Dither => state.dither_settle = GuiderSettle::from(&config.dither),
            Section::Location => {
                // A start with no site configured keeps the site the trigger
                // state holds (a resumed run's, restored from its checkpoint);
                // the operator clearing the site clears it here too.
                let configured = config.latitude.is_some() && config.longitude.is_some();
                if configured || projection == Projection::Change {
                    state.set_observer_location(config.latitude, config.longitude);
                }
            }
            Section::MaxSunAltitude => {
                state.set_max_sun_altitude_degrees(config.max_sun_altitude())
            }
            Section::SafetyFailMode => state.safety_fail_mode = config.safety_fail_mode,
            Section::StopOnQualityProblems => {
                state.stop_on_quality_problems = config.stop_on_quality_problems
            }
            Section::MeridianFlip => match projection {
                Projection::Start => state.guiding_settle = trigger_flip_settle,
                Projection::Change => {
                    if let Some(flip) = &config.meridian_flip {
                        state.guiding_settle = Some(GuiderSettle::from(flip));
                    }
                }
            },
            _ => {}
        }
    }
}

/// What the next start consumes and no later one sees.
#[derive(Debug, Default)]
pub(crate) struct RunStaging {
    /// The operator's Resume / Restart choice from the session-handoff
    /// dialog: `target_id` -> `filter` -> seconds already captured. Resume
    /// carries the earlier totals, Restart an empty map for the target, and
    /// a target with no entry keeps what the run would otherwise start with.
    pub integration_carry_over: HashMap<String, HashMap<String, f64>>,
}

impl RunStaging {
    /// Give the starting run its per-target integration accounting.
    ///
    /// The checkpoint's accounting goes in first and the operator's choice
    /// on top of it, target by target. `restore_snapshot` replaces the whole
    /// registry, so the other order would discard the operator's choice on
    /// every checkpoint resume.
    pub(crate) async fn seed_budget(
        self,
        registry: &BudgetRegistry,
        checkpoint: Option<BudgetRegistrySnapshot>,
    ) {
        if let Some(snapshot) = checkpoint {
            registry.restore_snapshot(snapshot).await;
        }
        for (target_id, per_filter) in self.integration_carry_over {
            tracing::info!(
                "Seeding integration carry-over for target_id={} ({} filter entries)",
                target_id,
                per_filter.len()
            );
            registry.seed_carry_over(&target_id, per_filter).await;
        }
    }
}

/// Live sky readings the app pushes: a feed, not settings. Each setter
/// writes its slot directly; a run's context takes clones of the slots.
#[derive(Clone)]
pub(crate) struct SkyFeed {
    pub sky_brightness_mag: Arc<RwLock<Option<f64>>>,
    pub cloud_motion: Arc<RwLock<CloudMotionSnapshot>>,
    pub transparency: Arc<RwLock<Option<f64>>>,
    pub transparency_backup: Arc<RwLock<Option<TransparencyBackupPlan>>>,
    pub conditions_score: Arc<RwLock<Option<ConditionsScore>>>,
}

impl SkyFeed {
    pub(crate) fn new() -> Self {
        Self {
            sky_brightness_mag: Arc::new(RwLock::new(None)),
            cloud_motion: Arc::new(RwLock::new(CloudMotionSnapshot::default())),
            transparency: Arc::new(RwLock::new(None)),
            transparency_backup: Arc::new(RwLock::new(None)),
            conditions_score: Arc::new(RwLock::new(None)),
        }
    }

    /// A run starts without the readings taken for the run before it. The
    /// conditions score and the backup plan carry over.
    pub(crate) async fn begin_run(&self) {
        *self.sky_brightness_mag.write().await = None;
        *self.cloud_motion.write().await = CloudMotionSnapshot::default();
        *self.transparency.write().await = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::broadcast;

    struct Rig {
        store: RunConfigStore,
        triggers: Arc<RwLock<TriggerManager>>,
        run: RunCell,
        events: broadcast::Receiver<ExecutorEvent>,
    }

    fn rig() -> Rig {
        let (tx, events) = broadcast::channel(64);
        let mut manager = TriggerManager::new();
        manager.create_standard_triggers();
        Rig {
            store: RunConfigStore::default(),
            triggers: Arc::new(RwLock::new(manager)),
            run: RunCell::new(tx),
            events,
        }
    }

    impl Rig {
        async fn update(&self, edit: impl FnOnce(&mut RunConfig)) {
            self.store.update(&self.triggers, &self.run, edit).await;
        }

        fn announced(&mut self) -> Vec<String> {
            let mut out = Vec::new();
            while let Ok(event) = self.events.try_recv() {
                if let ExecutorEvent::RuntimeConfigUpdated { what } = event {
                    out.push(what);
                }
            }
            out
        }

        async fn trigger_state<R>(&self, read: impl FnOnce(&TriggerState) -> R) -> R {
            let state = self.triggers.read().await.state();
            let state = state.read().await;
            read(&state)
        }
    }

    #[tokio::test]
    async fn a_change_is_announced_once_and_an_equal_value_not_at_all() {
        let mut rig = rig();
        rig.update(|config| config.dither.pixels = 7.5).await;
        assert_eq!(rig.announced(), vec!["dither"]);

        rig.update(|config| config.dither.pixels = 7.5).await;
        assert!(rig.announced().is_empty());
    }

    #[tokio::test]
    async fn one_apply_announces_each_changed_section() {
        let mut rig = rig();
        let mut config = rig.store.snapshot();
        config.latitude = Some(41.5);
        config.longitude = Some(-71.25);
        config.park_policy.park_before_dawn = false;
        rig.store.apply(config, &rig.triggers, &rig.run).await;

        assert_eq!(rig.announced(), vec!["location", "park_policy"]);
    }

    #[tokio::test]
    async fn the_max_sun_altitude_default_is_resolved_in_one_place() {
        let rig = rig();
        for unusable in [None, Some(f64::NAN), Some(f64::INFINITY)] {
            let config = RunConfig {
                max_sun_altitude_degrees: unusable,
                ..RunConfig::default()
            };
            assert_eq!(
                config.max_sun_altitude(),
                crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES
            );
        }

        rig.update(|config| config.max_sun_altitude_degrees = Some(-6.0))
            .await;
        assert_eq!(rig.store.read().max_sun_altitude(), -6.0);
        assert_eq!(
            rig.trigger_state(|state| state.max_sun_altitude_degrees)
                .await,
            Some(-6.0)
        );

        rig.update(|config| config.max_sun_altitude_degrees = None)
            .await;
        assert_eq!(
            rig.trigger_state(|state| state.max_sun_altitude_degrees)
                .await,
            Some(crate::instructions::DEFAULT_MAX_SUN_ALTITUDE_DEGREES)
        );
    }

    #[tokio::test]
    async fn settings_reach_the_trigger_state_and_the_context_slots() {
        let rig = rig();
        rig.update(|config| {
            config.dither.settle_pixels = 0.5;
            config.dither.settle_time = 8.0;
            config.dither.settle_timeout = 60.0;
            config.stop_on_quality_problems = true;
            config.safety_fail_mode = SafetyFailMode::WarnOnly;
            config.device_retry = DeviceRetryPolicy {
                camera_retries: 1,
                filter_wheel_retries: 99,
            };
            config.decision_logging_enabled = false;
            config.autofocus_interval_frames = Some(40);
        })
        .await;

        let (settle, stops, fail_mode) = rig
            .trigger_state(|state| {
                (
                    state.dither_settle,
                    state.stop_on_quality_problems,
                    state.safety_fail_mode,
                )
            })
            .await;
        assert_eq!(
            settle,
            GuiderSettle {
                pixels: 0.5,
                time_secs: 8.0,
                timeout_secs: 60.0
            }
        );
        assert!(stops);
        assert_eq!(fail_mode, SafetyFailMode::WarnOnly);

        let slots = rig.store.slots();
        assert_eq!(*slots.safety_fail_mode.read(), SafetyFailMode::WarnOnly);
        assert_eq!(
            slots.device_retry.get(),
            DeviceRetryPolicy {
                camera_retries: 1,
                filter_wheel_retries: crate::instructions::MAX_DEVICE_RETRIES,
            }
        );
        assert!(!slots.decision_logging_enabled.load(Ordering::Relaxed));

        let manager = rig.triggers.read().await;
        let interval = manager
            .triggers()
            .iter()
            .find(|trigger| trigger.id == "autofocus_interval")
            .map(|trigger| trigger.trigger_type.clone());
        assert!(matches!(
            interval,
            Some(TriggerType::AutofocusInterval { every_n_frames: 40 })
        ));
    }

    #[tokio::test]
    async fn a_start_keeps_the_trigger_states_site_when_none_is_configured() {
        let rig = rig();
        {
            let mut manager = rig.triggers.write().await;
            manager
                .state()
                .write()
                .await
                .set_observer_location(Some(45.5), Some(-122.6));
            rig.store.project_at_start(&mut manager).await;
        }
        assert_eq!(
            rig.trigger_state(|state| (state.observer_latitude, state.observer_longitude))
                .await,
            (Some(45.5), Some(-122.6))
        );

        // The operator clearing the site is a change, and clears it.
        rig.update(|config| {
            config.latitude = Some(10.0);
            config.longitude = Some(20.0);
        })
        .await;
        rig.update(|config| {
            config.latitude = None;
            config.longitude = None;
        })
        .await;
        assert_eq!(
            rig.trigger_state(|state| (state.observer_latitude, state.observer_longitude))
                .await,
            (None, None)
        );
    }

    #[tokio::test]
    async fn the_operators_autofocus_tuning_takes_precedence_over_the_sequences() {
        let rig = rig();
        assert!(rig.store.trigger_autofocus().is_none());

        let from_node = AutofocusConfig {
            step_size: 55,
            ..AutofocusConfig::default()
        };
        rig.store.set_sequence_autofocus(Some(from_node));
        assert_eq!(rig.store.trigger_autofocus().map(|c| c.step_size), Some(55));

        let from_operator = AutofocusConfig {
            step_size: 80,
            ..AutofocusConfig::default()
        };
        rig.update(|config| config.autofocus = Some(from_operator))
            .await;
        assert_eq!(rig.store.trigger_autofocus().map(|c| c.step_size), Some(80));

        // The next sequence has no Autofocus node: the operator's tuning
        // stays, and the earlier sequence's does not come back.
        rig.store.set_sequence_autofocus(None);
        assert_eq!(rig.store.trigger_autofocus().map(|c| c.step_size), Some(80));
    }

    #[test]
    fn a_config_with_missing_fields_loads_with_defaults() {
        let partial: RunConfig =
            serde_json::from_str(r#"{"latitude": 41.5, "park_policy": {"park_before_dawn": false}}"#)
                .expect("a partial config loads");
        assert_eq!(partial.latitude, Some(41.5));
        assert!(!partial.park_policy.park_before_dawn);
        assert!(partial.park_policy.park_on_unsafe_weather);
        assert!(partial.decision_logging_enabled);
        assert_eq!(
            RunConfig {
                latitude: None,
                park_policy: ParkPolicy::default(),
                ..partial
            },
            RunConfig::default()
        );

        let empty: RunConfig = serde_json::from_str("{}").expect("an empty config loads");
        assert_eq!(empty, RunConfig::default());
    }

    #[test]
    fn a_config_survives_a_round_trip() {
        let config = RunConfig {
            latitude: Some(41.5),
            longitude: Some(-71.25),
            max_sun_altitude_degrees: Some(-8.0),
            filter_focus_offsets: HashMap::from([("Ha".to_string(), 250)]),
            safety_fail_mode: SafetyFailMode::FailOpen,
            autofocus: Some(AutofocusConfig::default()),
            autofocus_interval_frames: Some(12),
            meridian_flip: Some(MeridianFlipConfig::default()),
            stop_on_quality_problems: true,
            decision_logging_enabled: false,
            device_retry: DeviceRetryPolicy {
                camera_retries: 5,
                filter_wheel_retries: 0,
            },
            ..RunConfig::default()
        };
        let json = serde_json::to_string(&config).expect("serializes");
        let back: RunConfig = serde_json::from_str(&json).expect("deserializes");
        assert_eq!(back, config);
    }
}
