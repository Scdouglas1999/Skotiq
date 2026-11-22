//! The variables a `${...}` placeholder can name.
//!
//! [`variable_catalog`] is the one list: the resolver refuses a name that is
//! not on it. A test here writes it to
//! `test_fixtures/interpolation_catalog/catalog.json`, and the app's catalog
//! (`packages/skotiq_core/lib/src/models/sequence/interpolation_catalog.dart`,
//! read by the variable picker and the notification renderer) is held to that
//! file by `interpolation_catalog_fixture_test.dart`.
//!
//! Adding a variable: declare it here, add its arm in
//! [`super::resolver::resolve_variable`], regenerate the fixture with
//! `SKOTIQ_WRITE_FIXTURES=1 cargo test -p skotiq_sequencer catalog_fixture`,
//! and copy the entry into the Dart catalog.

/// Top-level groupings shown in the Dart variable-picker UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VariableGroup {
    Target,
    Filter,
    Frame,
    Session,
    Time,
    Moon,
    Weather,
    Observer,
    Equipment,
    Exposure,
}

impl VariableGroup {
    pub fn label(self) -> &'static str {
        match self {
            VariableGroup::Target => "Target",
            VariableGroup::Filter => "Filter",
            VariableGroup::Frame => "Frame",
            VariableGroup::Session => "Session",
            VariableGroup::Time => "Time",
            VariableGroup::Moon => "Moon",
            VariableGroup::Weather => "Weather",
            VariableGroup::Observer => "Observer",
            VariableGroup::Equipment => "Equipment",
            VariableGroup::Exposure => "Exposure",
        }
    }
}

/// One entry in the catalog. Renders as a picker row.
#[derive(Debug, Clone)]
pub struct VariableEntry {
    /// The dotted name a user types inside `${...}`.
    pub name: &'static str,
    /// Human-readable description (one line, plain text).
    pub description: &'static str,
    /// Group used to bucket the variable in the picker.
    pub group: VariableGroup,
    /// Example rendered value, shown alongside the description so the user
    /// knows the shape of what they will get.
    pub example: &'static str,
    /// Whether the variable supports a numeric format spec (`.Nf` / `0N`).
    pub supports_format: bool,
}

