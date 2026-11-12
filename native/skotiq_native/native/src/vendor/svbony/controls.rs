//! The camera's controls as SVBGetControlCaps lists them, and the SDK calls
//! that read and write one.

use super::*;

/// One control from SVBGetControlCaps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Control {
    pub(crate) control_type: c_int,
    pub(crate) min: i64,
    pub(crate) max: i64,
    pub(crate) default: i64,
    pub(crate) writable: bool,
}

impl Control {
    pub(crate) fn from_caps(caps: &SvbControlCaps) -> Self {
        Self {
            control_type: caps.control_type,
            min: from_long(caps.min_value),
            max: from_long(caps.max_value),
            default: from_long(caps.default_value),
            writable: caps.is_writable != 0,
        }
    }
}

/// Every control one camera has, read once at connect.
#[derive(Debug, Clone, Default)]
pub(crate) struct Controls(Vec<Control>);

impl Controls {
    #[cfg(test)]
    pub(crate) fn new(controls: Vec<Control>) -> Self {
        Self(controls)
    }

    /// Read the list under a lock the caller holds. A control whose caps
    /// cannot be read is left out, as INDI and NINA do.
    pub(crate) fn read(sdk: &SvbonySdk, camera_id: c_int) -> Result<Self, DriverError> {
        let mut count: c_int = 0;
        // SAFETY: the camera is open; `&mut count` is a valid c_int out-pointer.
        let result = unsafe { (sdk.get_num_of_controls)(camera_id, &mut count) };
        check(result, "list the camera's controls")?;
        let mut controls = Vec::new();
        for index in 0..count {
            // SAFETY: SvbControlCaps is `#[repr(C)]` POD; zeroed is a valid value
            // for the SDK to overwrite.
            let mut caps: SvbControlCaps = unsafe { std::mem::zeroed() };
            // SAFETY: `index` is below the count the SDK just gave and `caps` is a
            // valid out-pointer to a struct laid out as SVB_CONTROL_CAPS.
            let result = unsafe { (sdk.get_control_caps)(camera_id, index, &mut caps) };
            if SvbError::from_i32(result) == SvbError::Success {
                controls.push(Control::from_caps(&caps));
            } else {
                tracing::debug!(
                    "SVBony camera {}: control {} could not be read ({:?})",
                    camera_id,
                    index,
                    SvbError::from_i32(result)
                );
            }
        }
        Ok(Self(controls))
    }

    pub(crate) fn get(&self, control: SvbControlType) -> Option<&Control> {
        self.0.iter().find(|c| c.control_type == control as c_int)
    }

    pub(crate) fn has(&self, control: SvbControlType) -> bool {
        self.get(control).is_some()
    }

    /// Writable controls that shape the image (gamma, contrast, white balance,
    /// flip, ...). The camera keeps their values from the last program that
    /// used it, so connect puts them back to their defaults: INDI calls
    /// SVBRestoreDefaultParam (svbony_base.cpp:539-545) and NINA sets every
    /// control to its default (SVBonySDK.cs:103-112). A flip left on would move
    /// the Bayer pattern every frame is labelled with.
    pub(crate) fn image_shaping(&self) -> impl Iterator<Item = &Control> {
        self.0.iter().filter(|c| {
            c.writable
                && !SvbControlType::OWNED
                    .iter()
                    .any(|owned| *owned as c_int == c.control_type)
        })
    }
}

/// The SDK's `long` as i64: the same type on LP64 (Linux, macOS), a widening
/// from i32 on LLP64 (Windows).
#[allow(clippy::useless_conversion)]
fn from_long(value: c_long) -> i64 {
    i64::from(value)
}

pub(crate) fn check(result: c_int, action: &str) -> Result<(), DriverError> {
    match SvbError::from_i32(result) {
        SvbError::Success => Ok(()),
        error => Err(error.to_native_error(action)),
    }
}

/// Read a control under a lock the caller holds.
pub(crate) fn read_control(
    sdk: &SvbonySdk,
    camera_id: c_int,
    control: SvbControlType,
) -> Result<i64, DriverError> {
    let mut value: c_long = 0;
    let mut is_auto: c_int = 0;
    // SAFETY: the camera is open; both out-pointers are valid stack locals.
    let result =
        unsafe { (sdk.get_control_value)(camera_id, control as c_int, &mut value, &mut is_auto) };
    check(
        result,
        &format!("read the {}", control_name(control as c_int)),
    )?;
    Ok(from_long(value))
}

/// Write a control with automatic adjustment off, under a lock the caller
/// holds. The SDK stores the nearest value inside the control's range and
/// reports success (SVBCameraSDK.h, SVBSetControlValue), so a caller that
/// records the value reads it back.
pub(crate) fn write_control(
    sdk: &SvbonySdk,
    camera_id: c_int,
    control_type: c_int,
    value: i64,
) -> Result<(), DriverError> {
    let value = c_long::try_from(value).map_err(|_| {
        DriverError::InvalidParameter(format!(
            "SVBony {} value {} does not fit the SDK's long",
            control_name(control_type),
            value
        ))
    })?;
    // SAFETY: the camera is open; all arguments are plain integers.
    let result = unsafe { (sdk.set_control_value)(camera_id, control_type, value, 0) };
    check(result, &format!("set the {}", control_name(control_type)))
}

/// The SVB_EXPOSURE value for a requested exposure, in microseconds.
///
/// Above the camera's longest exposure the request is refused: the SDK would
/// store its maximum and report success, and the frame would be labelled with
/// a time the camera did not expose. Below the shortest, the camera exposes its
/// shortest, which the caller reads back and records. On Windows the SDK's
/// `long` is 32 bits, so nothing past 2147 s can be sent at all.
pub(crate) fn exposure_micros(
    duration_secs: f64,
    range: Option<&Control>,
) -> Result<i64, DriverError> {
    if !duration_secs.is_finite() || duration_secs < 0.0 {
        return Err(DriverError::InvalidParameter(format!(
            "SVBony exposure must be a positive number of seconds, got {}",
            duration_secs
        )));
    }
    let micros = (duration_secs * 1_000_000.0).round();
    let longest = range
        .map(|c| c.max)
        .unwrap_or(from_long(c_long::MAX))
        .min(from_long(c_long::MAX));
    if micros > longest as f64 {
        return Err(DriverError::InvalidParameter(format!(
            "SVBony camera's longest exposure is {} s; {} s was requested",
            longest as f64 / 1_000_000.0,
            duration_secs
        )));
    }
    let micros = micros as i64;
    Ok(range.map_or(micros, |c| micros.max(c.min)))
}
