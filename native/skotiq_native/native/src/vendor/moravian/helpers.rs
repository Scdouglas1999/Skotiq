//! Pure helpers (unit-tested).

use super::*;

/// Binned ROI in the coordinate system `gxccd_start_exposure` expects: origin
/// is bottom-up (y grows up), matching `gxccd_read_image`'s Cartesian output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct BinnedRoi {
    pub(crate) x: c_int,
    pub(crate) y: c_int,
    pub(crate) w: c_int,
    pub(crate) h: c_int,
}

/// Convert a top-down, unbinned subframe (or full frame) into the binned,
/// y-flipped ROI `gxccd_start_exposure` requires.
///
/// The reference driver does exactly this at mi_ccd.cpp:510-517:
/// send binned coords, then `fy = (YRes / binY) - y - h` because "libgxccd has
/// 0 on the bottom". The full-frame case collapses to `fy = 0` (unaffected).
pub(crate) fn compute_binned_roi(
    sensor_w: u32,
    sensor_h: u32,
    bin_x: u32,
    bin_y: u32,
    subframe: Option<(u32, u32, u32, u32)>,
) -> Result<BinnedRoi, String> {
    if bin_x == 0 || bin_y == 0 {
        return Err("binning must be >= 1".to_string());
    }
    let full_bw = sensor_w / bin_x;
    let full_bh = sensor_h / bin_y;

    // Subframe origin/size are top-down and in UNBINNED sensor pixels; divide by
    // the bin factor to reach binned coordinates (mi_ccd.cpp:510-513).
    let (xb, yb_top, wb, hb) = match subframe {
        Some((sx, sy, sw, sh)) => (sx / bin_x, sy / bin_y, sw / bin_x, sh / bin_y),
        None => (0, 0, full_bw, full_bh),
    };

    if wb == 0 || hb == 0 {
        return Err("ROI width/height must be > 0 after binning".to_string());
    }
    let x_end = xb
        .checked_add(wb)
        .ok_or_else(|| "ROI x extent overflow".to_string())?;
    let y_end = yb_top
        .checked_add(hb)
        .ok_or_else(|| "ROI y extent overflow".to_string())?;
    if x_end > full_bw || y_end > full_bh {
        return Err(format!(
            "ROI {}x{}+{}+{} exceeds binned sensor {}x{}",
            wb, hb, xb, yb_top, full_bw, full_bh
        ));
    }

    // Top-down y origin -> bottom-up y origin.
    let fy = full_bh - yb_top - hb;

    let to_i32 = |v: u32, what: &str| {
        i32::try_from(v).map_err(|_| format!("Moravian ROI {} value {} exceeds i32", what, v))
    };
    Ok(BinnedRoi {
        x: to_i32(xb, "x")?,
        y: to_i32(fy, "y")?,
        w: to_i32(wb, "w")?,
        h: to_i32(hb, "h")?,
    })
}

/// Vertically mirror a tightly-packed 16-bit image in place (row 0 <-> last
/// row). `gxccd_read_image` returns rows bottom-up (gxccd.h:416-434); the rest
/// of the pipeline expects top-down. Equivalent to mi_ccd.cpp `mirror_image`.
pub(crate) fn mirror_vertical_u16(buf: &mut [u16], width: usize, height: usize) {
    if width == 0 || height < 2 {
        return;
    }
    // Only touch the region we actually own; never index past the slice.
    if width.saturating_mul(height) > buf.len() {
        return;
    }
    for row in 0..(height / 2) {
        let top = row * width;
        let bot = (height - 1 - row) * width;
        for col in 0..width {
            buf.swap(top + col, bot + col);
        }
    }
}

/// RGB Bayer pattern implied by the debayer phase bits, expressed in the SDK's
/// *native* (bottom-up) orientation. `x_odd`/`y_odd` are `GBP_DEBAYER_X_ODD` /
/// `GBP_DEBAYER_Y_ODD` (gxccd.h:249-252).
pub(crate) fn native_bayer(x_odd: bool, y_odd: bool) -> BayerPattern {
    match (x_odd, y_odd) {
        (false, false) => BayerPattern::Rggb,
        (true, false) => BayerPattern::Grbg,
        (false, true) => BayerPattern::Gbrg,
        (true, true) => BayerPattern::Bggr,
    }
}

/// Adjust a Bayer pattern for the vertical mirror we apply to every frame.
/// Reversing the row order of an even-height frame swaps the two Bayer rows.
pub(crate) fn flip_bayer_vertical(p: BayerPattern) -> BayerPattern {
    match p {
        BayerPattern::Rggb => BayerPattern::Gbrg,
        BayerPattern::Gbrg => BayerPattern::Rggb,
        BayerPattern::Grbg => BayerPattern::Bggr,
        BayerPattern::Bggr => BayerPattern::Grbg,
    }
}
