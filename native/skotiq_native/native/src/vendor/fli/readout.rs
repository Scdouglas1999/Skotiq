//! What libfli is told for one frame and what it means, worked out without
//! the SDK.

use super::*;

/// libfli's own binning limit for every camera family it drives (libfli.c
/// FLISetHBin / FLISetVBin: "from 1 to 16").
pub(crate) const FLI_MAX_BIN: i32 = 16;

/// The visible part of the sensor as FLIGetVisibleArea reports it, in
/// absolute sensor pixels. The origin is often not (0, 0): the columns and
/// rows before it are overscan.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct VisibleArea {
    pub(crate) ul_x: i32,
    pub(crate) ul_y: i32,
    pub(crate) width: u32,
    pub(crate) height: u32,
}

impl VisibleArea {
    /// From the SDK's corners; an inverted rectangle is an SDK fault.
    pub(crate) fn from_corners(
        ul_x: c_long,
        ul_y: c_long,
        lr_x: c_long,
        lr_y: c_long,
    ) -> Result<Self, DriverError> {
        let ul_x = fli_c_long_to_i32(ul_x, "visible area ul_x")?;
        let ul_y = fli_c_long_to_i32(ul_y, "visible area ul_y")?;
        let lr_x = fli_c_long_to_i32(lr_x, "visible area lr_x")?;
        let lr_y = fli_c_long_to_i32(lr_y, "visible area lr_y")?;
        let width = u32::try_from(i64::from(lr_x) - i64::from(ul_x));
        let height = u32::try_from(i64::from(lr_y) - i64::from(ul_y));
        match (width, height) {
            (Ok(width), Ok(height)) if width > 0 && height > 0 && ul_x >= 0 && ul_y >= 0 => {
                Ok(Self {
                    ul_x,
                    ul_y,
                    width,
                    height,
                })
            }
            _ => Err(DriverError::SdkError(format!(
                "FLI camera reported an unusable visible area ({ul_x}, {ul_y}) to ({lr_x}, {lr_y})"
            ))),
        }
    }
}

/// The rectangle one frame is read from, as FLISetImageArea takes it, and the
/// size of the frame it gives.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) struct ImageArea {
    pub(crate) ul_x: c_long,
    pub(crate) ul_y: c_long,
    pub(crate) lr_x: c_long,
    pub(crate) lr_y: c_long,
    /// Binned pixels per row.
    pub(crate) width: u32,
    /// Binned rows.
    pub(crate) height: u32,
}

/// The FLISetImageArea rectangle for a subframe (unbinned pixels, relative
/// to the visible area; `None` is the whole visible area) at a binning.
///
/// libfli.c FLISetImageArea: the upper-left corner is absolute and unbinned,
/// the lower-right one is that corner plus the binned frame size. The camera
/// reads `(lr - ul) * bin` sensor pixels from the corner (INDI fli_ccd.cpp
/// UpdateCCDFrame, NINA FLICamera.GetImageArea do the same), so passing the
/// unbinned lower-right corner asks a binned frame for bin² the area, past
/// the edge of the sensor.
pub(crate) fn image_area(
    visible: VisibleArea,
    subframe: Option<&SubFrame>,
    bin_x: i32,
    bin_y: i32,
) -> Result<ImageArea, DriverError> {
    for (axis, bin) in [("horizontal", bin_x), ("vertical", bin_y)] {
        if !(1..=FLI_MAX_BIN).contains(&bin) {
            return Err(DriverError::InvalidParameter(format!(
                "FLI {axis} binning must be 1 to {FLI_MAX_BIN}, not {bin}"
            )));
        }
    }
    let (start_x, start_y, width, height) = match subframe {
        Some(sf) => {
            let fits_x = u64::from(sf.start_x) + u64::from(sf.width) <= u64::from(visible.width);
            let fits_y = u64::from(sf.start_y) + u64::from(sf.height) <= u64::from(visible.height);
            if !fits_x || !fits_y {
                return Err(DriverError::InvalidParameter(format!(
                    "FLI subframe {}x{} at ({}, {}) does not fit the {}x{} sensor",
                    sf.width, sf.height, sf.start_x, sf.start_y, visible.width, visible.height
                )));
            }
            (sf.start_x, sf.start_y, sf.width, sf.height)
        }
        None => (0, 0, visible.width, visible.height),
    };
    // bin_x/bin_y are 1..=16 here, so the casts are lossless.
    let binned_width = width / bin_x as u32;
    let binned_height = height / bin_y as u32;
    if binned_width == 0 || binned_height == 0 {
        return Err(DriverError::InvalidParameter(format!(
            "FLI subframe {width}x{height} is smaller than one {bin_x}x{bin_y} binned pixel"
        )));
    }
    // Every term is bounded by the visible area, which came from i32 values.
    let ul_x = i64::from(visible.ul_x) + i64::from(start_x);
    let ul_y = i64::from(visible.ul_y) + i64::from(start_y);
    let corner = |value: i64| {
        c_long::try_from(value).map_err(|_| {
            DriverError::InvalidParameter(format!("FLI image area coordinate {value} is too large"))
        })
    };
    Ok(ImageArea {
        ul_x: corner(ul_x)?,
        ul_y: corner(ul_y)?,
        lr_x: corner(ul_x + i64::from(binned_width))?,
        lr_y: corner(ul_y + i64::from(binned_height))?,
        width: binned_width,
        height: binned_height,
    })
}

