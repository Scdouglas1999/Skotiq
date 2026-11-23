//! What a captured frame is, as its FITS `IMAGETYP` names it.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// What a captured frame is.
///
/// A Snapshot is a frame of the sky the operator wants to look at now (a
/// framing or focus check, a test of the exposure), not part of the night's
/// data: it is taken, analyzed and guided like a light, but it does not wait
/// for darkness and is not stacked. A camera is never asked for one; it takes
/// a light ([`FrameType::taken_as`]).
///
/// The frame type also drives the shutter on cameras with a mechanical one
/// (Moravian G-series, FLI, some CCDs): dark and bias frames are taken with it
/// closed. CMOS cameras without a shutter ignore it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum FrameType {
    #[default]
    Light,
    Dark,
    Flat,
    Bias,
    DarkFlat,
    Snapshot,
}

impl FrameType {
    const ALL: [Self; 6] = [
        Self::Light,
        Self::Dark,
        Self::Flat,
        Self::Bias,
        Self::DarkFlat,
        Self::Snapshot,
    ];

    /// The `IMAGETYP` spelling, which is also the wire spelling.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Light => "Light",
            Self::Dark => "Dark",
            Self::Flat => "Flat",
            Self::Bias => "Bias",
            Self::DarkFlat => "DarkFlat",
            Self::Snapshot => "Snapshot",
        }
    }

    /// The frame type its `IMAGETYP` spelling names.
    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|frame_type| frame_type.as_str() == name)
    }

    /// The camera frame a name from the app asks for, ignoring case: "dark",
    /// "flat", "bias" and "darkflat" (also "dark_flat", "dark flat"), and a
    /// light for "light" and "snapshot". `None` for any other name.
    pub fn from_app_name(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "dark" => Some(Self::Dark),
            "flat" => Some(Self::Flat),
            "bias" => Some(Self::Bias),
            "darkflat" | "dark_flat" | "dark flat" => Some(Self::DarkFlat),
            "light" | "snapshot" => Some(Self::Light),
            _ => None,
        }
    }

    /// [`Self::from_app_name`], with any other name a light: the shutter
    /// opens and no frame is missed.
    pub fn from_str_lenient(s: &str) -> Self {
        Self::from_app_name(s).unwrap_or(Self::Light)
    }

    /// The frame a camera is asked for: a snapshot is taken as a light.
    pub fn taken_as(self) -> Self {
        match self {
            Self::Snapshot => Self::Light,
            other => other,
        }
    }

    /// Whether a mechanical shutter is open during the exposure. Light, flat
    /// and snapshot frames collect light; dark, bias and dark-flat frames
    /// exclude it.
    pub fn opens_shutter(self) -> bool {
        matches!(self, Self::Light | Self::Flat | Self::Snapshot)
    }

    /// A frame of the sky through the open telescope: its stars are measured
    /// and graded, it is dithered and guided for, it counts toward the
    /// autofocus and dither cadence, and it waits out a meridian flip that
    /// would ruin it.
    pub fn is_sky_frame(self) -> bool {
        matches!(self, Self::Light | Self::Snapshot)
    }

    /// Part of the night's data: it waits for darkness, its filters are the
    /// night's light filters, and it is stacked.
    pub fn is_science(self) -> bool {
        self == Self::Light
    }

    /// Taken with the shutter closed or on a flat light source; where the
    /// telescope points does not matter.
    pub fn is_calibration(self) -> bool {
        !self.is_sky_frame()
    }

    /// Matched to lights by the sensor temperature it was taken at, so it is
    /// taken only with the sensor at the cooler's set-point.
    pub fn is_matched_by_sensor_temperature(self) -> bool {
        matches!(self, Self::Dark | Self::Bias | Self::DarkFlat)
    }
}

impl Serialize for FrameType {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for FrameType {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let name = String::deserialize(deserializer)?;
        Self::from_name(&name).ok_or_else(|| {
            serde::de::Error::custom(format!(
                "unknown frame type `{name}`; expected one of Light, Dark, Flat, Bias, \
                 DarkFlat, Snapshot"
            ))
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_type_round_trips_through_its_imagetyp_spelling() {
        for frame_type in FrameType::ALL {
            assert_eq!(FrameType::from_name(frame_type.as_str()), Some(frame_type));
            let json = serde_json::to_string(&frame_type).unwrap();
            assert_eq!(json, format!("\"{}\"", frame_type.as_str()));
            assert_eq!(
                serde_json::from_str::<FrameType>(&json).unwrap(),
                frame_type
            );
        }
        assert_eq!(FrameType::from_name("dark"), None);
        assert!(serde_json::from_str::<FrameType>("\"dark\"").is_err());
    }

    #[test]
    fn a_name_from_the_app_asks_for_a_camera_frame() {
        assert_eq!(FrameType::from_str_lenient(" DARK "), FrameType::Dark);
        assert_eq!(FrameType::from_str_lenient("Flat"), FrameType::Flat);
        assert_eq!(FrameType::from_str_lenient("bias"), FrameType::Bias);
        for name in ["DarkFlat", "dark_flat", "dark flat"] {
            assert_eq!(FrameType::from_str_lenient(name), FrameType::DarkFlat);
        }
        for name in ["Light", "Snapshot", "Darks", ""] {
            assert_eq!(FrameType::from_str_lenient(name), FrameType::Light);
        }
    }

    /// F1-4: every frame type name the app sends a capture with (its
    /// `FrameType.name`, pinned by `camera_frame_type_names_test.dart`) is
    /// one the capture knows, and asks for the frame it names.
    #[test]
    fn every_name_the_app_sends_is_known() {
        let names: std::collections::BTreeMap<String, String> = serde_json::from_str(include_str!(
            "../../../../packages/skotiq_core/test/fixtures/camera_frame_type_names.json"
        ))
        .expect("the fixture is JSON");
        for (name, frame) in names {
            assert_eq!(
                FrameType::from_app_name(&name).map(FrameType::as_str),
                Some(frame.as_str()),
                "{name}"
            );
        }
        assert_eq!(FrameType::from_app_name("Darks"), None);
    }

    #[test]
    fn a_snapshot_is_taken_as_a_light() {
        assert_eq!(FrameType::Snapshot.taken_as(), FrameType::Light);
        for frame_type in FrameType::ALL {
            assert_ne!(frame_type.taken_as(), FrameType::Snapshot);
            assert_eq!(
                frame_type.taken_as().opens_shutter(),
                frame_type.opens_shutter()
            );
        }
        assert!(FrameType::Light.opens_shutter() && FrameType::Flat.opens_shutter());
        assert!(!FrameType::Dark.opens_shutter() && !FrameType::Bias.opens_shutter());
        assert!(!FrameType::DarkFlat.opens_shutter());
    }
}
