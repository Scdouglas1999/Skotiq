//! Frame geometry and color filter rules (pure, unit-tested).

use super::*;

/// A frame region as the libraries take it: binned pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct SdkRoi {
    pub(crate) x: c_int,
    pub(crate) y: c_int,
    pub(crate) w: c_int,
    pub(crate) h: c_int,
}

/// The region one exposure reads.
///
/// `subframe` is Skotiq's ROI: binned pixels, origin at the image's top-left
/// (`ExposureParams::subframe`); `None` is the full sensor. INDI and NINA both
/// hand the libraries binned coordinates (mi_ccd.cpp:509-517,
/// MoravianCamera.cs:350-359). libgxccd counts rows from the bottom
/// (mi_ccd.cpp:514 "libgxccd has 0 on the bottom"), so its origin row is
/// flipped; the Windows drivers take it as it is (NINA).
pub(crate) fn sdk_roi(
    sensor_w: u32,
    sensor_h: u32,
    bin_x: u32,
    bin_y: u32,
    subframe: Option<&SubFrame>,
    bottom_up: bool,
) -> Result<SdkRoi, String> {
    if bin_x == 0 || bin_y == 0 {
        return Err("binning must be at least 1".to_string());
    }
    let full_w = sensor_w / bin_x;
    let full_h = sensor_h / bin_y;
    let (x, y, w, h) = match subframe {
        Some(sf) => (sf.start_x, sf.start_y, sf.width, sf.height),
        None => (0, 0, full_w, full_h),
    };
    if w == 0 || h == 0 {
        return Err(format!(
            "a {}x{} frame is empty at {}x{} binning",
            w, h, bin_x, bin_y
        ));
    }
    let fits = x.checked_add(w).is_some_and(|end| end <= full_w)
        && y.checked_add(h).is_some_and(|end| end <= full_h);
    if !fits {
        return Err(format!(
            "the region {}x{} at ({}, {}) does not fit the {}x{} sensor at {}x{} binning ({}x{} pixels)",
            w, h, x, y, sensor_w, sensor_h, bin_x, bin_y, full_w, full_h
        ));
    }
    let y = if bottom_up { full_h - y - h } else { y };
    let int = |v: u32| c_int::try_from(v).map_err(|_| format!("{} is too large", v));
    Ok(SdkRoi {
        x: int(x)?,
        y: int(y)?,
        w: int(w)?,
        h: int(h)?,
    })
}

/// Reverse the row order of a packed 16-bit frame (mi_ccd.cpp `mirror_image`).
pub(crate) fn mirror_vertical_u16(buf: &mut [u16], width: usize, height: usize) {
    if width == 0 || height < 2 || width.saturating_mul(height) > buf.len() {
        return;
    }
    for row in 0..(height / 2) {
        let top = row * width;
        let bottom = (height - 1 - row) * width;
        for col in 0..width {
            buf.swap(top + col, bottom + col);
        }
    }
}

/// The RGB cell at pixel (0, 0) of the frame the library delivers for the
/// full sensor. "Bayer mask starts on horizontal / vertical odd pixel"
/// (`GBP_DEBAYER_X_ODD` / `_Y_ODD`, gxccd.h:249-252) shifts the RGGB cell by
/// one column / row.
pub(crate) fn delivered_bayer(x_odd: bool, y_odd: bool) -> BayerPattern {
    shift_bayer(BayerPattern::Rggb, x_odd as u32, y_odd as u32)
}

/// The cell seen from a pixel `dx` columns right of and `dy` rows below one
/// whose cell is `cell`.
pub(crate) fn shift_bayer(cell: BayerPattern, dx: u32, dy: u32) -> BayerPattern {
    use BayerPattern::*;
    let cell = if dx % 2 == 1 {
        match cell {
            Rggb => Grbg,
            Grbg => Rggb,
            Gbrg => Bggr,
            Bggr => Gbrg,
            other => other,
        }
    } else {
        cell
    };
    if dy % 2 == 1 {
        match cell {
            Rggb => Gbrg,
            Gbrg => Rggb,
            Grbg => Bggr,
            Bggr => Grbg,
            other => other,
        }
    } else {
        cell
    }
}

/// The cell at pixel (0, 0) of an unbinned frame as Skotiq hands it on (top
/// row first), for a frame whose top-left sensor pixel is (`x`, `y`) counted
/// from the top. `full_frame_cell` is [`delivered_bayer`] for the camera.
/// When the library delivers the bottom row first, the frame is mirrored, so
/// its first pixel is sensor row `sensor_h - 1 - y` of the delivered full
/// frame.
pub(crate) fn frame_bayer(
    full_frame_cell: BayerPattern,
    bottom_up: bool,
    sensor_h: u32,
    x: u32,
    y: u32,
) -> BayerPattern {
    let row = if bottom_up {
        sensor_h.saturating_sub(1).saturating_sub(y)
    } else {
        y
    };
    shift_bayer(full_frame_cell, x, row)
}

/// Bits that hold `max_pixel_value` (12 for 4095, 16 for 65535).
pub(crate) fn bits_for(max_pixel_value: u32) -> u32 {
    (u32::BITS - max_pixel_value.leading_zeros()).clamp(1, 16)
}
