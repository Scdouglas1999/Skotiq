//! Single source of truth for the variable catalog.
//!
//! Every supported `${...}` placeholder is declared in [`variable_catalog`].
//! The resolver consults this list when evaluating a template; the Dart
//! variable-picker widget consults the JSON dump of this list (emitted by
//! [`catalog_json`]) so the two stay in sync.
//!
//! Adding a new variable: declare it here, add its resolution arm in
//! [`super::resolver::resolve_variable`], and the picker picks it up on the
//! next FRB regen.

use serde::Serialize;

/// Top-level groupings shown in the Dart variable-picker UI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
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
#[derive(Debug, Clone, Serialize)]
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
        // Filter
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
            description: "Observer elevation (metres)",
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
            name: "exposure.temp_c",
            description: "Target cooler temperature (°C)",
            group: VariableGroup::Exposure,
            example: "-10",
            supports_format: true,
        },
        VariableEntry {
            name: "exposure.total",
            description: "Total burst integration time (minutes — duration_secs × count / 60)",
            group: VariableGroup::Exposure,
            example: "30",
            supports_format: true,
        },
    ]
}

/// Stable JSON dump of the catalog. The Dart picker fetches this via FFI
/// (see `skotiq_bridge::api`) and renders one row per entry.
pub fn catalog_json() -> String {
    serde_json::to_string(variable_catalog())
        .expect("variable catalog must serialise — all fields derive Serialize")
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

    #[test]
    fn catalog_json_renders_every_entry() {
        // VariableEntry holds `&'static str`s so deserialization requires a
        // shadow type. We verify the JSON structure instead — each entry's
        // `name` must appear in the dump.
        let json = catalog_json();
        for entry in variable_catalog() {
            assert!(
                json.contains(&format!("\"{}\"", entry.name)),
                "json dump missing variable {}",
                entry.name
            );
        }
        // The dump must be a JSON array so the Dart side can decode it.
        assert!(json.starts_with('['), "expected JSON array, got: {json}");
        assert!(json.ends_with(']'), "expected JSON array, got: {json}");
    }
}
