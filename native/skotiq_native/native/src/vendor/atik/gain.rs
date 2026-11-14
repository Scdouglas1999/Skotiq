//! Gain and offset, which Atik cameras take in three different ways.

use super::*;

/// How a camera takes gain and offset, decided once at connect.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum GainControl {
    /// No gain or offset setting (the CCD cameras).
    #[default]
    None,
    /// ArtemisSetGain / ArtemisGetGain, which only the Sony scientific
    /// cameras implement.
    Sdk,
    /// Camera specific options (Horizon, ACIS, Apx, TE): a custom gain and
    /// offset inside the ranges the camera reports, and on most models factory
    /// presets that take their place while one is selected. The camera keeps
    /// all of it across power cycles.
    Options {
        /// `None` on a TE camera in a low-noise readout: ADC1 has no gain.
        gain: Option<(u16, u16)>,
        offset: (u16, u16),
        /// The custom offset, or the ADC1 offset of a TE camera in a
        /// low-noise readout.
        offset_id: u16,
        presets: bool,
    },
}

impl GainControl {
    /// Whether the camera takes a gain (or, with `offset`, an offset).
    pub(crate) fn takes(self, offset: bool) -> bool {
        match self {
            GainControl::None => false,
            GainControl::Sdk => true,
            GainControl::Options { .. } => self.range(offset).is_some(),
        }
    }

    fn range(self, offset: bool) -> Option<(u16, u16)> {
        match self {
            GainControl::Options {
                gain,
                offset: offsets,
                ..
            } => {
                if offset {
                    Some(offsets)
                } else {
                    gain
                }
            }
            _ => None,
        }
    }

    pub(crate) fn gain_range(self) -> Option<(i32, i32)> {
        self.range(false).map(|(lo, hi)| (lo.into(), hi.into()))
    }

    pub(crate) fn offset_range(self) -> Option<(i32, i32)> {
        self.range(true).map(|(lo, hi)| (lo.into(), hi.into()))
    }
}

const PRESET_NAMES: [&str; 4] = ["Custom", "Low", "Medium", "High"];

/// Camera specific option access on one open camera. The caller holds the
/// SDK lock.
pub(crate) struct Options<'a> {
    sdk: &'a AtikSdk,
    handle: ArtemisHandle,
}

impl<'a> Options<'a> {
    /// `None` when the SDK predates camera specific options.
    pub(crate) fn of(sdk: &'a AtikSdk, handle: ArtemisHandle) -> Option<Self> {
        (sdk.has_camera_specific_option.is_some()
            && sdk.camera_specific_option_get_data.is_some()
            && sdk.camera_specific_option_set_data.is_some())
        .then_some(Self { sdk, handle })
    }

    pub(crate) fn has(&self, id: u16) -> bool {
        let has = self
            .sdk
            .has_camera_specific_option
            .expect("checked in Options::of");
        // SAFETY: the handle is open and the lock is held; plain arguments.
        unsafe { has(self.handle, id) }
    }

    pub(crate) fn read<const N: usize>(&self, id: u16) -> Result<[u8; N], DriverError> {
        let get = self
            .sdk
            .camera_specific_option_get_data
            .expect("checked in Options::of");
        let mut data = [0u8; N];
        let mut actual: c_int = 0;
        // SAFETY: `data` has the N bytes passed as its length and `actual` is a
        // valid out-pointer; the handle is open and the lock is held.
        let result = unsafe { get(self.handle, id, data.as_mut_ptr(), N as c_int, &mut actual) };
        check_artemis_error(result, &format!("read camera option {id}"))?;
        Ok(data)
    }

    pub(crate) fn read_u16(&self, id: u16) -> Result<u16, DriverError> {
        let data = self.read::<2>(id)?;
        Ok(u16::from_le_bytes(data))
    }

    pub(crate) fn write_u16(&self, id: u16, value: u16) -> Result<(), DriverError> {
        let set = self
            .sdk
            .camera_specific_option_set_data
            .expect("checked in Options::of");
        let mut data = value.to_le_bytes();
        // SAFETY: `data` holds the 2 bytes passed as its length; the SDK copies
        // them. The handle is open and the lock is held.
        let result = unsafe { set(self.handle, id, data.as_mut_ptr(), data.len() as c_int) };
        check_artemis_error(result, &format!("set camera option {id} to {value}"))
    }

    /// Minimum, maximum and current value of an option that reports all
    /// three (custom gain and offset, the TE readout mode and ADC1 offset).
    fn bounded(&self, id: u16) -> Result<(u16, u16, u16), DriverError> {
        let d = self.read::<6>(id)?;
        Ok((
            u16::from_le_bytes([d[0], d[1]]),
            u16::from_le_bytes([d[2], d[3]]),
            u16::from_le_bytes([d[4], d[5]]),
        ))
    }
}

