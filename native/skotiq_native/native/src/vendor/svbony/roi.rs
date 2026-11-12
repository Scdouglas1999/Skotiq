//! The readout region in the form SVBSetROIFormat accepts.

use super::*;

/// What SVBSetROIFormat is given: start and size in binned pixels, and the bin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Roi {
    pub(crate) start_x: i32,
    pub(crate) start_y: i32,
    pub(crate) width: i32,
    pub(crate) height: i32,
    pub(crate) bin: i32,
}

impl Roi {
    /// The region for `bin` and an optional subframe (binned pixels, as every
    /// Skotiq caller gives it).
    ///
    /// SVBCameraSDK.h requires `width % 8 == 0` and `height % 2 == 0`; any other
    /// size is refused with SVB_ERROR_INVALID_SIZE. Like the INDI driver
    /// (svbony_base.cpp:1100-1115) the size is rounded down to the nearest one
    /// the SDK takes: an IMX294 camera (SV405CC, 4144 x 2822) at bin 2 reads
    /// 2072 x 1410. On a color sensor the start is kept on even pixels so the
    /// subframe's Bayer pattern is the sensor's.
    pub(crate) fn for_frame(
        sensor_width: u32,
        sensor_height: u32,
        bin: i32,
        subframe: Option<&SubFrame>,
        color: bool,
    ) -> Result<Self, DriverError> {
        let bin_u32 = u32::try_from(bin).ok().filter(|&b| b >= 1).ok_or_else(|| {
            DriverError::InvalidParameter(format!("SVBony binning must be 1 or more, got {}", bin))
        })?;
        let binned_width = sensor_width / bin_u32;
        let binned_height = sensor_height / bin_u32;
        let (start_x, start_y, width, height) = match subframe {
            None => (0, 0, binned_width, binned_height),
            Some(sf) => {
                let fits = |start: u32, size: u32, limit: u32| {
                    start.checked_add(size).is_some_and(|end| end <= limit)
                };
                if !fits(sf.start_x, sf.width, binned_width)
                    || !fits(sf.start_y, sf.height, binned_height)
                {
                    return Err(DriverError::InvalidParameter(format!(
                        "SVBony subframe {}x{} at {},{} does not fit the {}x{} sensor at bin {}",
                        sf.width,
                        sf.height,
                        sf.start_x,
                        sf.start_y,
                        binned_width,
                        binned_height,
                        bin
                    )));
                }
                let phase = if color { !1 } else { !0 };
                (sf.start_x & phase, sf.start_y & phase, sf.width, sf.height)
            }
        };
        let width = width & !7;
        let height = height & !1;
        if width == 0 || height == 0 {
            return Err(DriverError::InvalidParameter(format!(
                "SVBony readout region must be at least 8 x 2 pixels after alignment, got {}x{}",
                width, height
            )));
        }
        let as_int = |value: u32| {
            i32::try_from(value).map_err(|_| {
                DriverError::InvalidParameter(format!(
                    "SVBony readout region value {} is out of range",
                    value
                ))
            })
        };
        Ok(Self {
            start_x: as_int(start_x)?,
            start_y: as_int(start_y)?,
            width: as_int(width)?,
            height: as_int(height)?,
            bin,
        })
    }

    /// The subframe a frame read with this region covers.
    pub(crate) fn subframe(&self) -> SubFrame {
        // The fields are built from u32 values in `for_frame`.
        SubFrame {
            start_x: self.start_x as u32,
            start_y: self.start_y as u32,
            width: self.width as u32,
            height: self.height as u32,
        }
    }
}
