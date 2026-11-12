//! What the ICameraV4 members mean, decided once for both ASCOM transports.
//!
//! The COM wrapper (`bridge/src/ascom_wrapper/camera.rs`) and the Alpaca
//! camera path (`bridge/src/device_manager/ops/camera/`) read and write the
//! same members; the rules here say how a request becomes member values and
//! how member values become what Skotiq reports, so the two cannot drift.
//! References: ASCOM Master Interfaces 1.1.0 (ICameraV4) and ConformU's
//! `CameraTester.cs`.

use crate::{DriverError, FrameType, SubFrame};

/// The `Light` argument of `StartExposure`: false for frames taken with the
/// shutter closed. A camera without a shutter ignores it, and only a dark
/// exposure may be shorter than `ExposureMin` (a bias may be 0 s).
pub fn exposes_to_light(frame_type: FrameType) -> bool {
    !matches!(
        frame_type,
        FrameType::Dark | FrameType::Bias | FrameType::DarkFlat
    )
}

/// What reading one member told about it.
#[derive(Debug, Clone, PartialEq)]
pub enum Probe<T> {
    Value(T),
    /// The driver says it has no such member (`NotImplemented`).
    Absent,
    /// The member exists but gave no value: ConformU counts a member that
    /// throws `InvalidOperation` as implemented, and a read that failed for
    /// any other reason says nothing about the member.
    NoValue,
}

impl<T> From<Result<T, DriverError>> for Probe<T> {
    fn from(read: Result<T, DriverError>) -> Self {
        match read {
            Ok(value) => Probe::Value(value),
            Err(DriverError::NotSupported) => Probe::Absent,
            Err(_) => Probe::NoValue,
        }
    }
}

impl<T> Probe<T> {
    fn exists(&self) -> bool {
        !matches!(self, Probe::Absent)
    }

    fn value(self) -> Option<T> {
        match self {
            Probe::Value(value) => Some(value),
            _ => None,
        }
    }
}

/// How a camera offers `Gain` or `Offset`: the three modes of ICameraV4.
///
/// In the index mode the property is a position in a list of named settings
/// (`Gains`, `Offsets`). When every name is an ISO speed (a DSLR behind an
/// ASCOM driver: "ISO 100", "ISO 800"), Skotiq reads and writes the ISO number
/// and the index stays on the wire, as for DSLRs on their own drivers. Other
/// names ("Low", "HCG") have no number, so Skotiq uses the index itself.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum CameraControl {
    /// Neither the property nor its list is implemented.
    #[default]
    Absent,
    /// The property is a position in this list of names.
    Named(Vec<String>),
    /// The property is a number, within `GainMin..=GainMax` when the driver
    /// reports the limits.
    Value { range: Option<(i32, i32)> },
}

impl CameraControl {
    /// The mode the four members of one control show. `value` is `Gain`,
    /// `names` is `Gains`, `min`/`max` are `GainMin`/`GainMax` (or the offset
    /// ones).
    pub fn detect(
        value: Probe<i32>,
        names: Probe<Vec<String>>,
        min: Probe<i32>,
        max: Probe<i32>,
    ) -> Self {
        match names {
            Probe::Value(names) if !names.is_empty() => return CameraControl::Named(names),
            _ => {}
        }
        if !value.exists() && !min.exists() && !max.exists() {
            return CameraControl::Absent;
        }
        let range = match (min.value(), max.value()) {
            (Some(min), Some(max)) if min <= max => Some((min, max)),
            _ => None,
        };
        CameraControl::Value { range }
    }

    pub fn is_present(&self) -> bool {
        !matches!(self, CameraControl::Absent)
    }

    /// The ISO speeds of an index-mode control whose names are all ISO
    /// speeds, with the index each one has on the wire, lowest speed first.
    /// Empty for every other control.
    fn iso_positions(&self) -> Vec<(i32, i32)> {
        let CameraControl::Named(names) = self else {
            return Vec::new();
        };
        let mut positions = Vec::with_capacity(names.len());
        for (index, name) in names.iter().enumerate() {
            match iso_speed(name) {
                Some(iso) => positions.push((iso, index as i32)),
                None if name.trim().eq_ignore_ascii_case("auto")
                    || name.trim().eq_ignore_ascii_case("iso auto") => {}
                None => return Vec::new(),
            }
        }
        positions.sort_unstable();
        positions
    }

