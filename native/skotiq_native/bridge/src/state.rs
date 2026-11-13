//! Global state management for the Skotiq application
//!
//! This module maintains the application state and provides
//! thread-safe access to it from multiple components.

use crate::device::DeviceType;
use crate::event::bus::{EventBus, EventPayload, SkotiqEvent};
use crate::event::correlation::SharedEventBus;
use crate::event::equipment::{EquipmentEvent, EventCategory, EventSeverity};
use crate::event::guiding::GuidingEvent;
use crate::event::imaging::ImagingEvent;
use crate::event::system::{SafetyEvent, SystemEvent};
use crate::storage::{
    AppSettings, ObserverLocation, PlateSolverPreference, PlateSolverStorage, ProfileStorage,
    SettingsStorage,
};
use std::sync::{Arc, OnceLock};
use tokio::sync::RwLock;

pub struct AppState {
    /// Event bus for publishing/subscribing to events
    pub event_bus: SharedEventBus,

    profile: RwLock<Option<EquipmentProfile>>,

    /// Observer location (in-memory, synced from Dart on startup/change)
    /// This is the single source of truth for location during runtime
    ///
    /// Guarded by a *sync* lock, unlike the fields above: reads must never be
    /// allowed to give up and report "no site" (see `get_observer_location`).
    observer_location: std::sync::RwLock<Option<ObserverLocation>>,
}

static PROFILE_STORAGE: OnceLock<ProfileStorage> = OnceLock::new();

/// Initialize profile storage
pub fn init_profile_storage(storage_dir: std::path::PathBuf) -> Result<(), String> {
    let storage = ProfileStorage::new(storage_dir)?;
    PROFILE_STORAGE
        .set(storage)
        .map_err(|_| "Profile storage already initialized".to_string())
}

fn get_profile_storage() -> Result<&'static ProfileStorage, String> {
    PROFILE_STORAGE
        .get()
        .ok_or_else(|| "Profile storage not initialized".to_string())
}

static SETTINGS_STORAGE: OnceLock<SettingsStorage> = OnceLock::new();

pub fn init_settings_storage(storage_dir: std::path::PathBuf) -> Result<(), String> {
    let storage = SettingsStorage::new(storage_dir)?;
    SETTINGS_STORAGE
        .set(storage)
        .map_err(|_| "Settings storage already initialized".to_string())
}

fn get_settings_storage() -> Result<&'static SettingsStorage, String> {
    SETTINGS_STORAGE
        .get()
        .ok_or_else(|| "Settings storage not initialized".to_string())
}

/// Global plate-solver preference storage. Shares the settings directory so
/// callers only need to initialise one storage root.
static PLATESOLVER_STORAGE: OnceLock<PlateSolverStorage> = OnceLock::new();

pub fn init_platesolver_storage(storage_dir: std::path::PathBuf) -> Result<(), String> {
    let storage = PlateSolverStorage::new(storage_dir)?;
    PLATESOLVER_STORAGE
        .set(storage)
        .map_err(|_| "Plate-solver storage already initialized".to_string())
}

fn get_platesolver_storage() -> Result<&'static PlateSolverStorage, String> {
    PLATESOLVER_STORAGE
        .get()
        .ok_or_else(|| "Plate-solver storage not initialized".to_string())
}

pub fn get_platesolver_preference() -> Result<PlateSolverPreference, String> {
    get_platesolver_storage()?.load()
}

pub fn save_platesolver_preference(pref: &PlateSolverPreference) -> Result<(), String> {
    get_platesolver_storage()?.save(pref)
}

/// Equipment profile containing device selections
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct EquipmentProfile {
    pub id: String,
    pub name: String,
    pub camera_id: Option<String>,
    pub mount_id: Option<String>,
    pub focuser_id: Option<String>,
    pub filter_wheel_id: Option<String>,
    pub guider_id: Option<String>,
    /// Camera the built-in guider takes its frames with. Never the imaging
    /// camera.
    #[serde(default)]
    pub guide_camera_id: Option<String>,
    /// Focal length of the guide scope, in millimeters. `None` for an
    /// off-axis guider, which shares the telescope's focal length.
    #[serde(default)]
    pub guide_focal_length_mm: Option<f64>,
    pub rotator_id: Option<String>,
    pub dome_id: Option<String>,
    pub weather_id: Option<String>,
    #[serde(default)]
    pub safety_monitor_id: Option<String>,
    pub cover_calibrator_id: Option<String>,
    pub telescope_focal_length: f64,
    pub telescope_aperture: f64,
}