/// A pixel pitch from FLIGetPixelSize, in microns.
///
/// libfli's documentation says microns, but USB cameras answer in meters: the
/// ProLine/MicroLine parameter block holds meters, and libfli itself writes
/// 7.4e-6 for the ML4022 (libfli-camera-usb.c). INDI (fli_ccd.cpp) and NINA
/// (FLICamera.PixelSizeX) multiply by 1e6. Only the built-in table for the
/// oldest MaxCam and parallel-port bodies holds microns (20.0), so a value
/// below a millimeter is taken as meters. That table has no pitch (0.0) for
/// the CCD47-10 and CCD77 (libfli-camera.c knowndev), so 0 is an unknown
/// pitch, not a fault.
pub(crate) fn pixel_size_microns(reported: c_double) -> Result<Option<f64>, DriverError> {
    if reported == 0.0 {
        return Ok(None);
    }
    if !reported.is_finite() || reported < 0.0 {
        return Err(DriverError::SdkError(format!(
            "FLI camera reported a pixel size of {reported}"
        )));
    }
    let microns = if reported < 1e-3 {
        reported * 1e6
    } else {
        reported
    };
    Ok(Some((microns * 1000.0).round() / 1000.0))
}

/// The exposure time FLISetExposureTime takes, in whole milliseconds.
pub(crate) fn exposure_ms(duration_secs: f64) -> Result<c_long, DriverError> {
    let ms = (duration_secs * 1000.0).round();
    // c_long is 32 bits on Windows; that is 24 days, far past any exposure.
    if !ms.is_finite() || ms < 0.0 || ms > f64::from(i32::MAX) {
        return Err(DriverError::InvalidParameter(format!(
            "FLI exposure time {duration_secs} s is out of range"
        )));
    }
    Ok(ms as c_long)
}

/// Whether a frame can be read, from FLIGetDeviceStatus and
/// FLIGetExposureStatus.
///
/// libfli fills the status with FLI_CAMERA_STATUS_UNKNOWN (all ones) for
/// cameras that cannot report one (MaxCam/IMG bodies, ProLine firmware 1.00,
/// parallel-port cameras), and every bit is set in it, the data-ready bit
/// included. As in FLI's own legacy driver (NINA FLICamera.IsFrameComplete;
/// INDI fli_ccd.cpp TimerHit for the unknown case), a frame is complete when
/// the camera is idle, or cannot say, with no exposure time left, or when it
/// reports data ready.
pub(crate) fn frame_is_complete(status: c_long, time_left_ms: c_long) -> bool {
    // libfli writes 32 bits; c_long is 64 bits on Linux and macOS.
    let status = status as u32;
    let unknown = status == FLI_CAMERA_STATUS_UNKNOWN;
    let idle = unknown || status & FLI_CAMERA_STATUS_MASK == FLI_CAMERA_STATUS_IDLE;
    let data_ready = !unknown && status & FLI_CAMERA_DATA_READY != 0;
    (idle && time_left_ms == 0) || data_ready
}

#[cfg(test)]
mod tests {
    use super::*;

    const SENSOR: VisibleArea = VisibleArea {
        ul_x: 0,
        ul_y: 0,
        width: 64,
        height: 48,
    };

    fn area(ul_x: c_long, ul_y: c_long, lr_x: c_long, lr_y: c_long, w: u32, h: u32) -> ImageArea {
        ImageArea {
            ul_x,
            ul_y,
            lr_x,
            lr_y,
            width: w,
            height: h,
        }
    }

    #[test]
    fn full_frame_at_bin_one_is_the_visible_area() {
        assert_eq!(
            image_area(SENSOR, None, 1, 1).unwrap(),
            area(0, 0, 64, 48, 64, 48)
        );
    }