    /// The camera's selectable ISO speeds, lowest first; empty unless the
    /// control is an ISO list.
    pub fn iso_speeds(&self) -> Vec<i32> {
        self.iso_positions()
            .into_iter()
            .map(|(iso, _)| iso)
            .collect()
    }

    /// The values Skotiq may request, inclusive.
    pub fn range(&self) -> Option<(i32, i32)> {
        match self {
            CameraControl::Absent => None,
            CameraControl::Value { range } => *range,
            CameraControl::Named(names) => {
                let isos = self.iso_positions();
                match (isos.first(), isos.last()) {
                    (Some(lowest), Some(highest)) => Some((lowest.0, highest.0)),
                    _ => Some((0, names.len() as i32 - 1)),
                }
            }
        }
    }

    /// The value to write to the property for a requested setting. An ISO
    /// request between two listed speeds takes the nearest one.
    pub fn to_wire(&self, requested: i32, what: &str) -> Result<i32, DriverError> {
        match self {
            CameraControl::Absent => Err(DriverError::NotSupported),
            CameraControl::Value { range } => match range {
                Some((min, max)) if requested < *min || requested > *max => {
                    Err(DriverError::InvalidParameter(format!(
                        "{what} {requested} is outside the camera's range {min} to {max}"
                    )))
                }
                _ => Ok(requested),
            },
            CameraControl::Named(names) => {
                let isos = self.iso_positions();
                if let Some(&(_, index)) = isos
                    .iter()
                    .min_by_key(|(iso, _)| (i64::from(*iso) - i64::from(requested)).abs())
                {
                    return Ok(index);
                }
                if (0..names.len() as i32).contains(&requested) {
                    Ok(requested)
                } else {
                    Err(DriverError::InvalidParameter(format!(
                        "{what} {requested} is not one of the camera's {} settings (0 to {})",
                        names.len(),
                        names.len() as i32 - 1
                    )))
                }
            }
        }
    }

    /// The setting a property value stands for: the ISO speed at that index
    /// for an ISO list, otherwise the value itself.
    pub fn from_wire(&self, wire: i32) -> i32 {
        self.iso_positions()
            .into_iter()
            .find(|(_, index)| *index == wire)
            .map_or(wire, |(iso, _)| iso)
    }
}

/// The two sensitivity controls of one camera.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CameraControls {
    pub gain: CameraControl,
    pub offset: CameraControl,
}

/// The ISO speed a gain name stands for: "ISO 800", "ISO800", "800".
fn iso_speed(name: &str) -> Option<i32> {
    let name = name.trim();
    let digits = name
        .strip_prefix("ISO")
        .or_else(|| name.strip_prefix("iso"))
        .unwrap_or(name)
        .trim();
    digits.parse::<i32>().ok().filter(|iso| *iso > 0)
}

/// The setpoint to write to `SetCCDTemperature` before `CoolerOn`, if any.
///
/// Switching a cooler off writes `CoolerOn = false` and nothing else, and a
/// camera that answers `CanSetCCDTemperature = False` (or whose answer could
/// not be read) is never sent a setpoint: on a ZWO ASI178MM an invented
/// setpoint on a cooler-off command threw and left the cooler on. `None` for
/// `requested` keeps the setpoint the driver holds.
pub fn cooler_setpoint_to_write(
    enabled: bool,
    requested: Option<f64>,
    can_set_ccd_temperature: Option<bool>,
) -> Option<f64> {
    if !enabled || can_set_ccd_temperature != Some(true) {
        return None;
    }
    requested
}

/// `StartX`, `StartY`, `NumX`, `NumY` for one exposure, in binned pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameGeometry {
    pub start_x: i32,
    pub start_y: i32,
    pub num_x: i32,
    pub num_y: i32,
}