/// The canonical variable catalog. Add new variables here AND in the
/// resolver — the tests assert the two stay in sync.
pub fn variable_catalog() -> &'static [VariableEntry] {
    &[
        // Target
        VariableEntry {
            name: "target.name",
            description: "Name of the active target (e.g. \"M42\")",
            group: VariableGroup::Target,
            example: "M42",
            supports_format: false,
        },
        VariableEntry {
            name: "target.id",
            description: "Stable internal identifier of the active target",
            group: VariableGroup::Target,
            example: "tgt-7c3a",
            supports_format: false,
        },
        VariableEntry {
            name: "target.ra",
            description: "Right ascension of the active target (hours)",
            group: VariableGroup::Target,
            example: "5.59",
            supports_format: true,
        },
        VariableEntry {
            name: "target.dec",
            description: "Declination of the active target (degrees)",
            group: VariableGroup::Target,
            example: "-5.39",
            supports_format: true,
        },
        VariableEntry {
            name: "target.rotation",
            description: "Position-angle rotation for the target (degrees)",
            group: VariableGroup::Target,
            example: "45.0",
            supports_format: true,
        },
        VariableEntry {
            name: "target.alt",
            description: "Current altitude of the target (degrees)",
            group: VariableGroup::Target,
            example: "42.7",
            supports_format: true,
        },
        VariableEntry {
            name: "target.az",
            description: "Current azimuth of the target (degrees)",
            group: VariableGroup::Target,
            example: "138.2",
            supports_format: true,
        },
        VariableEntry {
            name: "filter",
            description: "Currently selected filter name",
            group: VariableGroup::Filter,
            example: "Ha",
            supports_format: false,
        },
        VariableEntry {
            name: "filter.position",
            description: "Filter-wheel position (1-based)",
            group: VariableGroup::Filter,
            example: "3",
            supports_format: true,
        },
        // Frame counters
        VariableEntry {
            name: "frame",
            description: "Current frame number within the active burst",
            group: VariableGroup::Frame,
            example: "8",
            supports_format: true,
        },
        VariableEntry {
            name: "frame.total",
            description: "Total frames requested in the active burst",
            group: VariableGroup::Frame,
            example: "30",
            supports_format: true,
        },
        // Session
        VariableEntry {
            name: "session.id",
            description: "Unique identifier of the active imaging session",
            group: VariableGroup::Session,
            example: "5f9a-…-83b1",
            supports_format: false,
        },
        VariableEntry {
            name: "session.date",
            description: "UTC date the session started (YYYY-MM-DD)",
            group: VariableGroup::Session,
            example: "2026-01-15",
            supports_format: false,
        },
        VariableEntry {
            name: "session.start",
            description: "ISO-8601 UTC timestamp when the session started",
            group: VariableGroup::Session,
            example: "2026-01-15T22:14:33Z",
            supports_format: false,
        },
        // Time
        VariableEntry {
            name: "time.now",
            description: "Current UTC timestamp (ISO-8601)",
            group: VariableGroup::Time,
            example: "2026-01-15T22:47:12Z",
            supports_format: false,
        },
        VariableEntry {
            name: "time.local",
            description: "Current local timestamp (ISO-8601 with offset)",
            group: VariableGroup::Time,
            example: "2026-01-15 17:47:12 -05:00",
            supports_format: false,
        },
        VariableEntry {
            name: "time.date",
            description: "Current UTC date (YYYY-MM-DD)",
            group: VariableGroup::Time,
            example: "2026-01-15",
            supports_format: false,
        },
        VariableEntry {
            name: "time.clock",
            description: "Current UTC time of day, file-name safe (HH-MM-SS)",
            group: VariableGroup::Time,
            example: "22-47-12",
            supports_format: false,
        },
        VariableEntry {
            name: "time.local_clock",
            description: "Current local time of day (HH:MM)",
            group: VariableGroup::Time,
            example: "17:47",
            supports_format: false,
        },
        // Moon
        VariableEntry {
            name: "moon.phase",
            description: "Moon illuminated fraction (0.0 – 1.0)",
            group: VariableGroup::Moon,
            example: "0.42",
            supports_format: true,
        },
        VariableEntry {
            name: "moon.separation",
            description: "Angular separation between the moon and the target (degrees)",
            group: VariableGroup::Moon,
            example: "67.3",
            supports_format: true,
        },
        // Weather
        VariableEntry {
            name: "weather.temp_c",
            description: "Ambient temperature (°C) from the active weather source",
            group: VariableGroup::Weather,
            example: "12.4",
            supports_format: true,
        },
        VariableEntry {
            name: "weather.humidity",
            description: "Relative humidity percentage (0 – 100)",
            group: VariableGroup::Weather,
            example: "67",
            supports_format: true,
        },
        VariableEntry {
            name: "sqm",
            description: "Sky-quality reading (mag / arcsec²) from the active sensor",
            group: VariableGroup::Weather,
            example: "21.2",
            supports_format: true,
        },
        // Observer
        VariableEntry {
            name: "observer.name",
            description: "Observer name from app settings",
            group: VariableGroup::Observer,
            example: "Alice",
            supports_format: false,
        },
        VariableEntry {
            name: "observer.lat",
            description: "Observer latitude (degrees)",
            group: VariableGroup::Observer,
            example: "40.7128",
            supports_format: true,
        },
        VariableEntry {
            name: "observer.lon",
            description: "Observer longitude (degrees)",
            group: VariableGroup::Observer,
            example: "-74.0060",
            supports_format: true,
        },
        VariableEntry {
            name: "observer.elevation",
            description: "Observer elevation (meters)",
            group: VariableGroup::Observer,
            example: "150",
            supports_format: true,
        },
        // Equipment
        VariableEntry {
            name: "equipment.camera",
            description: "Camera make + model from the active equipment profile",
            group: VariableGroup::Equipment,
            example: "ZWO ASI2600MM",
            supports_format: false,
        },
        VariableEntry {
            name: "equipment.telescope",
            description: "Telescope name from the active equipment profile",
            group: VariableGroup::Equipment,
            example: "TS-Optics 130/910 APO",
            supports_format: false,
        },
        VariableEntry {
            name: "equipment.focal_length",
            description: "Telescope focal length (mm)",
            group: VariableGroup::Equipment,
            example: "910",
            supports_format: true,
        },
        VariableEntry {
            name: "equipment.aperture",
            description: "Telescope aperture (mm)",
            group: VariableGroup::Equipment,
            example: "130",
            supports_format: true,
        },
        // Exposure
        VariableEntry {
            name: "exposure.duration",
            description: "Exposure duration of the active burst (seconds)",
            group: VariableGroup::Exposure,
            example: "180",
            supports_format: true,
        },
        VariableEntry {
            name: "exposure.gain",
            description: "Camera gain of the active burst",
            group: VariableGroup::Exposure,
            example: "100",
            supports_format: true,
        },
        VariableEntry {
            name: "exposure.offset",
            description: "Camera offset of the active burst",
            group: VariableGroup::Exposure,
            example: "10",
            supports_format: true,
        },
        VariableEntry {
            name: "exposure.binning",
            description: "Binning of the active burst (e.g. \"1x1\")",
            group: VariableGroup::Exposure,
            example: "1x1",
            supports_format: false,
        },
        VariableEntry {
            name: "camera.temp_c",
            description: "Sensor temperature with the frame (°C); the cooler setpoint, else 0, when the camera reports none",
            group: VariableGroup::Equipment,
            example: "-10",
            supports_format: true,
        },
        VariableEntry {
            name: "exposure.temp_c",
            description: "Target cooler temperature (°C)",
            group: VariableGroup::Exposure,
            example: "-10",
            supports_format: true,
        },
        VariableEntry {
            name: "exposure.total",
            description: "Total burst integration time (minutes: duration_secs × count / 60)",
            group: VariableGroup::Exposure,
            example: "30",
            supports_format: true,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_names_are_unique() {
        let mut seen: std::collections::HashSet<&str> = std::collections::HashSet::new();
        for entry in variable_catalog() {
            assert!(
                seen.insert(entry.name),
                "duplicate variable name in catalog: {}",
                entry.name
            );
        }
    }

    const FIXTURE: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../test_fixtures/interpolation_catalog/catalog.json"
    );

    fn catalog_contract() -> serde_json::Value {
        let entries: Vec<serde_json::Value> = variable_catalog()
            .iter()
            .map(|entry| {
                serde_json::json!({
                    "name": entry.name,
                    "description": entry.description,
                    "group": entry.group.label().to_ascii_lowercase(),
                    "example": entry.example,
                    "supportsFormat": entry.supports_format,
                })
            })
            .collect();
        serde_json::json!({ "variables": entries })
    }

    /// The fixture the app's catalog is held to is this list: the same names,
    /// words, groups, examples and format support, in the same order.
    #[test]
    fn the_catalog_fixture_matches_the_catalog() {
        let mut text = serde_json::to_string_pretty(&catalog_contract()).expect("serialize");
        text.push('\n');
        if std::env::var_os("SKOTIQ_WRITE_FIXTURES").is_some() {
            std::fs::create_dir_all(std::path::Path::new(FIXTURE).parent().expect("dir"))
                .expect("fixture dir");
            std::fs::write(FIXTURE, &text).expect("write fixture");
            return;
        }
        let committed = std::fs::read_to_string(FIXTURE).expect("fixture");
        let committed: serde_json::Value = serde_json::from_str(&committed).expect("fixture JSON");
        assert_eq!(
            committed,
            catalog_contract(),
            "the catalog changed; regenerate the fixture and update the app's catalog"
        );
    }
}
