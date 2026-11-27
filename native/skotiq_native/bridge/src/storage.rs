//! Profile storage layer for Equipment Profiles
//!
//! Provides JSON-based persistence for equipment profiles.

use crate::state::EquipmentProfile;
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::PathBuf;

/// Container for all profiles
#[derive(Debug, Clone, Serialize, Deserialize)]
struct ProfilesData {
    profiles: Vec<EquipmentProfile>,
}

pub struct ProfileStorage {
    storage_path: PathBuf,
}

impl ProfileStorage {
    /// Create a new profile storage
    pub fn new(storage_dir: PathBuf) -> Result<Self, String> {
        if !storage_dir.exists() {
            fs::create_dir_all(&storage_dir)
                .map_err(|e| format!("Failed to create storage directory: {}", e))?;
        }

        let storage_path = storage_dir.join("profiles.json");

        Ok(Self { storage_path })
    }

    /// Load all profiles from disk
    pub fn load_profiles(&self) -> Result<Vec<EquipmentProfile>, String> {
        if !self.storage_path.exists() {
            return Ok(Vec::new());
        }

        let data = fs::read_to_string(&self.storage_path)
            .map_err(|e| format!("Failed to read profiles file: {}", e))?;

        let profiles_data: ProfilesData = serde_json::from_str(&data)
            .map_err(|e| format!("Failed to parse profiles JSON: {}", e))?;

        Ok(profiles_data.profiles)
    }

    /// Save all profiles to disk
    fn save_profiles(&self, profiles: &[EquipmentProfile]) -> Result<(), String> {
        let profiles_data = ProfilesData {
            profiles: profiles.to_vec(),
        };

        let json = serde_json::to_string_pretty(&profiles_data)
            .map_err(|e| format!("Failed to serialize profiles: {}", e))?;

        fs::write(&self.storage_path, json)
            .map_err(|e| format!("Failed to write profiles file: {}", e))?;

        Ok(())
    }

    /// Save a single profile (creates or updates)
    pub fn save_profile(&self, profile: &EquipmentProfile) -> Result<(), String> {
        let mut profiles = self.load_profiles()?;

        profiles.retain(|p| p.id != profile.id);

        profiles.push(profile.clone());

        self.save_profiles(&profiles)
    }

    pub fn delete_profile(&self, profile_id: &str) -> Result<(), String> {
        let mut profiles = self.load_profiles()?;

        let initial_len = profiles.len();
        profiles.retain(|p| p.id != profile_id);

        if profiles.len() == initial_len {
            return Err(format!("Profile not found: {}", profile_id));
        }

        self.save_profiles(&profiles)
    }

    /// Get a specific profile by ID
    pub fn get_profile(&self, profile_id: &str) -> Result<EquipmentProfile, String> {
        let profiles = self.load_profiles()?;

        profiles
            .into_iter()
            .find(|p| p.id == profile_id)
            .ok_or_else(|| format!("Profile not found: {}", profile_id))
    }
}

// Settings storage

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ObserverLocation {
    pub latitude: f64,
    pub longitude: f64,
    pub elevation: f64,
}

/// `settings.json`: the observing site is the only value native code keeps
/// there. `theme`, `language` and `auto_connect` are still written because
/// older builds require them to read the file; nothing reads them.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct SettingsFile {
    location: Option<ObserverLocation>,
    #[serde(default = "SettingsFile::legacy_theme")]
    theme: String,
    #[serde(default = "SettingsFile::legacy_language")]
    language: String,
    #[serde(default = "SettingsFile::legacy_auto_connect")]
    auto_connect: bool,
}

impl SettingsFile {
    fn legacy_theme() -> String {
        "dark".to_string()
    }

    fn legacy_language() -> String {
        "en".to_string()
    }

    fn legacy_auto_connect() -> bool {
        true
    }
}

impl Default for SettingsFile {
    fn default() -> Self {
        Self {
            location: None,
            theme: Self::legacy_theme(),
            language: Self::legacy_language(),
            auto_connect: Self::legacy_auto_connect(),
        }
    }
}

pub struct SettingsStorage {
    storage_path: PathBuf,
}

impl SettingsStorage {
    /// Create a new settings storage
    pub fn new(storage_dir: PathBuf) -> Result<Self, String> {
        if !storage_dir.exists() {
            fs::create_dir_all(&storage_dir)
                .map_err(|e| format!("Failed to create storage directory: {}", e))?;
        }

        let storage_path = storage_dir.join("settings.json");

        Ok(Self { storage_path })
    }

    fn load(&self) -> Result<SettingsFile, String> {
        if !self.storage_path.exists() {
            return Ok(SettingsFile::default());
        }

        let data = fs::read_to_string(&self.storage_path)
            .map_err(|e| format!("Failed to read settings file: {}", e))?;

        serde_json::from_str(&data).map_err(|e| format!("Failed to parse settings JSON: {}", e))
    }

    /// The observing site the file records.
    pub fn load_location(&self) -> Result<Option<ObserverLocation>, String> {
        Ok(self.load()?.location)
    }

    /// Record `location` as the observing site, keeping the rest of the file.
    pub fn save_location(&self, location: Option<ObserverLocation>) -> Result<(), String> {
        let mut file = self.load()?;
        file.location = location;
        let json = serde_json::to_string_pretty(&file)
            .map_err(|e| format!("Failed to serialize settings: {}", e))?;

        fs::write(&self.storage_path, json)
            .map_err(|e| format!("Failed to write settings file: {}", e))?;

        Ok(())
    }
}

// Plate solver settings storage