impl AppState {
    /// Create a new application state
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            event_bus: Arc::new(EventBus::new(crate::event::bus::DEFAULT_EVENT_BUFFER_SIZE)),
            profile: RwLock::new(None),
            observer_location: std::sync::RwLock::new(None),
        })
    }

    pub async fn get_profile(&self) -> Option<EquipmentProfile> {
        self.profile.read().await.clone()
    }

    pub async fn set_profile(&self, profile: Option<EquipmentProfile>) {
        let mut p = self.profile.write().await;
        *p = profile;
    }

    /// Load all profiles from storage
    pub fn load_profiles(&self) -> Result<Vec<EquipmentProfile>, String> {
        get_profile_storage()?.load_profiles()
    }

    pub fn save_profile_to_storage(&self, profile: &EquipmentProfile) -> Result<(), String> {
        get_profile_storage()?.save_profile(profile)
    }

    pub fn delete_profile_from_storage(&self, profile_id: &str) -> Result<(), String> {
        get_profile_storage()?.delete_profile(profile_id)
    }

    /// Load a specific profile from storage and set it as active
    pub async fn load_and_set_profile(&self, profile_id: &str) -> Result<(), String> {
        let profile = get_profile_storage()?.get_profile(profile_id)?;

        self.set_profile(Some(profile)).await;
        Ok(())
    }

    pub fn get_settings(&self) -> Result<AppSettings, String> {
        get_settings_storage()?.load_settings()
    }

    pub fn update_settings(&self, settings: &AppSettings) -> Result<(), String> {
        get_settings_storage()?.save_settings(settings)
    }

    /// Get observer location from in-memory state
    /// This is the primary accessor - reads from runtime state, not file
    /// `None` means exactly one thing: this user has no observing site on
    /// record. Every native consumer treats it that way — polar alignment
    /// refuses to run, the sequencer skips altitude/meridian maths, FITS
    /// headers omit SITELAT/SITELONG — so `None` must never be an answer this
    /// method invents. In particular lock contention is not `None`: a failed
    /// `try_read` would make a writer holding the lock for a microsecond
    /// indistinguishable from a user who never set a site, at exactly the
    /// moment (settings sync) when a writer is there.
    pub fn get_observer_location(&self) -> Result<Option<ObserverLocation>, String> {
        let location = self.read_observer_location().clone();
        match &location {
            Some(loc) => {
                tracing::debug!(
                    "Retrieved observer location: lat={}, lon={}, elev={}",
                    loc.latitude,
                    loc.longitude,
                    loc.elevation
                );
            }
            None => {
                tracing::debug!("Observer location is not set");
            }
        }
        Ok(location)
    }

    /// Borrow the stored site, waiting for any in-flight write.
    ///
    /// A plain (non-async) lock is deliberate. Every critical section on this
    /// field is a single clone or assignment with no `.await` inside it, so
    /// waiting costs nanoseconds and cannot deadlock a runtime worker — whereas
    /// the async lock's non-blocking escapes both had to invent an answer when
    /// they lost the race (see [`Self::get_observer_location`]) or fall back to
    /// `blocking_write()`, which panics outright when called from inside a
    /// Tokio runtime, as the sequencer and mount device-ops paths do.
    fn read_observer_location(&self) -> std::sync::RwLockReadGuard<'_, Option<ObserverLocation>> {
        // The guarded value is a plain `Option`; a panic elsewhere cannot leave
        // it half-written, so recover from poisoning instead of propagating it.
        self.observer_location
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn write_observer_location(&self) -> std::sync::RwLockWriteGuard<'_, Option<ObserverLocation>> {
        self.observer_location
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Set observer location in-memory and optionally persist to file
    /// This updates the runtime state that all components use
    ///
    /// `None` is the only way to say "this user has no observing site", and
    /// callers that don't have one MUST pass it. There is no coordinate that
    /// means "unset": (0, 0) is a real point in the Gulf of Guinea, and every
    /// native consumer reads a `Some` as a site the user chose. Handing this a
    /// placeholder triple silently defeats guards that exist precisely to stop
    /// site-dependent work — polar alignment's "set your site location before
    /// starting" refusal, the sequencer's altitude/meridian maths, and the
    /// SITELAT/SITELONG in every FITS header — because a fabricated site is
    /// indistinguishable from a real one once it is in here. It also persists,
    /// so one bad write outlives the launch that made it.
    pub fn set_observer_location(&self, location: Option<ObserverLocation>) -> Result<(), String> {
        match &location {
            Some(loc) => {
                tracing::info!(
                    "Setting observer location: lat={}, lon={}, elev={}",
                    loc.latitude,
                    loc.longitude,
                    loc.elevation
                );
            }
            None => {
                tracing::info!("Clearing observer location");
            }
        }

        // Update in-memory state (this is the primary source of truth at runtime)
        {
            let mut loc_guard = self.write_observer_location();
            *loc_guard = location.clone();
        }
        tracing::debug!("Observer location updated in memory");

        // Also persist to settings file if storage is initialized (best-effort)
        if let Ok(mut settings) = self.get_settings() {
            settings.location = location;
            if let Err(e) = self.update_settings(&settings) {
                tracing::warn!("Failed to persist observer location to file: {}", e);
                // Don't fail - in-memory state is already updated
            } else {
                tracing::debug!("Observer location persisted to file");
            }
        }

        Ok(())
    }

    /// Load observer location from persisted settings into in-memory state
    /// Call this at startup after settings storage is initialized
    ///
    /// "No site in settings" loads as no site. Skipping the write in that case
    /// would let a site from a previous profile or a previous run outlive the
    /// settings that named it, and absence is the one state whose whole job is
    /// to survive.
    pub fn load_observer_location_from_settings(&self) {
        if let Ok(settings) = self.get_settings() {
            match &settings.location {
                Some(loc) => tracing::info!(
                    "Loading observer location from settings: lat={}, lon={}, elev={}",
                    loc.latitude,
                    loc.longitude,
                    loc.elevation
                ),
                None => tracing::info!("Settings have no observer location"),
            }
            let mut loc_guard = self.write_observer_location();
            *loc_guard = settings.location;
        }
    }

    // Event publishing (event bus with sequence numbers)

    /// Publish an event to the event bus
    /// Returns the event ID
    pub fn publish_event(&self, event: SkotiqEvent) -> u64 {
        self.event_bus.publish(event)
    }

    /// Create and publish a system event
    /// Returns the event ID
    pub fn publish_system_event(&self, event: SystemEvent) -> u64 {
        self.event_bus.publish_with_tracking(
            EventSeverity::Info,
            EventCategory::System,
            EventPayload::System(event),
            None,
        )
    }

    /// Create and publish an equipment event
    /// Returns the event ID
    pub fn publish_equipment_event(&self, event: EquipmentEvent, severity: EventSeverity) -> u64 {
        let device_id = event.device_id().to_string();
        self.event_bus.publish_device_event(
            severity,
            EventCategory::Equipment,
            EventPayload::Equipment(event),
            &device_id,
            None,
        )
    }

    /// Create and publish an imaging event
    /// Returns the event ID
    pub fn publish_imaging_event(&self, event: ImagingEvent, severity: EventSeverity) -> u64 {
        self.event_bus.publish_with_tracking(
            severity,
            EventCategory::Imaging,
            EventPayload::Imaging(event),
            None,
        )
    }

    /// Create and publish a guiding event
    /// Returns the event ID
    pub fn publish_guiding_event(&self, event: GuidingEvent, severity: EventSeverity) -> u64 {
        self.event_bus.publish_with_tracking(
            severity,
            EventCategory::Guiding,
            EventPayload::Guiding(event),
            None,
        )
    }

    /// Create and publish a safety event
    /// Returns the event ID
    pub fn publish_safety_event(&self, event: SafetyEvent, severity: EventSeverity) -> u64 {
        self.event_bus.publish_with_tracking(
            severity,
            EventCategory::Safety,
            EventPayload::Safety(event),
            None,
        )
    }

    /// Get the device ID from the current profile for a specific device type
    pub async fn get_profile_device_id(&self, device_type: DeviceType) -> Option<String> {
        let profile = self.profile.read().await;
        profile.as_ref().and_then(|p| match device_type {
            DeviceType::Camera => p.camera_id.clone(),
            DeviceType::Mount => p.mount_id.clone(),
            DeviceType::Focuser => p.focuser_id.clone(),
            DeviceType::FilterWheel => p.filter_wheel_id.clone(),
            DeviceType::Rotator => p.rotator_id.clone(),
            DeviceType::Dome => p.dome_id.clone(),
            DeviceType::Weather => p.weather_id.clone(),
            DeviceType::CoverCalibrator => p.cover_calibrator_id.clone(),
            DeviceType::Guider => p.guider_id.clone(),
            _ => None,
        })
    }
}