/// Which gain control a freshly opened camera has.
pub(crate) fn detect(sdk: &AtikSdk, handle: ArtemisHandle) -> Result<GainControl, DriverError> {
    if let Some(options) = Options::of(sdk, handle) {
        let presets = options.has(ID_GO_PRESET_MODE);
        let adc1 = options.has(ID_READOUT_MODE_TE)
            && options.bounded(ID_READOUT_MODE_TE)?.2 != READOUT_MODE_TE_PREVIEW;
        if adc1 {
            if options.has(ID_ADC1_OFFSET_TE) {
                let (offset_min, offset_max, _) = options.bounded(ID_ADC1_OFFSET_TE)?;
                return Ok(GainControl::Options {
                    gain: None,
                    offset: (offset_min, offset_max),
                    offset_id: ID_ADC1_OFFSET_TE,
                    presets,
                });
            }
        } else if options.has(ID_GO_CUSTOM_GAIN) && options.has(ID_GO_CUSTOM_OFFSET) {
            let (gain_min, gain_max, _) = options.bounded(ID_GO_CUSTOM_GAIN)?;
            let (offset_min, offset_max, _) = options.bounded(ID_GO_CUSTOM_OFFSET)?;
            return Ok(GainControl::Options {
                gain: Some((gain_min, gain_max)),
                offset: (offset_min, offset_max),
                offset_id: ID_GO_CUSTOM_OFFSET,
                presets,
            });
        }
    }
    let (mut gain, mut offset) = (0, 0);
    // SAFETY: both out-pointers are valid; the handle is open and the lock is held.
    let result = unsafe { (sdk.get_gain)(handle, false, &mut gain, &mut offset) };
    Ok(if result == ArtemisError::Ok as c_int {
        GainControl::Sdk
    } else {
        GainControl::None
    })
}

/// The gain and offset the camera exposes with now.
pub(crate) fn effective(
    sdk: &AtikSdk,
    handle: ArtemisHandle,
    control: GainControl,
) -> Result<(i32, i32), DriverError> {
    match control {
        GainControl::None => Ok((0, 0)),
        GainControl::Sdk => {
            let (mut gain, mut offset) = (0, 0);
            // SAFETY: both out-pointers are valid; the handle is open and the lock is held.
            let result = unsafe { (sdk.get_gain)(handle, false, &mut gain, &mut offset) };
            check_artemis_error(result, "read gain and offset")?;
            Ok((gain, offset))
        }
        GainControl::Options {
            gain,
            offset_id,
            presets,
            ..
        } => {
            let options = Options::of(sdk, handle).ok_or(DriverError::NotSupported)?;
            let preset = if presets {
                options.read_u16(ID_GO_PRESET_MODE)?
            } else {
                0
            };
            if preset == 0 {
                let gain = match gain {
                    Some(_) => options.bounded(ID_GO_CUSTOM_GAIN)?.2,
                    None => 0,
                };
                let (_, _, offset) = options.bounded(offset_id)?;
                Ok((gain.into(), offset.into()))
            } else {
                let d = options.read::<5>(ID_GO_PRESET_LOW + preset - 1)?;
                Ok((
                    u16::from_le_bytes([d[1], d[2]]).into(),
                    u16::from_le_bytes([d[3], d[4]]).into(),
                ))
            }
        }
    }
}

/// Sets the custom gain (or offset) and returns the gain and offset the
/// camera exposes with afterwards. A preset in force would override the custom
/// value, so the camera is switched to its custom setting first.
pub(crate) fn set(
    sdk: &AtikSdk,
    handle: ArtemisHandle,
    control: GainControl,
    current: (i32, i32),
    value: i32,
    is_offset: bool,
) -> Result<(i32, i32), DriverError> {
    let what = if is_offset { "offset" } else { "gain" };
    match control {
        GainControl::None => Err(DriverError::NotSupported),
        GainControl::Sdk => {
            let (gain, offset) = if is_offset {
                (current.0, value)
            } else {
                (value, current.1)
            };
            // SAFETY: plain arguments; the handle is open and the lock is held.
            let result = unsafe { (sdk.set_gain)(handle, false, gain, offset) };
            check_artemis_error(result, &format!("set the {what} to {value}"))?;
            effective(sdk, handle, control)
        }
        GainControl::Options {
            offset_id, presets, ..
        } => {
            let (min, max) = control.range(is_offset).ok_or(DriverError::NotSupported)?;
            let requested = u16::try_from(value)
                .ok()
                .filter(|v| (min..=max).contains(v))
                .ok_or_else(|| {
                    DriverError::InvalidParameter(format!(
                        "Atik {what} {value} is outside the camera's range {min} to {max}"
                    ))
                })?;
            let options = Options::of(sdk, handle).ok_or(DriverError::NotSupported)?;
            if presets {
                let preset = options.read_u16(ID_GO_PRESET_MODE)?;
                if preset != 0 {
                    options.write_u16(ID_GO_PRESET_MODE, 0)?;
                    tracing::info!(
                        "Atik camera: switched gain and offset from the {} preset to the custom setting to set the {what}",
                        PRESET_NAMES.get(usize::from(preset)).unwrap_or(&"unknown")
                    );
                }
            }
            let id = if is_offset {
                offset_id
            } else {
                ID_GO_CUSTOM_GAIN
            };
            options.write_u16(id, requested)?;
            effective(sdk, handle, control)
        }
    }
}