/// Persisted plate-solver UX configuration: user-overridden executable +
/// catalog paths and the active solver preference. Lives in its own
/// `platesolver.json` so it can evolve independently of `settings.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PlateSolverPreference {
    /// User-configured ASTAP executable path. Empty string means "auto".
    #[serde(default)]
    pub astap_path: String,
    /// User-configured Astrometry.net `solve-field` path. Empty string means "auto".
    #[serde(default)]
    pub astrometry_path: String,
    /// User-configured ASTAP star catalog directory. Empty string means
    /// "look next to the executable / in well-known catalog locations".
    #[serde(default)]
    pub catalog_path: String,
    /// `"astap" | "astrometry" | "auto"`. `auto` falls back to ASTAP first,
    /// Astrometry.net second.
    #[serde(default = "default_solver_choice")]
    pub solver_choice: String,
}

fn default_solver_choice() -> String {
    "auto".to_string()
}

impl Default for PlateSolverPreference {
    fn default() -> Self {
        Self {
            astap_path: String::new(),
            astrometry_path: String::new(),
            catalog_path: String::new(),
            solver_choice: default_solver_choice(),
        }
    }
}

/// Plate-solver preference storage manager.
pub struct PlateSolverStorage {
    storage_path: PathBuf,
}

impl PlateSolverStorage {
    pub fn new(storage_dir: PathBuf) -> Result<Self, String> {
        if !storage_dir.exists() {
            fs::create_dir_all(&storage_dir)
                .map_err(|e| format!("Failed to create plate-solver storage directory: {}", e))?;
        }
        Ok(Self {
            storage_path: storage_dir.join("platesolver.json"),
        })
    }

    pub fn load(&self) -> Result<PlateSolverPreference, String> {
        if !self.storage_path.exists() {
            return Ok(PlateSolverPreference::default());
        }
        let data = fs::read_to_string(&self.storage_path)
            .map_err(|e| format!("Failed to read platesolver.json: {}", e))?;
        let pref: PlateSolverPreference = serde_json::from_str(&data)
            .map_err(|e| format!("Failed to parse platesolver.json: {}", e))?;
        Ok(pref)
    }

    pub fn save(&self, pref: &PlateSolverPreference) -> Result<(), String> {
        let json = serde_json::to_string_pretty(pref)
            .map_err(|e| format!("Failed to serialize platesolver.json: {}", e))?;
        fs::write(&self.storage_path, json)
            .map_err(|e| format!("Failed to write platesolver.json: {}", e))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    /// The file older builds wrote loads its site; saving a site keeps the
    /// keys those builds require to read the file back.
    #[test]
    fn settings_file_stays_readable_both_ways() {
        let temp_dir = TempDir::new().unwrap();
        let path = temp_dir.path().join("settings.json");
        std::fs::write(
            &path,
            r#"{"location":{"latitude":41.5,"longitude":-71.25,"elevation":30.0},
               "theme":"light","language":"de","auto_connect":false}"#,
        )
        .unwrap();
        let storage = SettingsStorage::new(temp_dir.path().to_path_buf()).unwrap();
        let site = storage.load_location().unwrap().expect("site");
        assert_eq!((site.latitude, site.longitude), (41.5, -71.25));

        storage.save_location(None).unwrap();
        let written: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(
            written,
            serde_json::json!({
                "location": null,
                "theme": "light",
                "language": "de",
                "auto_connect": false,
            })
        );

        std::fs::write(&path, r#"{"location":null}"#).unwrap();
        storage
            .save_location(Some(ObserverLocation {
                latitude: 10.0,
                longitude: 20.0,
                elevation: 0.0,
            }))
            .unwrap();
        let written: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        for key in ["theme", "language", "auto_connect"] {
            assert!(written.get(key).is_some(), "{key} missing: {written}");
        }
    }

    #[test]
    fn test_save_and_load_profile() {
        let temp_dir = TempDir::new().unwrap();
        let storage = ProfileStorage::new(temp_dir.path().to_path_buf()).unwrap();

        let profile = EquipmentProfile {
            id: "test-profile".to_string(),
            name: "Test Profile".to_string(),
            camera_id: Some("camera1".to_string()),
            mount_id: None,
            focuser_id: None,
            filter_wheel_id: None,
            guider_id: None,
            guide_camera_id: None,
            guide_focal_length_mm: None,
            rotator_id: None,
            dome_id: None,
            weather_id: None,
            safety_monitor_id: None,
            cover_calibrator_id: None,
            telescope_focal_length: 1000.0,
            telescope_aperture: 200.0,
        };

        storage.save_profile(&profile).unwrap();

        let loaded = storage.load_profiles().unwrap();
        assert_eq!(loaded.len(), 1);
        assert_eq!(loaded[0].id, "test-profile");

        let retrieved = storage.get_profile("test-profile").unwrap();
        assert_eq!(retrieved.name, "Test Profile");
    }

    #[test]
    fn test_delete_profile() {
        let temp_dir = TempDir::new().unwrap();
        let storage = ProfileStorage::new(temp_dir.path().to_path_buf()).unwrap();

        let profile = EquipmentProfile {
            id: "test-profile".to_string(),
            name: "Test Profile".to_string(),
            camera_id: None,
            mount_id: None,
            focuser_id: None,
            filter_wheel_id: None,
            guider_id: None,
            guide_camera_id: None,
            guide_focal_length_mm: None,
            rotator_id: None,
            dome_id: None,
            weather_id: None,
            safety_monitor_id: None,
            cover_calibrator_id: None,
            telescope_focal_length: 1000.0,
            telescope_aperture: 200.0,
        };

        storage.save_profile(&profile).unwrap();
        storage.delete_profile("test-profile").unwrap();

        // Should be empty
        let loaded = storage.load_profiles().unwrap();
        assert_eq!(loaded.len(), 0);
    }
}
