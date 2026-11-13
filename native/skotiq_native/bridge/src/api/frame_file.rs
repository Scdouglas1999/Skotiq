//! A frame file's metadata, read and edited for the app: every format the
//! frame seam opens (FITS, XISF, camera raw), by the rules of
//! `skotiq_imaging`, so the app keeps no reader of its own.

use crate::error::SkotiqError;
use skotiq_imaging::{FitsHeader, SipWcs};
use std::path::Path;

/// One value card of a frame's header, in header order.
#[derive(Debug, Clone, PartialEq)]
pub struct FrameCard {
    pub keyword: String,
    /// The value as plain text: a string without its quotes, a number as the
    /// app's frame writer writes it, `T`/`F` for a boolean.
    pub text: String,
    /// The value when it is a number.
    pub number: Option<f64>,
}

/// A celestial TAN solution as a frame header carries it: degrees, a 1-based
/// reference pixel, the CD matrix in degrees per pixel and the SIP
/// polynomials (orders zero when there is no distortion; coefficients
/// row-major, term `(i, j)` at `i * (order + 1) + j`).
#[derive(Debug, Clone, PartialEq)]
pub struct FrameWcs {
    pub crval1: f64,
    pub crval2: f64,
    pub crpix1: f64,
    pub crpix2: f64,
    pub cd1_1: f64,
    pub cd1_2: f64,
    pub cd2_1: f64,
    pub cd2_2: f64,
    pub a_order: u32,
    pub b_order: u32,
    pub a_coeffs: Vec<f64>,
    pub b_coeffs: Vec<f64>,
    pub ap_order: u32,
    pub bp_order: u32,
    pub ap_coeffs: Vec<f64>,
    pub bp_coeffs: Vec<f64>,
}

impl From<SipWcs> for FrameWcs {
    fn from(w: SipWcs) -> Self {
        Self {
            crval1: w.crval1,
            crval2: w.crval2,
            crpix1: w.crpix1,
            crpix2: w.crpix2,
            cd1_1: w.cd1_1,
            cd1_2: w.cd1_2,
            cd2_1: w.cd2_1,
            cd2_2: w.cd2_2,
            a_order: w.a_order,
            b_order: w.b_order,
            a_coeffs: w.a_coeffs,
            b_coeffs: w.b_coeffs,
            ap_order: w.ap_order,
            bp_order: w.bp_order,
            ap_coeffs: w.ap_coeffs,
            bp_coeffs: w.bp_coeffs,
        }
    }
}

impl From<FrameWcs> for SipWcs {
    fn from(w: FrameWcs) -> Self {
        Self {
            crval1: w.crval1,
            crval2: w.crval2,
            crpix1: w.crpix1,
            crpix2: w.crpix2,
            cd1_1: w.cd1_1,
            cd1_2: w.cd1_2,
            cd2_1: w.cd2_1,
            cd2_2: w.cd2_2,
            a_order: w.a_order,
            b_order: w.b_order,
            a_coeffs: w.a_coeffs,
            b_coeffs: w.b_coeffs,
            ap_order: w.ap_order,
            bp_order: w.bp_order,
            ap_coeffs: w.ap_coeffs,
            bp_coeffs: w.bp_coeffs,
        }
    }
}

/// What a frame file's header says: its value cards, the image size among
/// them (`NAXIS1`, `NAXIS2` and `NAXIS3` for more than one channel, whatever
/// the format), and the astrometry they state.
#[derive(Debug, Clone)]
pub struct FrameHeaderRead {
    pub cards: Vec<FrameCard>,
    /// `None` when the header states no astrometry. What the header says, not
    /// a judgment of it: a matrix that cannot be inverted is returned as is.
    pub wcs: Option<FrameWcs>,
}

fn header_read(header: &FitsHeader) -> FrameHeaderRead {
    let cards = header
        .cards()
        .map(|(keyword, value, _)| FrameCard {
            keyword: keyword.to_string(),
            text: value.to_header_string(),
            number: value.as_f64(),
        })
        .collect();
    FrameHeaderRead {
        cards,
        wcs: SipWcs::from_header(header).map(FrameWcs::from),
    }
}

/// Read a frame file's header without decoding its pixels.
pub async fn api_read_frame_header(file_path: String) -> Result<FrameHeaderRead, SkotiqError> {
    tokio::task::spawn_blocking(move || skotiq_imaging::read_frame_header(Path::new(&file_path)))
        .await
        .map_err(|e| SkotiqError::OperationFailed(format!("Task join error: {e}")))?
        .map(|header| header_read(&header))
        .map_err(|e| SkotiqError::ImageError(format!("Could not read the frame's header: {e}")))
}

/// Write `wcs` into a frame file as its astrometry, in place of any it held,
/// keeping its pixels and every other card.
pub async fn api_write_frame_wcs(file_path: String, wcs: FrameWcs) -> Result<(), SkotiqError> {
    tokio::task::spawn_blocking(move || {
        skotiq_imaging::write_wcs_into_frame(Path::new(&file_path), &SipWcs::from(wcs))
    })
    .await
    .map_err(|e| SkotiqError::OperationFailed(format!("Task join error: {e}")))?
    .map_err(|e| SkotiqError::ImageError(format!("Could not write the frame's astrometry: {e}")))
}

/// One card to set in a frame file's metadata. Exactly one value is given.
#[derive(Debug, Clone)]
pub struct FrameCardUpdate {
    pub keyword: String,
    pub string_value: Option<String>,
    pub int_value: Option<i64>,
    pub double_value: Option<f64>,
    pub comment: Option<String>,
}

/// Set cards in a frame file's metadata, FITS or XISF, keeping its pixels and
/// everything else it holds. The file is replaced whole, never left half
/// written.
pub async fn api_update_frame_cards(
    file_path: String,
    cards: Vec<FrameCardUpdate>,
) -> Result<(), SkotiqError> {
    tokio::task::spawn_blocking(move || {
        skotiq_imaging::rewrite_frame_header(Path::new(&file_path), |header| {
            for card in &cards {
                if let Some(v) = &card.string_value {
                    header.set_string(&card.keyword, v);
                } else if let Some(v) = card.int_value {
                    header.set_int(&card.keyword, v);
                } else if let Some(v) = card.double_value {
                    header.set_float(&card.keyword, v);
                }
                if let Some(comment) = &card.comment {
                    header.set_comment(&card.keyword, comment);
                }
            }
        })
    })
    .await
    .map_err(|e| SkotiqError::OperationFailed(format!("Task join error: {e}")))?
    .map_err(|e| SkotiqError::ImageError(format!("Could not update the frame's metadata: {e}")))
}

#[cfg(test)]
mod tests;