impl Default for AppState {
    fn default() -> Self {
        Self {
            event_bus: Arc::new(EventBus::new(crate::event::bus::DEFAULT_EVENT_BUFFER_SIZE)),
            profile: RwLock::new(None),
            observer_location: std::sync::RwLock::new(None),
        }
    }
}

/// Thread-safe shared application state
pub type SharedAppState = Arc<AppState>;

static APP_STATE: OnceLock<SharedAppState> = OnceLock::new();

/// The process's one application state.
pub(crate) fn get_state() -> &'static SharedAppState {
    APP_STATE.get_or_init(AppState::new)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Guard for the "no observing site" representation the whole stack depends
    /// on. Absence has to survive as absence: a launch that has never had a
    /// site must not report one, and an explicit clear must not decay into a
    /// coordinate. Every native consumer (polar alignment's refusal to run, the
    /// sequencer's altitude maths, FITS SITELAT/SITELONG) branches on this
    /// `Option` and cannot tell a fabricated site from a chosen one, so a
    /// future `unwrap_or_default()` here would be invisible everywhere else.
    #[tokio::test]
    async fn observer_location_absence_is_representable_and_survives() {
        let state = AppState::new();

        // Never configured — not 0/0, which is a real place off Africa.
        assert!(state.get_observer_location().unwrap().is_none());

        state
            .set_observer_location(Some(ObserverLocation {
                latitude: 40.71,
                longitude: -74.01,
                elevation: 10.0,
            }))
            .expect("site should be settable");
        let site = state.get_observer_location().unwrap().expect("site");
        assert_eq!(site.latitude, 40.71);
        assert_eq!(site.longitude, -74.01);

        // Clearing means "no site", not "the site at 0/0".
        state
            .set_observer_location(None)
            .expect("site should be clearable");
        assert!(state.get_observer_location().unwrap().is_none());
    }

    /// The other way to fabricate a site is to fabricate its absence. A reader
    /// that loses the race with a writer must wait, not answer "no site on
    /// record" — that answer aborts polar alignment, drops SITELAT/SITELONG
    /// from the FITS header and skips meridian maths, and the settings fan-out
    /// makes a writer present at exactly the moment surfaces first ask.
    #[test]
    fn a_busy_lock_never_reports_the_site_as_unset() {
        let state = AppState::new();
        state
            .set_observer_location(Some(ObserverLocation {
                latitude: 40.71,
                longitude: -74.01,
                elevation: 10.0,
            }))
            .expect("site should be settable");

        let (locked_tx, locked_rx) = std::sync::mpsc::channel();
        let writer_state = Arc::clone(&state);
        let writer = std::thread::spawn(move || {
            let guard = writer_state.write_observer_location();
            locked_tx.send(()).expect("reader should be waiting");
            std::thread::sleep(std::time::Duration::from_millis(200));
            drop(guard);
        });
        locked_rx.recv().expect("writer should take the lock");

        let site = state
            .get_observer_location()
            .expect("read should not error")
            .expect("a held write lock is not 'the user has no site'");
        assert_eq!(site.latitude, 40.71);

        writer.join().expect("writer thread should finish");
    }
}