    /// The lower-right corner is the upper-left plus the binned size.
    #[test]
    fn binned_frame_passes_the_binned_corner() {
        assert_eq!(
            image_area(SENSOR, None, 2, 2).unwrap(),
            area(0, 0, 32, 24, 32, 24)
        );
        assert_eq!(
            image_area(SENSOR, None, 3, 2).unwrap(),
            area(0, 0, 21, 24, 21, 24)
        );
    }

    /// The visible-area origin moves the corner; the subframe is unbinned.
    #[test]
    fn subframe_is_offset_by_the_visible_origin() {
        let visible = VisibleArea {
            ul_x: 12,
            ul_y: 4,
            width: 512,
            height: 512,
        };
        let sf = SubFrame {
            start_x: 8,
            start_y: 4,
            width: 16,
            height: 8,
        };
        assert_eq!(
            image_area(visible, Some(&sf), 1, 1).unwrap(),
            area(20, 8, 36, 16, 16, 8)
        );
        assert_eq!(
            image_area(visible, Some(&sf), 2, 2).unwrap(),
            area(20, 8, 28, 12, 8, 4)
        );
    }

    #[test]
    fn subframe_past_the_sensor_or_below_one_pixel_is_refused() {
        let past = SubFrame {
            start_x: 60,
            start_y: 0,
            width: 8,
            height: 8,
        };
        assert!(matches!(
            image_area(SENSOR, Some(&past), 1, 1),
            Err(DriverError::InvalidParameter(_))
        ));
        let tiny = SubFrame {
            start_x: 0,
            start_y: 0,
            width: 3,
            height: 3,
        };
        assert!(matches!(
            image_area(SENSOR, Some(&tiny), 4, 4),
            Err(DriverError::InvalidParameter(_))
        ));
    }

    #[test]
    fn binning_outside_one_to_sixteen_is_refused() {
        for bin in [0, -1, 17, 99] {
            assert!(matches!(
                image_area(SENSOR, None, bin, 1),
                Err(DriverError::InvalidParameter(_))
            ));
        }
    }

    #[test]
    fn pixel_size_in_meters_becomes_microns() {
        assert_eq!(pixel_size_microns(9e-6).unwrap(), Some(9.0));
        assert_eq!(pixel_size_microns(7.4e-6).unwrap(), Some(7.4));
        assert_eq!(pixel_size_microns(5.4e-6).unwrap(), Some(5.4));
    }

    /// The oldest bodies' built-in table (libfli-camera.c knowndev) is in microns.
    #[test]
    fn pixel_size_table_in_microns_stays() {
        assert_eq!(pixel_size_microns(20.0).unwrap(), Some(20.0));
        assert_eq!(pixel_size_microns(24.0).unwrap(), Some(24.0));
    }

    #[test]
    fn pixel_size_of_zero_is_unknown_and_a_negative_one_an_error() {
        assert_eq!(pixel_size_microns(0.0).unwrap(), None);
        assert!(pixel_size_microns(-9e-6).is_err());
        assert!(pixel_size_microns(f64::NAN).is_err());
    }

    /// 2.01 * 1000 is 2009.9999999999998 in floating point.
    #[test]
    fn exposure_time_rounds_to_the_nearest_millisecond() {
        assert_eq!(exposure_ms(2.01).unwrap(), 2010);
        assert_eq!(exposure_ms(0.0004).unwrap(), 0);
        assert_eq!(exposure_ms(300.0).unwrap(), 300_000);
        assert!(exposure_ms(-1.0).is_err());
        assert!(exposure_ms(f64::NAN).is_err());
        assert!(exposure_ms(3.0e6).is_err());
    }

    /// FLI_CAMERA_STATUS_UNKNOWN has the data-ready bit set like every other.
    #[test]
    fn unknown_status_waits_for_the_exposure_time() {
        let unknown = 0xffff_ffffu32 as c_long;
        assert!(!frame_is_complete(unknown, 500));
        assert!(frame_is_complete(unknown, 0));
    }

    #[test]
    fn known_status_completes_on_data_ready_or_idle_with_no_time_left() {
        let exposing = 0x02;
        let reading = 0x03;
        let data_ready = 0x8000_0000u32 as c_long;
        assert!(!frame_is_complete(exposing, 0));
        assert!(!frame_is_complete(exposing, 900));
        assert!(!frame_is_complete(reading, 0));
        assert!(frame_is_complete(data_ready, 0));
        assert!(frame_is_complete(data_ready | reading, 0));
        assert!(frame_is_complete(0x00, 0));
        assert!(!frame_is_complete(0x00, 300));
    }
}