/// The frame to set for an exposure at `bin`, given the unbinned sensor size
/// (`CameraXSize`, `CameraYSize`) and `MaxBinX`/`MaxBinY`.
///
/// `NumX`/`NumY` and `StartX`/`StartY` are in binned pixels, and a driver need
/// not resize the frame when the binning changes, so binning is checked first
/// and every exposure sets the whole frame: a subframe as asked (already in
/// binned pixels), otherwise the full sensor divided by the binning.
pub fn frame_geometry(
    sensor: (i32, i32),
    max_bin: (i32, i32),
    bin: (i32, i32),
    subframe: Option<&SubFrame>,
) -> Result<FrameGeometry, DriverError> {
    let (bin_x, bin_y) = bin;
    if bin_x < 1 || bin_y < 1 {
        return Err(DriverError::InvalidParameter(format!(
            "Binning {bin_x}x{bin_y} must be at least 1x1"
        )));
    }
    if bin_x > max_bin.0 || bin_y > max_bin.1 {
        return Err(DriverError::InvalidParameter(format!(
            "Binning {bin_x}x{bin_y} exceeds the camera's maximum {}x{}",
            max_bin.0, max_bin.1
        )));
    }
    let full_x = sensor.0 / bin_x;
    let full_y = sensor.1 / bin_y;
    if full_x < 1 || full_y < 1 {
        return Err(DriverError::InvalidParameter(format!(
            "A {}x{} sensor has no full frame at binning {bin_x}x{bin_y}",
            sensor.0, sensor.1
        )));
    }
    let Some(roi) = subframe else {
        return Ok(FrameGeometry {
            start_x: 0,
            start_y: 0,
            num_x: full_x,
            num_y: full_y,
        });
    };
    let fits = |start: u32, size: u32, full: i32| {
        i64::from(start) + i64::from(size) <= i64::from(full) && size > 0
    };
    if !fits(roi.start_x, roi.width, full_x) || !fits(roi.start_y, roi.height, full_y) {
        return Err(DriverError::InvalidParameter(format!(
            "Subframe {}x{} at ({}, {}) does not fit the {full_x}x{full_y} frame at binning {bin_x}x{bin_y}",
            roi.width, roi.height, roi.start_x, roi.start_y
        )));
    }
    Ok(FrameGeometry {
        start_x: roi.start_x as i32,
        start_y: roi.start_y as i32,
        num_x: roi.width as i32,
        num_y: roi.height as i32,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Probe<Vec<String>> {
        Probe::Value(list.iter().map(|s| s.to_string()).collect())
    }

    #[test]
    fn darks_and_biases_are_taken_with_the_shutter_closed() {
        assert!(exposes_to_light(FrameType::Light));
        assert!(exposes_to_light(FrameType::Flat));
        assert!(!exposes_to_light(FrameType::Dark));
        assert!(!exposes_to_light(FrameType::Bias));
        assert!(!exposes_to_light(FrameType::DarkFlat));
    }

    /// The three ICameraV4 modes, from what the four members answer.
    #[test]
    fn the_mode_follows_the_members_the_driver_implements() {
        assert_eq!(
            CameraControl::detect(Probe::Absent, Probe::Absent, Probe::Absent, Probe::Absent),
            CameraControl::Absent
        );
        assert_eq!(
            CameraControl::detect(
                Probe::Value(120),
                Probe::Absent,
                Probe::Value(0),
                Probe::Value(300)
            ),
            CameraControl::Value {
                range: Some((0, 300))
            }
        );
        assert_eq!(
            CameraControl::detect(
                Probe::Value(1),
                names(&["Low", "High"]),
                Probe::Absent,
                Probe::Absent
            ),
            CameraControl::Named(vec!["Low".into(), "High".into()])
        );
        // A gain that is only unreadable right now still exists.
        assert_eq!(
            CameraControl::detect(Probe::NoValue, Probe::Absent, Probe::Absent, Probe::Absent),
            CameraControl::Value { range: None }
        );
    }

    /// A DSLR behind ASCOM: Skotiq speaks ISO, the wire speaks the index.
    #[test]
    fn an_iso_list_is_read_and_written_as_iso_speeds() {
        let gain = CameraControl::detect(
            Probe::Value(2),
            names(&["ISO 100", "ISO 200", "ISO 400", "ISO 800", "ISO 1600"]),
            Probe::Absent,
            Probe::Absent,
        );
        assert_eq!(gain.iso_speeds(), vec![100, 200, 400, 800, 1600]);
        assert_eq!(gain.range(), Some((100, 1600)));
        assert_eq!(gain.from_wire(2), 400);
        assert_eq!(gain.to_wire(800, "Gain").unwrap(), 3);
        // Between two speeds the nearest one is taken.
        assert_eq!(gain.to_wire(700, "Gain").unwrap(), 3);
        assert_eq!(gain.to_wire(50, "Gain").unwrap(), 0);
    }

    #[test]
    fn an_auto_entry_keeps_the_other_speeds_on_their_indices() {
        let gain = CameraControl::Named(vec!["Auto".into(), "100".into(), "ISO800".into()]);
        assert_eq!(gain.iso_speeds(), vec![100, 800]);
        assert_eq!(gain.to_wire(800, "Gain").unwrap(), 2);
        assert_eq!(gain.from_wire(1), 100);
    }

    #[test]
    fn named_settings_without_numbers_use_the_index() {
        let gain = CameraControl::Named(vec!["Low".into(), "HCG".into()]);
        assert!(gain.iso_speeds().is_empty());
        assert_eq!(gain.range(), Some((0, 1)));
        assert_eq!(gain.from_wire(1), 1);
        assert_eq!(gain.to_wire(1, "Gain").unwrap(), 1);
        assert!(gain.to_wire(2, "Gain").is_err());
    }

    #[test]
    fn a_value_outside_the_reported_range_is_refused_in_words() {
        let gain = CameraControl::Value {
            range: Some((0, 300)),
        };
        let err = gain.to_wire(400, "Gain").unwrap_err().to_string();
        assert!(err.contains("outside the camera's range 0 to 300"), "{err}");
        assert_eq!(gain.to_wire(300, "Gain").unwrap(), 300);
        assert!(matches!(
            CameraControl::Absent.to_wire(1, "Gain"),
            Err(DriverError::NotSupported)
        ));
    }

    #[test]
    fn a_cooler_is_sent_a_setpoint_only_when_switching_on_a_camera_that_takes_one() {
        assert_eq!(
            cooler_setpoint_to_write(false, Some(-10.0), Some(true)),
            None
        );
        assert_eq!(
            cooler_setpoint_to_write(true, Some(-10.0), Some(false)),
            None
        );
        assert_eq!(cooler_setpoint_to_write(true, Some(-10.0), None), None);
        assert_eq!(cooler_setpoint_to_write(true, None, Some(true)), None);
        assert_eq!(
            cooler_setpoint_to_write(true, Some(-15.0), Some(true)),
            Some(-15.0)
        );
    }

    #[test]
    fn the_full_frame_is_in_binned_pixels() {
        let g = frame_geometry((1000, 800), (4, 4), (2, 2), None).unwrap();
        assert_eq!(
            g,
            FrameGeometry {
                start_x: 0,
                start_y: 0,
                num_x: 500,
                num_y: 400
            }
        );
    }

    #[test]
    fn a_subframe_must_fit_the_binned_frame() {
        let roi = SubFrame {
            start_x: 100,
            start_y: 100,
            width: 400,
            height: 300,
        };
        assert!(frame_geometry((1000, 800), (4, 4), (2, 2), Some(&roi)).is_ok());
        let too_wide = SubFrame { width: 401, ..roi };
        assert!(frame_geometry((1000, 800), (4, 4), (2, 2), Some(&too_wide)).is_err());
    }

    #[test]
    fn binning_beyond_the_camera_is_refused() {
        assert!(frame_geometry((1000, 800), (4, 4), (8, 8), None).is_err());
        assert!(frame_geometry((1000, 800), (4, 4), (0, 1), None).is_err());
    }
}
