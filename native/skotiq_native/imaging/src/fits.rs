//! Real FITS file I/O
//!
//! Implements actual FITS file reading and writing according to the
//! FITS standard (NASA/Science Office of Standards and Technology).
//!
//! FITS format:
//! - 2880-byte blocks
//! - Header with 80-character keyword records
//! - Data in big-endian format
//!
//! # `as`-cast policy
//!
//! FITS pixel I/O involves many wire-format scalar casts. They cluster into:
//! - **BITPIX dispatch** (`bitpix as i32`): FITS BITPIX is an integer in
//!   {8, 16, 32, 64, -32, -64}. The cast is over a small set of statically
//!   known constants.
//! - **Pixel-buffer rescaling**: `v as f64 * bscale + bzero` saturating into
//!   {u8,u16,u32,f32}. The `.clamp(...)` and `as` saturation match the FITS
//!   spec's expectation that out-of-range scaled values are clipped.
//! - **`width * height * depth`** in `(_ as usize)` form: these are u32 image
//!   dimensions; for sensors below ~46340x46340x1 the u32 multiply fits, and
//!   the resulting size is also valid usize. Allocation failure surfaces from
//!   `Vec` itself on >RAM sizes.
//!
//! Sites with their own `Why:` comment override the module-level reasoning.

#[cfg(test)]
use crate::BayerPattern;
use crate::{ColorFilterArray, ImageData, PixelType};
use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{BufReader, BufWriter, Read, Seek, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

/// A FITS file is a whole number of 2880-byte records; header and data are each
/// padded out to one (FITS 3.1).
const FITS_RECORD_LEN: usize = 2880;

/// FITS header containing all keywords plus separate COMMENT and HISTORY blocks.
///
/// Why: COMMENT and HISTORY are not value cards — they have no `=` separator and
/// the card body is a free-form text run from columns 9..80. Storing them in the
/// same `keywords` map as value cards (with synthetic names like `COMMENT_3`)
/// produced malformed cards on writeback and silently corrupted round-trips.
#[derive(Debug, Clone, Default)]
pub struct FitsHeader {
    /// Keyword-value pairs (uppercase keys; never includes COMMENT/HISTORY).
    pub keywords: HashMap<String, FitsValue>,
    /// Keywords in original order (for stable rewrite).
    keyword_order: Vec<String>,
    /// Optional inline comment text for each keyword (`KEY = value / comment`).
    keyword_comments: HashMap<String, String>,
    /// COMMENT text in original order, one entry per LOGICAL line rather than
    /// per 80-column card. See [`commentary_cards`] for the split.
    pub comments: Vec<String>,
    /// HISTORY text in original order, one entry per logical line.
    pub history: Vec<String>,
}

/// FITS value types. COMMENT/HISTORY are intentionally NOT a value variant —
/// they live in `FitsHeader::comments` and `FitsHeader::history` because they
/// are not value cards in the FITS sense.
#[derive(Debug, Clone)]
pub enum FitsValue {
    String(String),
    Integer(i64),
    Float(f64),
    Boolean(bool),
    /// Retained only for backward source compatibility; never produced by the
    /// reader and treated as a free-form value-style string by the writer.
    Comment(String),
}

impl FitsValue {
    pub fn as_string(&self) -> Option<&str> {
        match self {
            FitsValue::String(s) => Some(s),
            _ => None,
        }
    }

    pub fn as_i64(&self) -> Option<i64> {
        match self {
            FitsValue::Integer(i) => Some(*i),
            FitsValue::Float(f) => Some(*f as i64),
            _ => None,
        }
    }

    pub fn as_f64(&self) -> Option<f64> {
        match self {
            FitsValue::Float(f) => Some(*f),
            FitsValue::Integer(i) => Some(*i as f64),
            _ => None,
        }
    }

    pub fn as_bool(&self) -> Option<bool> {
        match self {
            FitsValue::Boolean(b) => Some(*b),
            _ => None,
        }
    }

    /// The value as plain header text: the string body without its FITS
    /// quoting, the number as `write_fits` would render it, `T`/`F` for a
    /// boolean.
    ///
    /// Why this and not `format!("{:?}", value)`: Debug emits the Rust variant
    /// syntax (`Float(120.0)`), and any consumer that carries a flattened
    /// header back into a FITS file then ships `EXPTIME = 'Float(120.0)'`.
    pub fn to_header_string(&self) -> String {
        match self {
            FitsValue::String(s) => s.clone(),
            FitsValue::Integer(i) => i.to_string(),
            FitsValue::Float(f) => format_fits_float(*f),
            FitsValue::Boolean(b) => if *b { "T" } else { "F" }.to_string(),
            FitsValue::Comment(c) => c.clone(),
        }
    }
}

impl FitsHeader {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_string(&mut self, key: &str, value: &str) {
        let key_upper = key.to_uppercase();
        if !self.keyword_order.contains(&key_upper) {
            self.keyword_order.push(key_upper.clone());
        }
        self.keywords
            .insert(key_upper, FitsValue::String(value.to_string()));
    }

    pub fn set_int(&mut self, key: &str, value: i64) {
        let key_upper = key.to_uppercase();
        if !self.keyword_order.contains(&key_upper) {
            self.keyword_order.push(key_upper.clone());
        }
        self.keywords.insert(key_upper, FitsValue::Integer(value));
    }

    pub fn set_float(&mut self, key: &str, value: f64) {
        let key_upper = key.to_uppercase();
        if !self.keyword_order.contains(&key_upper) {
            self.keyword_order.push(key_upper.clone());
        }
        self.keywords.insert(key_upper, FitsValue::Float(value));
    }

    pub fn set_bool(&mut self, key: &str, value: bool) {
        let key_upper = key.to_uppercase();
        if !self.keyword_order.contains(&key_upper) {
            self.keyword_order.push(key_upper.clone());
        }
        self.keywords.insert(key_upper, FitsValue::Boolean(value));
    }

    /// State the image size as a FITS file does: `NAXIS`, `NAXIS1` (width),
    /// `NAXIS2` (height) and, for more than one channel, `NAXIS3`. Every
    /// format's header read gives these, so a caller learns a frame's size
    /// without decoding it.
    pub fn set_image_size(&mut self, width: u32, height: u32, channels: u32) {
        self.set_int("NAXIS", if channels > 1 { 3 } else { 2 });
        self.set_int("NAXIS1", i64::from(width));
        self.set_int("NAXIS2", i64::from(height));
        if channels > 1 {
            self.set_int("NAXIS3", i64::from(channels));
        }
    }

    /// Attach an inline comment to an existing keyword. Emitted as
    /// `KEY = value / comment` on write, truncated if the card would exceed 80 bytes.
    pub fn set_comment(&mut self, key: &str, comment: &str) {
        self.keyword_comments
            .insert(key.to_uppercase(), comment.to_string());
    }

    /// Append a free-form COMMENT line.
    ///
    /// One LOGICAL line, of any length: the writer breaks it across as many
    /// cards as it needs at a token boundary with an explicit continuation, and
    /// the reader puts it back together. See [`commentary_cards`].
    pub fn add_comment(&mut self, text: &str) {
        self.comments.push(text.to_string());
    }

    /// Append a HISTORY line. One logical line of any length — see
    /// [`Self::add_comment`] for how it reaches the file.
    pub fn add_history(&mut self, text: &str) {
        self.history.push(text.to_string());
    }

    /// Remove a keyword (and any inline comment) from the header.
    pub(crate) fn remove(&mut self, key: &str) {
        let key_upper = key.to_uppercase();
        self.keywords.remove(&key_upper);
        self.keyword_comments.remove(&key_upper);
        self.keyword_order.retain(|k| k != &key_upper);
    }

    pub fn get(&self, key: &str) -> Option<&FitsValue> {
        self.keywords.get(&key.to_uppercase())
    }

    pub fn get_string(&self, key: &str) -> Option<&str> {
        self.get(key).and_then(|v| v.as_string())
    }

    pub fn get_int(&self, key: &str) -> Option<i64> {
        self.get(key).and_then(|v| v.as_i64())
    }

    pub fn get_float(&self, key: &str) -> Option<f64> {
        self.get(key).and_then(|v| v.as_f64())
    }

    pub fn get_bool(&self, key: &str) -> Option<bool> {
        self.get(key).and_then(|v| v.as_bool())
    }

    pub fn get_comment(&self, key: &str) -> Option<&str> {
        self.keyword_comments
            .get(&key.to_uppercase())
            .map(|s| s.as_str())
    }

    /// Width and height in pixels (`NAXIS1`, `NAXIS2`); `None` unless both
    /// are positive whole numbers.
    pub fn image_size(&self) -> Option<(u32, u32)> {
        let axis = |key: &str| {
            self.get_int(key)
                .filter(|n| *n > 0)
                .and_then(|n| u32::try_from(n).ok())
        };
        Some((axis("NAXIS1")?, axis("NAXIS2")?))
    }

    /// Image planes (`NAXIS3`): 1 when the card is missing or not positive.
    pub fn planes(&self) -> u32 {
        match self.get_int("NAXIS3").and_then(|n| u32::try_from(n).ok()) {
            Some(planes) if planes > 0 => planes,
            _ => 1,
        }
    }

    /// Every value card in header order: keyword, value, inline comment.
    pub fn cards(&self) -> impl Iterator<Item = (&str, &FitsValue, Option<&str>)> {
        self.keyword_order.iter().filter_map(|key| {
            self.keywords
                .get(key)
                .map(|value| (key.as_str(), value, self.get_comment(key)))
        })
    }
}

/// The text of a value as it stands on a card: strings quoted with inner
/// quotes doubled, numbers as `write_fits` writes them, `T`/`F`.
pub(crate) fn value_card_text(value: &FitsValue) -> String {
    match value {
        FitsValue::String(s) | FitsValue::Comment(s) => format!("'{}'", s.replace('\'', "''")),
        FitsValue::Integer(i) => i.to_string(),
        FitsValue::Float(f) => format_fits_float(*f),
        FitsValue::Boolean(b) => if *b { "T" } else { "F" }.to_string(),
    }
}

/// Read value text as it stands on a card, without a comment.
pub(crate) fn parse_value_card_text(text: &str) -> FitsValue {
    let t = text.trim();
    if let Some(body) = t.strip_prefix('\'') {
        let body = body.strip_suffix('\'').unwrap_or(body);
        return FitsValue::String(body.replace("''", "'").trim_end().to_string());
    }
    match parse_fits_value(t) {
        Ok(value) if !t.contains('/') => value,
        _ => FitsValue::String(t.to_string()),
    }
}

#[derive(Debug)]
pub enum FitsError {
    Io(std::io::Error),
    InvalidFormat(String),
    UnsupportedBitpix(i32),
    MissingKeyword(String),
    /// FITS files with NAXIS > 3 (4-D cubes / hyperspectral) are not supported.
    /// Why: silently dropping planes corrupts science data; explicit failure forces
    /// the caller to choose a real handling strategy.
    Unsupported4DCube {
        naxis: i64,
    },
    /// Caller passed a sub-horizon altitude to an airmass routine; the optical
    /// path is undefined below the horizon. The caller decides how to handle.
    BelowHorizon {
        altitude_degrees: f64,
    },
}

impl std::fmt::Display for FitsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FitsError::Io(e) => write!(f, "IO error: {}", e),
            FitsError::InvalidFormat(s) => write!(f, "Invalid FITS format: {}", s),
            FitsError::UnsupportedBitpix(b) => write!(f, "Unsupported BITPIX: {}", b),
            FitsError::MissingKeyword(k) => write!(f, "Missing required keyword: {}", k),
            FitsError::Unsupported4DCube { naxis } => write!(
                f,
                "Unsupported FITS dimensionality: NAXIS={} (only NAXIS<=3 is supported)",
                naxis
            ),
            FitsError::BelowHorizon { altitude_degrees } => write!(
                f,
                "Altitude {:.4}° is below the horizon; airmass is undefined",
                altitude_degrees
            ),
        }
    }
}

impl std::error::Error for FitsError {}

impl From<std::io::Error> for FitsError {
    fn from(e: std::io::Error) -> Self {
        FitsError::Io(e)
    }
}

pub fn read_fits(path: &Path) -> Result<(ImageData, FitsHeader), FitsError> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    read_fits_from_reader(&mut reader)
}

pub fn read_fits_from_bytes(bytes: &[u8]) -> Result<(ImageData, FitsHeader), FitsError> {
    let mut reader = std::io::Cursor::new(bytes);
    read_fits_from_reader(&mut reader)
}

/// Read only the primary HDU's header, without decoding the pixel data.
///
/// Callers that need a frame's metadata (exposure, sensor temperature, gain,
/// observation date, astrometry) but not its samples pay the header records
/// only, instead of a full-sensor decode. The returned header is identical to
/// the one [`read_fits`] yields: `BZERO`/`BSCALE` are stripped because they
/// describe an encoding this reader would have folded into the samples, so a
/// header from either entry point compares equal card for card.
pub fn read_fits_header(path: &Path) -> Result<FitsHeader, FitsError> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);
    let mut header = read_header(&mut reader)?;
    header.remove("BZERO");
    header.remove("BSCALE");
    header.remove(crate::fits_reader::RANGE_LOW_CARD);
    header.remove(crate::fits_reader::RANGE_HIGH_CARD);
    Ok(header)
}

/// True for a keyword that describes where on the sky a pixel grid points:
/// the FITS WCS core (`CRVAL`/`CRPIX`/`CD`/`PC`/`CDELT`/`CROTA`/`CTYPE`/`CUNIT`
/// /`PV`), the reference-frame cards (`EQUINOX`, `RADESYS`/`RADECSYS`,
/// `LONPOLE`, `LATPOLE`, `WCSAXES`), and the SIP distortion polynomials
/// (`A_ORDER`/`B_ORDER`/`AP_ORDER`/`BP_ORDER` plus every `A_i_j`, `B_i_j`,
/// `AP_i_j`, `BP_i_j` term, Shupe et al. 2005).
///
/// The set is closed over what [`crate::SipWcs::write_to_header`] writes and what ASTAP /
/// astrometry.net stamp, so a solved frame's astrometry survives a copy in
/// full — a partial copy (CD without CTYPE, or CRVAL without SIP) yields a
/// header that reads as solved while projecting to the wrong sky position.
pub fn is_astrometry_keyword(key: &str) -> bool {
    match key {
        "EQUINOX" | "RADESYS" | "RADECSYS" | "LONPOLE" | "LATPOLE" | "WCSAXES" => return true,
        _ => {}
    }
    // `CRVAL1`, `CTYPE2`, `CDELT1`, `CROTA2`, `CUNIT1`, `CRPIX2` — one axis digit.
    for stem in ["CRVAL", "CRPIX", "CDELT", "CROTA", "CTYPE", "CUNIT"] {
        if let Some(rest) = key.strip_prefix(stem) {
            if is_all_digits(rest) {
                return true;
            }
        }
    }
    // `CD1_1`, `PC2_1`, `PV1_17` — two index groups separated by `_`.
    for stem in ["CD", "PC", "PV"] {
        if let Some(rest) = key.strip_prefix(stem) {
            if is_index_pair(rest) {
                return true;
            }
        }
    }
    // SIP: `A_ORDER`/`AP_ORDER` and the `A_2_1`-style coefficient terms.
    for stem in ["A", "B", "AP", "BP"] {
        if let Some(rest) = key.strip_prefix(stem) {
            if rest == "_ORDER" {
                return true;
            }
            if let Some(indices) = rest.strip_prefix('_') {
                if is_index_pair(indices) {
                    return true;
                }
            }
        }
    }
    false
}

/// True for a keyword that identifies *what was observed and with what*, and
/// stays true of a frame that has been rescaled, rebalanced, or filtered in
/// place: target, filter, timing and pointing, plus the instrument
/// ([`is_instrument_keyword`]).
///
/// Deliberately excluded: `BAYERPAT`/`XBAYROFF`/`YBAYROFF`. A CFA pattern
/// describes a raw mosaic; carrying it onto a debayered or integrated frame
/// makes a downstream reader debayer an already-colour image.
pub fn is_observation_keyword(key: &str) -> bool {
    is_instrument_keyword(key)
        || matches!(
            key,
            "OBJECT"
                | "OBJCTRA"
                | "OBJCTDEC"
                | "RA"
                | "DEC"
                | "FILTER"
                | "DATE-OBS"
                | "DATE-END"
                | "EXPTIME"
                | "EXPOSURE"
                | "AIRMASS"
        )
}

/// True for a keyword that describes the instrument and site a frame was
/// taken with: optics, sensor and its settings, observer and site. These stay
/// true of a product combined from many exposures of one setup, which the
/// rest of [`is_observation_keyword`] (one exposure's timing and pointing) do
/// not.
pub fn is_instrument_keyword(key: &str) -> bool {
    matches!(
        key,
        "TELESCOP"
            | "INSTRUME"
            | "OBSERVER"
            | "FOCALLEN"
            | "APTDIA"
            | "APTAREA"
            | "XPIXSZ"
            | "YPIXSZ"
            | "PIXSIZE1"
            | "PIXSIZE2"
            | "XBINNING"
            | "YBINNING"
            | "GAIN"
            | "EGAIN"
            | "OFFSET"
            | "CCD-TEMP"
            | "SET-TEMP"
            | "READOUTM"
            | "SITELAT"
            | "SITELONG"
            | "SITEELEV"
    )
}

/// True when `s` is one or more ASCII digits.
fn is_all_digits(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit())
}

/// True when `s` is `<digits>_<digits>` — the FITS matrix/polynomial index form.
fn is_index_pair(s: &str) -> bool {
    match s.split_once('_') {
        Some((a, b)) => is_all_digits(a) && is_all_digits(b),
        None => false,
    }
}

/// Copy every card `keep` accepts from `src` into `dst`, in `src`'s card order,
/// and return how many were copied.
///
/// A key already present in `dst` is left alone: the writer that built `dst`
/// stated something about its own output (`IMAGETYP`, a recomputed `EXPTIME`)
/// and the source frame must not overwrite it. Iteration follows the source's
/// recorded card order, never the keyword map, so the output header is
/// byte-identical for identical inputs.
pub fn copy_header_cards(
    dst: &mut FitsHeader,
    src: &FitsHeader,
    keep: impl Fn(&str) -> bool,
) -> usize {
    let mut copied = 0usize;
    for key in &src.keyword_order {
        if !keep(key) || dst.keywords.contains_key(key) {
            continue;
        }
        let Some(value) = src.keywords.get(key) else {
            continue;
        };
        dst.keyword_order.push(key.clone());
        dst.keywords.insert(key.clone(), value.clone());
        if let Some(comment) = src.keyword_comments.get(key) {
            dst.keyword_comments.insert(key.clone(), comment.clone());
        }
        copied += 1;
    }
    copied
}

/// Carry the source frame's astrometry ([`is_astrometry_keyword`]) into `dst`,
/// returning the number of cards copied (`0` when the source is unsolved).
///
/// Every op that leaves the pixel grid alone — background extraction, colour
/// calibration, star reduction, deconvolution — must call this, or the frame it
/// writes reads as unsolved and the next op in the chain has no sky reference.
pub fn copy_astrometry_headers(dst: &mut FitsHeader, src: &FitsHeader) -> usize {
    copy_header_cards(dst, src, is_astrometry_keyword)
}

/// Give `dst` the astrometry of `src` in place of its own, returning the
/// number of cards copied: every astrometry card `dst` held goes first, so no
/// earlier `PC` matrix or SIP polynomial is read on top of `src`'s solution.
pub fn replace_astrometry_headers(dst: &mut FitsHeader, src: &FitsHeader) -> usize {
    remove_astrometry_headers(dst);
    copy_astrometry_headers(dst, src)
}

/// Remove every astrometry card ([`is_astrometry_keyword`]) from `header`.
pub fn remove_astrometry_headers(header: &mut FitsHeader) {
    let astrometry: Vec<String> = header
        .cards()
        .map(|(key, _, _)| key)
        .filter(|key| is_astrometry_keyword(key))
        .map(str::to_string)
        .collect();
    for key in astrometry {
        header.remove(&key);
    }
}

/// Carry the source frame's observation identity ([`is_observation_keyword`])
/// into `dst`, returning the number of cards copied.
fn copy_observation_headers(dst: &mut FitsHeader, src: &FitsHeader) -> usize {
    copy_header_cards(dst, src, is_observation_keyword)
}

/// Carry a source frame's astrometry **and** observation identity into the
/// header a same-geometry processing step is about to write, recording the
/// counts as a `HISTORY` card.
///
/// For any op that transforms pixel values while leaving the pixel grid alone,
/// the input's WCS still describes the output exactly, so dropping it would
/// strand the result: nothing downstream could plate-match it, and the next op
/// in a chain would inherit no sky reference at all. The counts are written even
/// when they are zero, so an unsolved input reads as unsolved rather than as an
/// unexplained absence.
///
/// **Not** for a step that changes the grid — a drizzle, a resample, a crop.
/// Those must recompute `CRPIX`/`CD` for the new grid; copying the input's cards
/// would produce a header that reads as solved and points at the wrong sky.
pub fn carry_source_header(dst: &mut FitsHeader, src: &FitsHeader) {
    let astrometry = copy_astrometry_headers(dst, src);
    let observation = copy_observation_headers(dst, src);
    dst.add_history(&format!(
        "Carried {astrometry} astrometry and {observation} observation cards from the input frame"
    ));
}

/// The image geometry a FITS header describes, plus the pixel type its BITPIX
/// selects.
///
/// `NAXIS = 0` (header-only HDU) is an error here; `read_fits_from_reader`
/// answers it with an empty image before asking, which is its own documented
/// behaviour rather than a shared one.
pub(crate) fn geometry_from_header(
    header: &FitsHeader,
) -> Result<(u32, u32, u32, PixelType), FitsError> {
    let bitpix = header
        .get_int("BITPIX")
        .ok_or_else(|| FitsError::MissingKeyword("BITPIX".to_string()))?;
    let naxis = header
        .get_int("NAXIS")
        .ok_or_else(|| FitsError::MissingKeyword("NAXIS".to_string()))?;

    if naxis == 0 {
        return Err(FitsError::InvalidFormat(
            "No image data in FITS file".to_string(),
        ));
    }

    // Why: 4-D cubes (NAXIS > 3) cannot be represented by `ImageData` (which has a
    // single channel/depth axis). Silently loading only the first plane corrupts
    // science workflows that depend on the full cube. Reject explicitly
    if naxis > 3 {
        return Err(FitsError::Unsupported4DCube { naxis });
    }

    let width = header
        .get_int("NAXIS1")
        .ok_or_else(|| FitsError::MissingKeyword("NAXIS1".to_string()))? as u32;
    let height = if naxis >= 2 {
        header
            .get_int("NAXIS2")
            .ok_or_else(|| FitsError::MissingKeyword("NAXIS2".to_string()))? as u32
    } else {
        1
    };
    let depth = if naxis >= 3 {
        header
            .get_int("NAXIS3")
            .ok_or_else(|| FitsError::MissingKeyword("NAXIS3".to_string()))? as u32
    } else {
        1
    };

    let pixel_type = match bitpix as i32 {
        8 => PixelType::U8,
        16 => PixelType::U16,
        32 => PixelType::U32,
        -32 => PixelType::F32,
        -64 => PixelType::F64,
        other => return Err(FitsError::UnsupportedBitpix(other)),
    };

    Ok((width, height, depth, pixel_type))
}

fn read_fits_from_reader<R: Read>(reader: &mut R) -> Result<(ImageData, FitsHeader), FitsError> {
    crate::fits_reader::FitsReader::open(reader)?.into_image()
}

/// Read the FITS header (80-character records until END)
pub(crate) fn read_header<R: Read>(reader: &mut R) -> Result<FitsHeader, FitsError> {
    read_header_measured(reader).map(|(header, _)| header)
}

/// [`read_header`], also reporting how many bytes it consumed: the header
/// records and their padding, so the data unit starts that far in.
pub(crate) fn read_header_measured<R: Read>(
    reader: &mut R,
) -> Result<(FitsHeader, u64), FitsError> {
    let mut header = FitsHeader::new();
    let mut buffer = [0u8; 80];
    let mut total_records: usize = 0;
    const MAX_HEADER_RECORDS: usize = 65_536;
    // The keyword whose string value ended in `&` on the card just read.
    let mut open_long_string: Option<String> = None;

    loop {
        reader.read_exact(&mut buffer)?;
        total_records += 1;
        if total_records > MAX_HEADER_RECORDS {
            return Err(FitsError::InvalidFormat(
                "FITS header exceeds maximum supported size or is missing END".to_string(),
            ));
        }

        // FITS records are a fixed 80-column ASCII grid. Slice the raw byte
        // buffer at the fixed columns (always in range) instead of byte-indexing
        // a lossy UTF-8 string: `String::from_utf8_lossy` maps each non-ASCII
        // byte to a 3-byte U+FFFD, which can straddle the column-8/10 boundary
        // and make `record[..8]`/`record[8..10]` panic ("byte index N is not a
        // char boundary"). A corrupted or partially-downloaded BLOB, or a camera
        // that emits binary bytes in the header area, must not crash capture.
        let keyword_cow = String::from_utf8_lossy(&buffer[..8]);
        let keyword = keyword_cow.trim();

        if keyword == "END" {
            break;
        }
        // Only the card right after a string ending in `&` carries it on.
        let continued_key = open_long_string.take();

        if keyword.is_empty() || keyword.starts_with(' ') {
            continue; // Blank or comment
        }

        if !is_valid_keyword(keyword) && keyword != "COMMENT" && keyword != "HISTORY" {
            return Err(FitsError::InvalidFormat(invalid_keyword_message(
                &buffer[..8],
                total_records,
            )));
        }

        // Parse the card. COMMENT/HISTORY cards have NO `=` separator per FITS 4.4.2.4
        // and their text occupies columns 9..80; route them to dedicated vectors so
        // they are never mistaken for value cards and re-emitted with `=`.
        if keyword == CONTINUE_KEYWORD {
            if let Some(key) = continued_key {
                let raw_after = String::from_utf8_lossy(&buffer[10..]);
                open_long_string = continue_long_string(&mut header, key, &raw_after);
            }
        } else if keyword == "COMMENT" {
            let text = String::from_utf8_lossy(&buffer[8..]).trim_end().to_string();
            header.comments.push(text);
        } else if keyword == "HISTORY" {
            let text = String::from_utf8_lossy(&buffer[8..]).trim_end().to_string();
            header.history.push(text);
        } else if &buffer[8..10] == b"= " {
            let raw_after = String::from_utf8_lossy(&buffer[10..]);
            open_long_string = insert_value_card(&mut header, keyword.to_string(), &raw_after)?;
        } else if keyword == HIERARCH_KEYWORD {
            let raw_after = String::from_utf8_lossy(&buffer[8..]);
            if let Some((name, value_text)) = raw_after.split_once('=') {
                let name = name.split_whitespace().collect::<Vec<_>>().join(" ");
                if !name.is_empty() {
                    open_long_string =
                        insert_value_card(&mut header, name.to_ascii_uppercase(), value_text)?;
                }
            }
        }
    }

    // Rejoin the commentary blocks. `comments` and `history` hold LOGICAL
    // lines — a line too long for one card was split by `commentary_cards` at
    // write time and is put back together here, so a path or a digest that
    // overran column 80 reads whole instead of as two entries a consumer has to
    // guess how to concatenate.
    header.comments = join_commentary_cards(std::mem::take(&mut header.comments));
    header.history = join_commentary_cards(std::mem::take(&mut header.history));
    // It describes the CONTINUE cards just folded into whole values; a writer
    // states it again when it needs to.
    header.remove(LONG_STRING_KEYWORD);

    // Skip to next 2880-byte boundary
    // The header is padded with spaces to a multiple of 2880 bytes
    // Use total_records (which counts every 80-byte record including
    // COMMENT, HISTORY, blanks, and END) for accurate padding calculation.
    let header_bytes = total_records * 80;
    let padding = (2880 - (header_bytes % 2880)) % 2880;
    if padding > 0 {
        let mut skip = vec![0u8; padding];
        reader.read_exact(&mut skip)?;
    }

    Ok((header, (header_bytes + padding) as u64))
}

/// Store the value and inline comment of a card under `key`. Returns `key`
/// when the value is a string ending in `&`, which the next CONTINUE card may
/// carry on.
fn insert_value_card(
    header: &mut FitsHeader,
    key: String,
    raw_after: &str,
) -> Result<Option<String>, FitsError> {
    let (value_part, comment_part) = split_value_and_comment(raw_after);
    let value = parse_fits_value(value_part)?;
    let open = matches!(&value, FitsValue::String(s) if s.ends_with(LONG_STRING_CONTINUATION))
        && value_part.starts_with('\'');
    header.keywords.insert(key.clone(), value);
    if !header.keyword_order.contains(&key) {
        header.keyword_order.push(key.clone());
    }
    if let Some(comment) = comment_part.map(str::trim).filter(|c| !c.is_empty()) {
        header
            .keyword_comments
            .insert(key.clone(), comment.to_string());
    }
    Ok(open.then_some(key))
}

/// Add one CONTINUE card's piece to the string value of `key`, whose text so
/// far ends in the `&` that asked for it, and its comment to the key's
/// comment. Returns `key` again when this piece ends in `&` too.
///
/// A CONTINUE card that is not a quoted string ends the value as it stands,
/// `&` and all, as cfitsio reads it.
fn continue_long_string(header: &mut FitsHeader, key: String, raw_after: &str) -> Option<String> {
    let (value_part, comment_part) = split_value_and_comment(raw_after);
    if !value_part.starts_with('\'') {
        return None;
    }
    let piece = quoted_string_body(value_part).ok()?;
    let Some(FitsValue::String(text)) = header.keywords.get_mut(&key) else {
        return None;
    };
    text.pop();
    text.push_str(&piece);
    let open = piece.ends_with(LONG_STRING_CONTINUATION);
    if !open {
        let joined = text.trim().to_string();
        *text = joined;
    }
    if let Some(comment) = comment_part.map(str::trim).filter(|c| !c.is_empty()) {
        header
            .keyword_comments
            .entry(key.clone())
            .and_modify(|text| {
                text.push(' ');
                text.push_str(comment);
            })
            .or_insert_with(|| comment.to_string());
    }
    open.then_some(key)
}

/// Length of one FITS header card, fixed by the standard.
const CARD_LEN: usize = 80;

/// Split header text into its cards.
///
/// A FITS header on disk is fixed-width 80-character cards packed end to end
/// with **no line terminators**; iterating one with `str::lines()` yields the
/// whole header as a single line, so only the first card is ever seen. Text
/// that does carry newlines (some solvers write one card per line) is split
/// on them first, and any segment longer than a card is split by width.
pub fn header_text_cards(content: &str) -> Vec<&str> {
    let mut cards = Vec::new();
    for segment in content.lines() {
        if segment.len() <= CARD_LEN {
            cards.push(segment);
            continue;
        }
        let bytes = segment.as_bytes();
        let mut start = 0;
        while start < bytes.len() {
            let end = (start + CARD_LEN).min(bytes.len());
            // A FITS header is ASCII, so every card boundary is a char
            // boundary. Anything else is not a header that can be split by
            // width; what is left is handed back in one piece.
            match std::str::from_utf8(&bytes[start..end]) {
                Ok(card) => cards.push(card),
                Err(_) => {
                    cards.push(&segment[start..]);
                    break;
                }
            }
            start = end;
        }
    }
    cards
}

/// A header written out as text (a solver's `.wcs` sidecar), read by the
/// same card rules as a file's header: [`header_text_cards`] splits it and
/// each card is read as the reader reads records. An `END` card is not
/// required.
pub fn header_from_text(content: &str) -> Result<FitsHeader, FitsError> {
    let mut records: Vec<u8> = Vec::new();
    for card in header_text_cards(content) {
        let bytes = &card.as_bytes()[..card.len().min(CARD_LEN)];
        if bytes[..bytes.len().min(8)].trim_ascii_end() == b"END" {
            break;
        }
        let mut record = [b' '; CARD_LEN];
        record[..bytes.len()].copy_from_slice(bytes);
        records.extend_from_slice(&record);
    }
    let mut end = [b' '; CARD_LEN];
    end[..3].copy_from_slice(b"END");
    records.extend_from_slice(&end);
    records.resize(records.len().div_ceil(2880) * 2880, b' ');
    read_header(&mut std::io::Cursor::new(records))
}

/// The keyword and raw value text of a value card (`KEYWORD = value /
/// comment`), comment removed and both trimmed. `None` for a card with no
/// value indicator (`COMMENT`, `HISTORY`, `END`, blanks).
pub fn card_keyword_and_value(card: &str) -> Option<(&str, &str)> {
    let keyword = card.get(..8)?.trim();
    let rest = card.get(8..)?;
    if card.len() < 10 || !rest.starts_with('=') {
        return None;
    }
    let (value, _) = split_value_and_comment(card.get(10..)?);
    Some((keyword, value.trim()))
}

/// Parse a FITS value from string. `s` may still contain a trailing `/ comment`;
/// callers that have already split the comment off can pass either form.
fn parse_fits_value(s: &str) -> Result<FitsValue, FitsError> {
    let s = s.trim();
    let (value_part, _) = split_value_and_comment(s);

    if value_part.starts_with('\'') {
        return quoted_string_body(value_part)
            .map(|body| FitsValue::String(body.trim().to_string()));
    }

    if value_part == "T" {
        return Ok(FitsValue::Boolean(true));
    }
    if value_part == "F" {
        return Ok(FitsValue::Boolean(false));
    }

    if let Ok(i) = value_part.parse::<i64>() {
        return Ok(FitsValue::Integer(i));
    }

    if let Ok(f) = value_part
        .replace('D', "E")
        .replace('d', "e")
        .parse::<f64>()
    {
        return Ok(FitsValue::Float(f));
    }

    Ok(FitsValue::String(value_part.to_string()))
}

/// The text of a quoted FITS string, `''` read as one quote, trailing spaces
/// dropped (FITS 4.2.1.1: they are not significant, leading ones are).
fn quoted_string_body(value_part: &str) -> Result<String, FitsError> {
    let mut body = String::new();
    let mut chars = value_part.strip_prefix('\'').unwrap_or(value_part).chars();
    loop {
        match chars.next() {
            Some('\'') if chars.clone().next() == Some('\'') => {
                chars.next();
                body.push('\'');
            }
            Some('\'') => return Ok(body.trim_end().to_string()),
            Some(ch) => body.push(ch),
            None => {
                return Err(FitsError::InvalidFormat(
                    "Unterminated FITS string literal".to_string(),
                ))
            }
        }
    }
}

fn split_value_and_comment(s: &str) -> (&str, Option<&str>) {
    let mut in_string = false;
    for (idx, ch) in s.char_indices() {
        match ch {
            '\'' => in_string = !in_string,
            '/' if !in_string => return (s[..idx].trim(), Some(s[idx + 1..].trim())),
            _ => {}
        }
    }
    (s.trim(), None)
}

/// Name what sits in the keyword field of a record that holds no valid keyword.
///
/// The eight raw bytes never go into the message verbatim. A torn write or a
/// lost extent leaves NUL bytes where a card belongs, and a message carrying
/// those NULs dies on the way out: it crosses the FFI as a C string and arrives
/// empty, so the operator is told a master failed and given no reason at all.
/// Every byte outside printable ASCII is escaped here, so the cause stays
/// readable from the reader to the night report.
///
/// An all-NUL field is named rather than shown as eight escapes, because that
/// field is not a mangled keyword — it is the signature of a file whose header
/// was never written.
fn invalid_keyword_message(field: &[u8], record_number: usize) -> String {
    if field.iter().all(|&byte| byte == 0) {
        return format!(
            "record {record_number} holds NUL bytes where a FITS keyword belongs, \
             so this is not a FITS header"
        );
    }
    let mut shown = String::with_capacity(field.len());
    for &byte in field {
        if (0x20..0x7f).contains(&byte) {
            shown.push(byte as char);
        } else {
            shown.push_str(&format!("\\x{byte:02x}"));
        }
    }
    format!("Invalid FITS keyword in record {record_number}: \"{shown}\"")
}

fn is_valid_keyword(keyword: &str) -> bool {
    !keyword.is_empty()
        && keyword.len() <= 8
        && keyword.bytes().all(|byte| {
            byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'-' || byte == b'_'
        })
}

/// Write and flush a sibling scratch file before atomically publishing the FITS.
/// A failed write leaves an existing destination intact and removes the scratch.
///
/// Why: this writer enforces three FITS-spec invariants that the prior version
/// violated:
///  * BSCALE/BZERO are computed fresh from the in-memory pixel type, never
///    inherited from a stale source header.
///  * String values are padded to ≥8 characters between single quotes (FITS 4.2.1.1).
///  * COMMENT/HISTORY cards are emitted without an `=` separator and free-form
///    text in columns 9..80; they are NOT routed through the value-card writer.
pub fn write_fits(path: &Path, image: &ImageData, header: &FitsHeader) -> Result<(), FitsError> {
    let permissions = match std::fs::metadata(path) {
        Ok(metadata) => {
            let permissions = metadata.permissions();
            if permissions.readonly() {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::PermissionDenied,
                    "FITS destination is read-only",
                )
                .into());
            }
            Some(permissions)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => return Err(error.into()),
    };
    let (mut scratch, file) = FitsScratch::create(path)?;
    if let Some(permissions) = permissions {
        file.set_permissions(permissions)?;
    }
    let mut writer = BufWriter::new(file);
    write_fits_to(&mut writer, image, header)?;
    writer.get_ref().sync_all()?;
    drop(writer);
    std::fs::rename(&scratch.path, path)?;
    scratch.published = true;
    Ok(())
}

struct FitsScratch {
    path: PathBuf,
    published: bool,
}

impl FitsScratch {
    fn create(destination: &Path) -> std::io::Result<(Self, File)> {
        static NEXT_ID: AtomicU64 = AtomicU64::new(0);
        let name = destination.file_name().ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "Missing FITS filename")
        })?;
        for _ in 0..100 {
            let mut scratch_name = std::ffi::OsString::from(".");
            scratch_name.push(name);
            scratch_name.push(format!(
                ".skotiq-{}-{}.tmp",
                std::process::id(),
                NEXT_ID.fetch_add(1, Ordering::Relaxed)
            ));
            let path = destination.with_file_name(scratch_name);
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => {
                    return Ok((
                        Self {
                            path,
                            published: false,
                        },
                        file,
                    ));
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error),
            }
        }
        Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "Could not reserve a FITS scratch file",
        ))
    }
}

impl Drop for FitsScratch {
    fn drop(&mut self) {
        if !self.published {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

fn write_fits_to(
    mut writer: &mut (impl Write + Seek),
    image: &ImageData,
    header: &FitsHeader,
) -> Result<(), FitsError> {
    let needed = image.pixel_count().saturating_mul(image.bytes_per_pixel());
    if image.data.len() < needed {
        return Err(FitsError::InvalidFormat(format!(
            "image is {} bytes and a {}x{}x{} {} frame needs {needed}",
            image.data.len(),
            image.width,
            image.height,
            image.channels,
            image.pixel_type.byte_size() * 8,
        )));
    }
    let bitpix: i32 = match image.pixel_type {
        PixelType::U8 => 8,
        PixelType::U16 => 16,
        PixelType::U32 => 32,
        PixelType::F32 => -32,
        PixelType::F64 => -64,
    };

    // Write mandatory keywords
    write_value_card(&mut writer, "SIMPLE", "T", None)?;
    write_value_card(&mut writer, "BITPIX", &bitpix.to_string(), None)?;
    write_value_card(
        &mut writer,
        "NAXIS",
        &format!("{}", if image.channels > 1 { 3 } else { 2 }),
        None,
    )?;
    write_value_card(&mut writer, "NAXIS1", &image.width.to_string(), None)?;
    write_value_card(&mut writer, "NAXIS2", &image.height.to_string(), None)?;
    if image.channels > 1 {
        write_value_card(&mut writer, "NAXIS3", &image.channels.to_string(), None)?;
    }

    // Why: the writer must always emit fresh BSCALE/BZERO matching
    // the chosen output BITPIX. The decoder strips them from `keyword_order`, so
    // these are the only BSCALE/BZERO cards in the file.
    if image.pixel_type == PixelType::U16 {
        write_value_card(&mut writer, "BZERO", "32768", None)?;
        write_value_card(&mut writer, "BSCALE", "1", None)?;
    } else if image.pixel_type == PixelType::U32 {
        // Unsigned 32-bit is stored as signed BITPIX=32 with the standard
        // BZERO offset (FITS §5.2.5). Without it, u32 values above 2^31-1 wrap
        // to negative i32 on disk and are clamped to zero when read back.
        write_value_card(&mut writer, "BZERO", "2147483648", None)?;
        write_value_card(&mut writer, "BSCALE", "1", None)?;
    } else if matches!(image.pixel_type, PixelType::F32 | PixelType::F64) {
        // A float file's numbers say nothing about their scale; state it.
        write_value_card(
            &mut writer,
            crate::fits_reader::RANGE_LOW_CARD,
            &format_fits_float(image.range.low),
            Some("sample value of black"),
        )?;
        write_value_card(
            &mut writer,
            crate::fits_reader::RANGE_HIGH_CARD,
            &format_fits_float(image.range.high),
            Some("sample value of full scale"),
        )?;
    }
    if image.channels > 1 {
        write_value_card(
            &mut writer,
            crate::fits_layout::LAYOUT_KEYWORD,
            &format_fits_string_value(crate::fits_layout::PlaneLayout::Planar.as_card()),
            Some("samples stored plane by plane"),
        )?;
    }

    // The cards this writer owns are written from the image above, never
    // copied from the header.
    let owned_by_writer = |key: &str| {
        [
            "SIMPLE",
            "BITPIX",
            "NAXIS",
            "NAXIS1",
            "NAXIS2",
            "NAXIS3",
            "BZERO",
            "BSCALE",
            "END",
            LONG_STRING_KEYWORD,
            crate::fits_layout::LAYOUT_KEYWORD,
            crate::fits_reader::RANGE_LOW_CARD,
            crate::fits_reader::RANGE_HIGH_CARD,
        ]
        .contains(&key)
    };
    let header_cards = || {
        header
            .keyword_order
            .iter()
            .filter(|key| !owned_by_writer(key))
            .filter_map(|key| header.keywords.get(key).map(|value| (key.as_str(), value)))
    };

    if header_cards().any(|(key, value)| {
        is_valid_keyword(key)
            && matches!(value, FitsValue::String(s) if string_value_pieces(s).len() > 1)
    }) {
        write_value_card(
            &mut writer,
            LONG_STRING_KEYWORD,
            &format_fits_string_value("OGIP 1.0"),
            Some("Long strings continue on CONTINUE cards"),
        )?;
    }

    for (key, value) in header_cards() {
        let comment = header.keyword_comments.get(key).map(|s| s.as_str());
        if !is_valid_keyword(key) {
            write_foreign_name_card(&mut writer, key, value, comment)?;
            continue;
        }
        match value {
            FitsValue::String(s) => {
                write_string_cards(&mut writer, key, s, comment)?;
            }
            FitsValue::Integer(i) => {
                write_value_card(&mut writer, key, &i.to_string(), comment)?;
            }
            FitsValue::Float(f) => {
                write_value_card(&mut writer, key, &format_fits_float(*f), comment)?;
            }
            FitsValue::Boolean(b) => {
                let token = if *b { "T" } else { "F" };
                write_value_card(&mut writer, key, token, comment)?;
            }
            // Why: legacy callers may still construct FitsValue::Comment directly.
            // Treat it as a free-form COMMENT card to avoid producing a malformed
            // value card. New code should call `add_comment()` on FitsHeader instead.
            FitsValue::Comment(c) => {
                write_text_card(&mut writer, "COMMENT", c)?;
            }
        }
    }

    // Emit COMMENT cards. Why: these have no `=` separator and the text body
    // occupies columns 9..80, padded with spaces.
    for text in &header.comments {
        write_text_card(&mut writer, "COMMENT", text)?;
    }
    for text in &header.history {
        write_text_card(&mut writer, "HISTORY", text)?;
    }

    write_end_card(&mut writer)?;

    // Pad header to 2880-byte boundary
    let pos = writer.stream_position()? as usize;
    let padding = (2880 - (pos % 2880)) % 2880;
    writer.write_all(&[b' '; FITS_RECORD_LEN][..padding])?;

    // Write image data, one plane after another: FITS orders a NAXIS3 cube
    // by plane, while `ImageData` interleaves its channels.
    let channels = image.channels.max(1) as usize;
    for channel in 0..channels {
        match image.pixel_type {
            PixelType::U8 => {
                write_be_samples::<_, 1>(&mut writer, &image.data, channels, channel, |raw| raw)?;
            }
            PixelType::U16 => {
                // Convert from little-endian u16 to big-endian i16 with BZERO offset
                write_be_samples::<_, 2>(&mut writer, &image.data, channels, channel, |raw| {
                    let signed = (u16::from_le_bytes(raw) as i32 - 32768) as i16;
                    signed.to_be_bytes()
                })?;
            }
            PixelType::U32 => {
                // Apply the BZERO=2147483648 offset written above: physical value
                // v maps to stored signed s = v - 2^31, recovered on read as
                // s + 2^31. This keeps the full unsigned range representable.
                write_be_samples::<_, 4>(&mut writer, &image.data, channels, channel, |raw| {
                    let signed = (u32::from_le_bytes(raw) as i64 - 2_147_483_648) as i32;
                    signed.to_be_bytes()
                })?;
            }
            PixelType::F32 => {
                write_be_samples::<_, 4>(&mut writer, &image.data, channels, channel, |raw| {
                    f32::from_le_bytes(raw).to_be_bytes()
                })?;
            }
            PixelType::F64 => {
                write_be_samples::<_, 8>(&mut writer, &image.data, channels, channel, |raw| {
                    f64::from_le_bytes(raw).to_be_bytes()
                })?;
            }
        }
    }

    // Pad data to 2880-byte boundary
    let data_size = image.data.len();
    let padding = (2880 - (data_size % 2880)) % 2880;
    writer.write_all(&[0u8; FITS_RECORD_LEN][..padding])?;

    writer.flush()?;
    Ok(())
}

/// Bytes converted per `write_all` in `write_be_samples`.
///
/// Why blocks: a per-sample `write_all` costs one `BufWriter` capacity check
/// each and, at the writer's 8 KiB buffer, a `write` syscall every 4096 pixels.
/// A 61 MP mono frame is 61 million of those on every capture. 64 KiB keeps the
/// scratch buffer off the large-allocation path while cutting the call count by
/// three orders of magnitude.
const WRITE_BLOCK_BYTES: usize = 64 * 1024;

/// Transcode one channel of a little-endian, channel-interleaved pixel buffer
/// to big-endian FITS order one block at a time. Trailing bytes that do not
/// form a whole pixel are dropped, matching `chunks_exact`.
fn write_be_samples<W: Write, const N: usize>(
    writer: &mut W,
    data: &[u8],
    channels: usize,
    channel: usize,
    convert: impl Fn([u8; N]) -> [u8; N],
) -> Result<(), FitsError> {
    let block_bytes = (WRITE_BLOCK_BYTES / N) * N;
    let mut block = Vec::with_capacity(block_bytes);
    let samples = data.as_chunks::<N>().0;
    let pixels = samples.len() / channels;
    for sample in samples.iter().skip(channel).step_by(channels).take(pixels) {
        block.extend_from_slice(&convert(*sample));
        if block.len() >= block_bytes {
            writer.write_all(&block)?;
            block.clear();
        }
    }
    writer.write_all(&block)?;
    Ok(())
}

/// Format a FITS string value with the FITS 4.2.1.1 minimum-length rule.
///
/// Why: PixInsight, AstroPixelProcessor, and several legacy tools reject string
/// cards whose quoted body is shorter than 8 characters. The spec requires the
/// quoted text to be space-padded out to at least 8 characters before the closing
/// quote.
/// `text` as the printable ASCII (32-126) every FITS header byte must be:
/// a character with a clear ASCII spelling is written in it ("°" as "deg",
/// "µ" as "u", typographic quotes and dashes as their plain forms, accented
/// Latin letters without the accent), and any other one as `?`.
fn fits_ascii(text: &str) -> std::borrow::Cow<'_, str> {
    if text.bytes().all(|b| (0x20..0x7f).contains(&b)) {
        return std::borrow::Cow::Borrowed(text);
    }
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        let spelled: &str = match ch {
            ' '..='~' => {
                out.push(ch);
                continue;
            }
            '\t' => " ",
            '°' | 'º' => "deg",
            '′' => "'",
            '″' => "\"",
            '‘' | '’' | '‚' => "'",
            '“' | '”' | '„' => "\"",
            '–' | '—' | '−' | '‐' => "-",
            '…' => "...",
            '·' | '•' => "-",
            '×' => "x",
            '±' => "+/-",
            'µ' | 'μ' => "u",
            'Å' => "A",
            'å' => "a",
            'Æ' => "AE",
            'æ' => "ae",
            'Ø' => "O",
            'ø' => "o",
            'ß' => "ss",
            '\u{a0}' => " ",
            _ => match unaccented(ch) {
                Some(letter) => {
                    out.push(letter);
                    continue;
                }
                None => "?",
            },
        };
        out.push_str(spelled);
    }
    std::borrow::Cow::Owned(out)
}

/// The plain letter an accented Latin-1 letter is written on.
fn unaccented(ch: char) -> Option<char> {
    const LETTERS: [(&str, char); 16] = [
        ("ÀÁÂÃÄ", 'A'),
        ("àáâãä", 'a'),
        ("Ç", 'C'),
        ("ç", 'c'),
        ("ÈÉÊË", 'E'),
        ("èéêë", 'e'),
        ("ÌÍÎÏ", 'I'),
        ("ìíîï", 'i'),
        ("Ñ", 'N'),
        ("ñ", 'n'),
        ("ÒÓÔÕÖ", 'O'),
        ("òóôõö", 'o'),
        ("ÙÚÛÜ", 'U'),
        ("ùúûü", 'u'),
        ("Ý", 'Y'),
        ("ýÿ", 'y'),
    ];
    LETTERS
        .iter()
        .find(|(accented, _)| accented.contains(ch))
        .map(|(_, plain)| *plain)
}

fn format_fits_string_value(value: &str) -> String {
    // Why: a single-quote inside the string must be escaped as `''` per FITS 4.2.1.1.
    let escaped = value.replace('\'', "''");
    let body = if escaped.chars().count() < 8 {
        // Pad with trailing spaces to the 8-char minimum.
        let needed = 8 - escaped.chars().count();
        format!("{}{}", escaped, " ".repeat(needed))
    } else {
        escaped
    };
    format!("'{}'", body)
}

/// Bytes a value card holds from column 11 to column 80: the value and its
/// inline comment.
const VALUE_FIELD_LEN: usize = 70;

/// Keyword of a card that carries on the string begun on the card before it
/// (the long-string convention, FITS 4.0 section 4.2.1.2).
const CONTINUE_KEYWORD: &str = "CONTINUE";

/// Keyword announcing that a header uses the long-string convention. FITS 4.0
/// does not require it; the OGIP convention the standard took it from asks for
/// it, and older readers look for it before they join CONTINUE cards.
const LONG_STRING_KEYWORD: &str = "LONGSTRN";

/// Last character of a string piece that the next CONTINUE card carries on.
const LONG_STRING_CONTINUATION: char = '&';

/// The quoted pieces a string value is written as, one per card.
///
/// A value that fits one card is one piece. A longer one is split into pieces
/// of at most 67 escaped bytes, each but the last ending in `&` inside its
/// quotes, the way cfitsio and astropy write and read it. A split
/// never falls inside a doubled quote or a multi-byte character. A value that
/// itself ends in `&` gets an empty last piece, because astropy drops a
/// trailing `&` from every piece of a long string, the last one included.
fn string_value_pieces(value: &str) -> Vec<String> {
    let single = format_fits_string_value(value);
    if single.len() <= VALUE_FIELD_LEN {
        return vec![single];
    }
    // Two quotes and the continuation marker around each piece.
    let piece_len = VALUE_FIELD_LEN - 3;
    let mut bodies = vec![String::new()];
    for ch in value.chars() {
        let mut unit = [0u8; 4];
        let unit = if ch == '\'' {
            "''"
        } else {
            ch.encode_utf8(&mut unit)
        };
        let body = bodies.last_mut().expect("bodies starts non-empty");
        if body.len() + unit.len() > piece_len {
            bodies.push(unit.to_string());
        } else {
            body.push_str(unit);
        }
    }
    if value.ends_with(LONG_STRING_CONTINUATION) {
        bodies.push(String::new());
    }
    let last = bodies.len() - 1;
    bodies
        .into_iter()
        .enumerate()
        .map(|(index, body)| {
            if index == last {
                format!("'{body}'")
            } else {
                format!("'{body}{LONG_STRING_CONTINUATION}'")
            }
        })
        .collect()
}

/// Write a string value card, carried on over CONTINUE cards when it is too
/// long for one. The inline comment goes on the last card.
fn write_string_cards<W: Write>(
    writer: &mut W,
    keyword: &str,
    value: &str,
    comment: Option<&str>,
) -> Result<(), FitsError> {
    let pieces = string_value_pieces(&fits_ascii(value));
    let last = pieces.len() - 1;
    for (index, piece) in pieces.iter().enumerate() {
        let comment = if index == last { comment } else { None };
        if index == 0 {
            write_value_card(writer, keyword, piece, comment)?;
        } else {
            let mut record = value_card_record(CONTINUE_KEYWORD, piece, comment)?;
            // A CONTINUE card has no value indicator in columns 9 and 10.
            record[8..10].copy_from_slice(b"  ");
            writer.write_all(&record)?;
        }
    }
    Ok(())
}

/// Format a float for a FITS value card. Why: FITS uses standard scientific
/// notation; we keep enough precision (10 significant digits) for double-precision
/// astrometry values without exceeding the 70-byte value field.
fn format_fits_float(value: f64) -> String {
    // Why: integer-valued floats round-trip through `f64::to_string` as e.g. "1",
    // which silently changes the type from Float to Integer on re-parse. Force a
    // decimal point for true integer values to preserve Float typing.
    if value.is_finite() && value.fract() == 0.0 && value.abs() < 1.0e16 {
        format!("{:.1}", value)
    } else {
        format!("{:.10E}", value)
    }
}

/// Write the END card. END has no `=` and no value body.
fn write_end_card<W: Write>(writer: &mut W) -> Result<(), FitsError> {
    let mut record = [b' '; 80];
    record[..3].copy_from_slice(b"END");
    writer.write_all(&record)?;
    Ok(())
}

/// Write a free-form text card (COMMENT, HISTORY, or any spec-defined commentary
/// keyword). Per FITS 4.4.2.4 these have no `=` separator; the text body fills
/// columns 9..80 (1-indexed) and is padded with trailing spaces. Long text is
/// split across multiple cards by [`commentary_cards`]. Why: emitting a
/// value-card for COMMENT/HISTORY would produce malformed cards like
/// `COMMENT = some text`.
fn write_text_card<W: Write>(writer: &mut W, keyword: &str, text: &str) -> Result<(), FitsError> {
    if keyword.len() > 8 {
        return Err(FitsError::InvalidFormat(format!(
            "Commentary keyword '{}' exceeds 8 chars",
            keyword
        )));
    }
    for body in commentary_cards(&fits_ascii(text)) {
        let mut record = [b' '; 80];
        let key_bytes = keyword.as_bytes();
        record[..key_bytes.len()].copy_from_slice(key_bytes);
        // Why: column 9 is the first text byte (0-indexed offset 8) and the spec
        // does not place an `=` at column 9 for commentary keywords.
        let bytes = body.as_bytes();
        record[8..8 + bytes.len()].copy_from_slice(bytes);
        writer.write_all(&record)?;
    }
    Ok(())
}

/// Text bytes one commentary card holds: columns 9..80 of the 80-column record.
const COMMENTARY_BODY_LEN: usize = 72;

/// Last character of a commentary card whose logical line continues on the next
/// card, and the character a literal one doubles itself into.
///
/// The same `&` FITS 4.2.1.2 gives the long-string convention, for the same
/// reason and read the same way: a reader that knows nothing of this sees a
/// trailing ampersand and knows the text is not finished, rather than a value
/// sliced at column 80 with nothing to say so.
const COMMENTARY_CONTINUATION: char = '&';

/// How many [`COMMENTARY_CONTINUATION`] characters `text` ends with.
fn trailing_marker_run(text: &str) -> usize {
    text.chars()
        .rev()
        .take_while(|c| *c == COMMENTARY_CONTINUATION)
        .count()
}

/// `text` with its trailing marker run doubled, so a card body ending in a
/// literal ampersand cannot be read as a continuation.
fn escape_trailing_markers(text: &str) -> String {
    let run = trailing_marker_run(text);
    let mut body = String::with_capacity(text.len() + run);
    body.push_str(text);
    for _ in 0..run {
        body.push(COMMENTARY_CONTINUATION);
    }
    body
}

/// Where to break `text` so the head, escaped and marked, fits one card.
///
/// The break falls after the last space that leaves a worthwhile head, so a
/// path, a digest or a keyword=value pair lands whole on one card rather than
/// halved at whatever column 80 happens to fall on. A token longer than a card
/// has no such space and is broken at the last character that fits — the
/// continuation marker is what makes that break readable rather than silent.
fn commentary_wrap_point(text: &str) -> usize {
    let mut limit = 0;
    for (index, ch) in text.char_indices() {
        let end = index + ch.len_utf8();
        if escape_trailing_markers(&text[..end]).len() + 1 > COMMENTARY_BODY_LEN {
            break;
        }
        limit = end;
    }
    if limit == 0 {
        // One character whose escaped form plus a marker overruns a card cannot
        // happen (three bytes at most), but a zero break point would loop
        // forever, so advance by one character rather than trust the arithmetic.
        return text
            .char_indices()
            .nth(1)
            .map_or(text.len(), |(index, _)| index);
    }
    match text[..limit].rfind(' ') {
        // The space stays on the head, so plain concatenation puts it back.
        Some(space) if space + 1 >= COMMENTARY_BODY_LEN / 4 => space + 1,
        _ => limit,
    }
}

/// The card bodies one logical commentary line becomes.
///
/// Every card but the last ends with [`COMMENTARY_CONTINUATION`]; the reader
/// side is [`join_commentary_cards`], and the two round-trip exactly — a line
/// written and read back is the line that was written, spaces and ampersands
/// included.
fn commentary_cards(text: &str) -> Vec<String> {
    let mut cards = Vec::new();
    let mut rest = text;
    loop {
        let escaped = escape_trailing_markers(rest);
        if escaped.len() <= COMMENTARY_BODY_LEN {
            cards.push(escaped);
            return cards;
        }
        let split = commentary_wrap_point(rest);
        let mut body = escape_trailing_markers(&rest[..split]);
        body.push(COMMENTARY_CONTINUATION);
        cards.push(body);
        rest = &rest[split..];
    }
}

/// Fold a block of commentary card bodies back into logical lines.
///
/// The inverse of [`commentary_cards`]. A card body ending in an ODD number of
/// ampersands is continued by the next card — the last one is the marker, the
/// pairs before it are literals; an EVEN number ends the line and every pair is
/// one literal ampersand. A file written before this convention carries no
/// markers at all, so each of its cards reads as its own line exactly as it did.
fn join_commentary_cards(cards: Vec<String>) -> Vec<String> {
    let mut lines: Vec<String> = Vec::with_capacity(cards.len());
    let mut pending: Option<String> = None;
    for card in cards {
        let run = trailing_marker_run(&card);
        let continued = run % 2 == 1;
        let literals = if continued { (run - 1) / 2 } else { run / 2 };
        let mut body = card[..card.len() - run].to_string();
        for _ in 0..literals {
            body.push(COMMENTARY_CONTINUATION);
        }
        match pending.take() {
            Some(mut head) => {
                head.push_str(&body);
                pending = Some(head);
            }
            None => pending = Some(body),
        }
        if !continued {
            if let Some(line) = pending.take() {
                lines.push(line);
            }
        }
    }
    // A block whose last card still asks to be continued has nothing to be
    // continued by — a truncated header, or one edited by another tool. What was
    // read is stated as it stands rather than dropped.
    if let Some(tail) = pending {
        lines.push(tail);
    }
    lines
}

/// Write a value-card record `KEYNAME = value [/ comment]`.
///
/// `comment` is an optional inline comment. The card is truncated at 80 bytes;
/// if the comment would push the card past 80 bytes it is shortened (or omitted)
/// rather than wrapped, since FITS 4.4.2.3 forbids continuation of value-card
/// inline comments.
fn write_value_card<W: Write>(
    writer: &mut W,
    keyword: &str,
    value: &str,
    comment: Option<&str>,
) -> Result<(), FitsError> {
    writer.write_all(&value_card_record(keyword, value, comment)?)?;
    Ok(())
}

/// The 80 bytes of a value card; see [`write_value_card`].
fn value_card_record(
    keyword: &str,
    value: &str,
    comment: Option<&str>,
) -> Result<[u8; 80], FitsError> {
    if !is_valid_keyword(keyword) {
        return Err(FitsError::InvalidFormat(format!(
            "Invalid FITS keyword for write: {}",
            keyword
        )));
    }

    let mut record = [b' '; 80];

    // Write keyword (8 chars, left-justified)
    let keyword_bytes = keyword.as_bytes();
    let keyword_len = keyword_bytes.len().min(8);
    record[..keyword_len].copy_from_slice(&keyword_bytes[..keyword_len]);

    if value.is_empty() {
        return Ok(record);
    }

    // "= " indicator at columns 9..10 (0-indexed 8..10).
    record[8] = b'=';
    record[9] = b' ';

    let value_bytes = value.as_bytes();
    // Strings start at column 11 (offset 10); numerics are right-justified ending at
    // column 30 (offset 30).
    let is_string = value.starts_with('\'');
    let start = if is_string {
        if value_bytes.len() > 70 {
            return Err(FitsError::InvalidFormat(format!(
                "FITS string value too long for {}",
                keyword
            )));
        }
        10
    } else {
        if value_bytes.len() > 70 {
            return Err(FitsError::InvalidFormat(format!(
                "FITS value too long for {}",
                keyword
            )));
        }
        30_usize.saturating_sub(value_bytes.len())
    };
    let value_len = value_bytes.len().min(70);
    if start + value_len > record.len() {
        return Err(FitsError::InvalidFormat(format!(
            "FITS value overflows 80-byte card for {}",
            keyword
        )));
    }
    record[start..start + value_len].copy_from_slice(&value_bytes[..value_len]);

    put_inline_comment(&mut record, start + value_len, comment);
    Ok(record)
}

/// Write `comment` after the value ending at `value_end`, as ` / comment`.
///
/// FITS 4.4.2.3 — the format is `value / comment` with at least one space on
/// each side of the `/`. Truncated (never wrapped) to fit 80 bytes.
fn put_inline_comment(record: &mut [u8; 80], value_end: usize, comment: Option<&str>) {
    if let Some(comment_text) = comment {
        let trimmed = comment_text.trim();
        if !trimmed.is_empty() {
            // Need " / " (3 bytes) plus at least one comment byte.
            if value_end + 4 <= 80 {
                let separator = b" / ";
                let sep_start = value_end + 1; // leave a space after the value
                if sep_start + 2 < 80 {
                    record[sep_start..sep_start + 2].copy_from_slice(&separator[1..3]);
                    let comment_start = sep_start + 2;
                    let available = 80 - comment_start;
                    let trimmed = fits_ascii(trimmed);
                    let comment_bytes = trimmed.as_bytes();
                    let copy_len = comment_bytes.len().min(available);
                    record[comment_start..comment_start + copy_len]
                        .copy_from_slice(&comment_bytes[..copy_len]);
                }
            }
        }
    }
}

/// Keyword of a card whose name is not a FITS keyword (the ESO HIERARCH
/// convention, read by astropy and cfitsio): `HIERARCH <name> = <value>`.
const HIERARCH_KEYWORD: &str = "HIERARCH";

/// Write a card whose name is no FITS keyword: longer than eight characters,
/// or with spaces or other characters a keyword cannot hold, as a foreign XISF
/// file or a HIERARCH header carries.
///
/// It is written `HIERARCH <name> = <value> / <comment>` when the name is
/// printable ASCII without `=` and name and value fit one card. Otherwise it
/// becomes a COMMENT line `<name> = <value> / <comment>`, which any length
/// fits, so one foreign card never costs the file.
fn write_foreign_name_card<W: Write>(
    writer: &mut W,
    name: &str,
    value: &FitsValue,
    comment: Option<&str>,
) -> Result<(), FitsError> {
    let value_text = match value {
        FitsValue::Comment(text) => return write_text_card(writer, "COMMENT", text),
        other => fits_ascii(&value_card_text(other)).into_owned(),
    };
    let name = name.trim();
    let card = format!("{HIERARCH_KEYWORD} {name} = {value_text}");
    let hierarch_name = !name.is_empty()
        && name
            .bytes()
            .all(|byte| (0x20..0x7f).contains(&byte) && byte != b'=');
    if hierarch_name && card.len() <= CARD_LEN {
        let mut record = [b' '; 80];
        record[..card.len()].copy_from_slice(card.as_bytes());
        put_inline_comment(&mut record, card.len(), comment);
        writer.write_all(&record)?;
        return Ok(());
    }
    let line = match comment.map(str::trim).filter(|c| !c.is_empty()) {
        Some(comment) => format!("{name} = {value_text} / {comment}"),
        None => format!("{name} = {value_text}"),
    };
    write_text_card(writer, "COMMENT", &line)
}

/// The color filter of a frame at its pixel (0, 0): `BAYERPAT` (4 letters for
/// Bayer, 36 for X-Trans) moved by `XBAYROFF`/`YBAYROFF`. `None` for a mono
/// frame or a `BAYERPAT` that names no filter the app knows.
pub fn read_color_filter_array(header: &FitsHeader) -> Option<ColorFilterArray> {
    let cfa = ColorFilterArray::parse(header.get_string("BAYERPAT")?)?;
    let x_offset = header.get_int("XBAYROFF").unwrap_or(0);
    let y_offset = header.get_int("YBAYROFF").unwrap_or(0);
    Some(cfa.shifted(x_offset, y_offset))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::validate_fits_header;
    use std::io::Cursor;

    /// Build an 80-byte FITS record from a byte slice, right-padded with spaces.
    fn fits_record(bytes: &[u8]) -> Vec<u8> {
        let mut r = bytes.to_vec();
        r.resize(80, b' ');
        r
    }

    /// A FITS header whose keyword column contains a non-ASCII byte must not
    /// panic the parser. `String::from_utf8_lossy` maps each invalid byte to a
    /// 3-byte U+FFFD, which can straddle the fixed column boundary (byte index
    /// 8/10) that the header parser slices at — byte-indexing a UTF-8 string off
    /// a char boundary panics ("byte index N is not a char boundary"). A
    /// corrupted/partial BLOB or a camera emitting binary in the header area is
    /// exactly this input, so the parser must return an error, never crash.
    #[test]
    fn test_read_fits_non_ascii_header_no_panic() {
        // "SIMPLE" then 0xFF at column 6 -> U+FFFD occupies output bytes 6..9,
        // so byte index 8 (the value-indicator column slice) is mid-char.
        let mut data = fits_record(b"SIMPLE\xff\xff= T");
        data.extend_from_slice(&fits_record(b"END"));
        let result = std::panic::catch_unwind(|| read_fits_from_bytes(&data));
        assert!(
            result.is_ok(),
            "parser panicked on a non-ASCII header column instead of erroring"
        );
    }

    /// Adversarial sweep: truncations and seeded-random byte streams must always
    /// produce a Result (Ok or Err), never a panic/abort. Guards the INDI BLOB ->
    /// FITS path against real-camera header variability and partial downloads.
    #[test]
    fn test_read_fits_fuzz_no_panic() {
        let hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {})); // silence expected-if-broken traces
                                                // Deterministic LCG so failures reproduce without a rand dep.
        let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut next = || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (state >> 33) as u32
        };
        let mut panicked_on: Option<Vec<u8>> = None;
        for _ in 0..2000 {
            let len = (next() % 6000) as usize;
            let mut data = vec![0u8; len];
            for b in data.iter_mut() {
                *b = (next() & 0xff) as u8;
            }
            // Bias some records toward FITS-looking keywords to reach deeper code.
            if len >= 80 && next() % 2 == 0 {
                data[..8].copy_from_slice(b"SIMPLE  ");
            }
            let probe = data.clone();
            if std::panic::catch_unwind(|| read_fits_from_bytes(&probe)).is_err() {
                panicked_on = Some(data);
                break;
            }
        }
        std::panic::set_hook(hook);
        assert!(
            panicked_on.is_none(),
            "read_fits_from_bytes panicked on adversarial input: {:?}",
            panicked_on.map(|d| d.len())
        );
    }

    #[test]
    fn test_fits_header_set_get() {
        let mut header = FitsHeader::new();
        header.set_string("OBJECT", "M31");
        header.set_float("EXPTIME", 120.5);
        header.set_int("GAIN", 100);
        header.set_bool("SIMPLE", true);

        assert_eq!(header.get_string("OBJECT"), Some("M31"));
        assert_eq!(header.get_float("EXPTIME"), Some(120.5));
        assert_eq!(header.get_int("GAIN"), Some(100));
    }

    #[test]
    fn test_fits_header_operations() {
        let width = 10;
        let height = 10;
        let data: Vec<u16> = (0..100).collect();
        let _image = ImageData::from_u16(width, height, 1, &data);

        let mut header = FitsHeader::new();
        header.set_string("OBJECT", "Test");
        header.set_float("EXPTIME", 60.0);
        header.set_string("IMAGETYP", "Light");
        header.set_int("GAIN", 100);
        header.set_float("CCD-TEMP", -10.5);

        assert_eq!(header.get_string("OBJECT"), Some("Test"));
        assert_eq!(header.get_float("EXPTIME"), Some(60.0));
        assert_eq!(header.get_string("IMAGETYP"), Some("Light"));
        assert_eq!(header.get_int("GAIN"), Some(100));
        assert_eq!(header.get_float("CCD-TEMP"), Some(-10.5));
    }

    #[test]
    fn test_fits_complete_metadata() {
        let mut header = FitsHeader::new();
        header.set_bool("SIMPLE", true);
        header.set_int("BITPIX", 16);
        header.set_int("NAXIS", 2);
        header.set_int("NAXIS1", 3008);
        header.set_int("NAXIS2", 3008);

        // Core metadata
        header.set_string("DATE-OBS", "2025-01-15T22:30:45.123");
        header.set_string("IMAGETYP", "Light");
        header.set_float("EXPTIME", 300.0);
        header.set_string("OBJECT", "M31");
        header.set_string("FILTER", "Luminance");

        // Equipment
        header.set_string("TELESCOP", "Test Telescope");
        header.set_string("INSTRUME", "Test Camera");
        header.set_string("OBSERVER", "Test Observer");

        // Camera settings
        header.set_int("GAIN", 139);
        header.set_int("OFFSET", 21);
        header.set_float("CCD-TEMP", -10.0);
        header.set_int("XBINNING", 1);
        header.set_int("YBINNING", 1);

        // Optics
        header.set_float("FOCALLEN", 600.0);
        header.set_float("APTDIA", 100.0);
        header.set_float("PIXSIZE1", 3.76);
        header.set_float("PIXSIZE2", 3.76);
        header.set_float("XPIXSZ", 3.76);
        header.set_float("YPIXSZ", 3.76);

        // Observer location
        header.set_float("SITELAT", 39.0);
        header.set_float("SITELONG", -77.0);
        header.set_float("SITEELEV", 100.0);

        // Target coordinates
        header.set_float("RA", 10.685);
        header.set_float("DEC", 41.27);
        header.set_float("AIRMASS", 1.15);

        let validation = validate_fits_header(&header);
        assert!(validation.is_valid, "Complete header should be valid");
        assert!(
            validation.warnings.is_empty(),
            "Complete header should have no warnings"
        );

        assert_eq!(
            header.get_string("DATE-OBS"),
            Some("2025-01-15T22:30:45.123")
        );
        assert_eq!(header.get_string("IMAGETYP"), Some("Light"));
        assert_eq!(header.get_float("EXPTIME"), Some(300.0));
        assert_eq!(header.get_float("FOCALLEN"), Some(600.0));
        assert_eq!(header.get_float("SITELAT"), Some(39.0));
        assert_eq!(header.get_float("AIRMASS"), Some(1.15));
    }

    #[test]
    fn test_fits_round_trip() {
        let width = 100;
        let height = 100;
        let data: Vec<u16> = (0..10000).map(|i| (i % 65535) as u16).collect();
        let _image = ImageData::from_u16(width, height, 1, &data);

        let mut header = FitsHeader::new();
        header.set_bool("SIMPLE", true);
        header.set_int("BITPIX", 16);
        header.set_int("NAXIS", 2);
        header.set_int("NAXIS1", width as i64);
        header.set_int("NAXIS2", height as i64);
        header.set_string("OBJECT", "M31");
        header.set_float("EXPTIME", 180.0);
        header.set_string("DATE-OBS", "2025-01-15T22:30:45");
        header.set_string("IMAGETYP", "Light");
        header.set_float("AIRMASS", 1.2);

        let validation = validate_fits_header(&header);
        assert!(validation.is_valid, "Header should be valid");

        assert!(header.get("OBJECT").is_some());
        assert!(header.get("EXPTIME").is_some());
        assert!(header.get("DATE-OBS").is_some());
        assert!(header.get("IMAGETYP").is_some());
        assert!(header.get("AIRMASS").is_some());
    }

    #[test]
    fn test_parse_fits_value_requires_exact_boolean_tokens() {
        assert!(matches!(
            parse_fits_value("F / false").unwrap(),
            FitsValue::Boolean(false)
        ));
        assert!(matches!(
            parse_fits_value("FLAT / image type").unwrap(),
            FitsValue::String(value) if value == "FLAT"
        ));
    }

    #[test]
    fn test_parse_fits_value_preserves_slash_inside_string() {
        assert!(matches!(
            parse_fits_value("'L-eXtreme / Duo' / filter").unwrap(),
            FitsValue::String(value) if value == "L-eXtreme / Duo"
        ));
    }

    #[test]
    fn test_read_header_rejects_invalid_keyword() {
        let mut bytes = vec![b' '; 2880];
        bytes[..80].copy_from_slice(
            b"BAD*KEY =                    1                                                  ",
        );
        bytes[80..160].copy_from_slice(
            b"END                                                                             ",
        );

        let err = read_header(&mut Cursor::new(bytes)).unwrap_err();
        assert!(matches!(err, FitsError::InvalidFormat(_)));
        let sentence = err.to_string();
        assert!(
            sentence.contains("BAD*KEY"),
            "the message names the keyword it rejected: {sentence}"
        );
    }

    /// A master whose header is NUL bytes — what a torn write or a lost extent
    /// leaves behind — has to fail with a sentence an operator can read.
    ///
    /// The message crosses the FFI as a C string on its way to the night report,
    /// so a single NUL in it costs the whole reason: the report then says a
    /// master produced no draft and says nothing about why.
    #[test]
    fn test_read_header_names_a_nul_header_without_carrying_the_nuls() {
        let err = read_header(&mut Cursor::new(vec![0u8; 2880])).unwrap_err();
        let sentence = err.to_string();

        assert!(!sentence.is_empty(), "the failure states a cause");
        assert!(
            !sentence.contains('\0'),
            "no NUL survives into the message: {sentence:?}"
        );
        assert!(
            sentence.contains("NUL") && sentence.contains("not a FITS header"),
            "the message names what it found: {sentence}"
        );
    }

    /// A header of other unprintable bytes is escaped rather than quoted raw, so
    /// the eight bytes are still reported and the sentence still survives.
    #[test]
    fn test_read_header_escapes_unprintable_keyword_bytes() {
        let mut bytes = vec![b' '; 2880];
        bytes[..8].copy_from_slice(&[0x01, 0x02, b'A', 0x00, 0xff, b'B', 0x7f, 0x1b]);

        let err = read_header(&mut Cursor::new(bytes)).unwrap_err();
        let sentence = err.to_string();

        assert!(!sentence.contains('\0'), "no NUL survives: {sentence:?}");
        assert!(
            sentence.contains("\\x01") && sentence.contains("\\x00") && sentence.contains("\\xff"),
            "each unprintable byte is shown escaped: {sentence}"
        );
        assert!(
            sentence.contains('A') && sentence.contains('B'),
            "the printable bytes are shown as themselves: {sentence}"
        );
    }

    #[test]
    fn failed_fits_write_preserves_existing_file_and_removes_scratch() {
        let dir = std::env::temp_dir().join(format!("sk_fits_atomic_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("frame.fits");
        let image = ImageData::from_u16(2, 1, 1, &[100, 200]);
        write_fits(&path, &image, &FitsHeader::new()).unwrap();
        let original = std::fs::read(&path).unwrap();
        let mut short = image.clone();
        short.data.truncate(2);
        assert!(write_fits(&path, &short, &FitsHeader::new()).is_err());
        assert_eq!(
            std::fs::read(&path).unwrap(),
            original,
            "existing FITS changed"
        );
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn failed_fits_write_does_not_publish_a_new_file() {
        let dir = std::env::temp_dir().join(format!("sk_fits_new_atomic_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let mut short = ImageData::from_u16(2, 1, 1, &[100, 200]);
        short.data.truncate(2);
        assert!(write_fits(&dir.join("new.fits"), &short, &FitsHeader::new()).is_err());
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 0);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn successful_fits_replacement_is_complete() {
        let dir = std::env::temp_dir().join(format!("sk_fits_replace_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("frame.fits");
        write_fits(
            &path,
            &ImageData::from_u16(2, 1, 1, &[1, 2]),
            &FitsHeader::new(),
        )
        .unwrap();
        let replacement = ImageData::from_u16(2, 1, 1, &[300, 400]);
        write_fits(&path, &replacement, &FitsHeader::new()).unwrap();
        assert_eq!(read_fits(&path).unwrap().0.data, replacement.data);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn failed_fits_publish_removes_scratch() {
        let dir = std::env::temp_dir().join(format!("sk_fits_publish_{}", std::process::id()));
        let destination = dir.join("directory.fits");
        std::fs::create_dir_all(&destination).unwrap();
        let image = ImageData::from_u16(2, 1, 1, &[100, 200]);
        assert!(write_fits(&destination, &image, &FitsHeader::new()).is_err());
        assert!(destination.is_dir());
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn test_write_keyword_rejects_overflowing_string() {
        let mut out = Vec::new();
        let value = format!("'{}'", "A".repeat(71));
        let err = write_value_card(&mut out, "OBJECT", &value, None).unwrap_err();
        assert!(matches!(err, FitsError::InvalidFormat(_)));
    }

    #[test]
    fn test_read_fits_requires_naxis2_for_2d_images() {
        let mut bytes = vec![b' '; 2880];
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                   10",
            "END",
        ];

        for (idx, card) in cards.iter().enumerate() {
            let offset = idx * 80;
            let mut card_bytes = [b' '; 80];
            let raw = card.as_bytes();
            card_bytes[..raw.len()].copy_from_slice(raw);
            bytes[offset..offset + 80].copy_from_slice(&card_bytes);
        }

        let err = read_fits_from_bytes(&bytes).unwrap_err();
        assert!(matches!(err, FitsError::MissingKeyword(keyword) if keyword == "NAXIS2"));
    }

    #[test]
    fn test_duplicate_keywords_do_not_write_twice() {
        let image = ImageData::from_u16(2, 1, 1, &[1, 2]);
        let mut fits_bytes = Vec::new();
        let raw_header = concat!(
            "SIMPLE  =                    T                                                  ",
            "BITPIX  =                   16                                                  ",
            "NAXIS   =                    2                                                  ",
            "NAXIS1  =                    2                                                  ",
            "NAXIS2  =                    1                                                  ",
            "OBJECT  = 'M31     '                                                            ",
            "OBJECT  = 'M42     '                                                            ",
            "END                                                                             "
        );
        fits_bytes.extend_from_slice(raw_header.as_bytes());
        fits_bytes.resize(2880, b' ');
        fits_bytes.extend_from_slice(&[0, 1, 0, 2]);
        fits_bytes.resize(5760, 0);

        let (_, header) = read_fits_from_bytes(&fits_bytes).expect("header should parse");

        let path = std::env::temp_dir().join(format!(
            "skotiq_duplicate_keyword_{}.fits",
            std::process::id()
        ));
        write_fits(&path, &image, &header).expect("write should succeed");
        let output = std::fs::read(&path).expect("fits bytes should be readable");
        let _ = std::fs::remove_file(&path);

        let header_text = String::from_utf8_lossy(&output[..2880.min(output.len())]);
        assert_eq!(header_text.matches("OBJECT").count(), 1);
        assert_eq!(header.get_string("OBJECT"), Some("M42"));
    }

    #[test]
    fn test_write_keyword_rejects_overflowing_numeric_value() {
        let mut out = Vec::new();
        let value = "1".repeat(71);
        let err = write_value_card(&mut out, "EXPTIME", &value, None).unwrap_err();
        assert!(matches!(err, FitsError::InvalidFormat(_)));
    }

    /// Helper: assemble a minimal FITS byte stream from in-order 80-byte cards.
    fn synth_fits_with_cards(cards: &[&str], data: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::new();
        for card in cards {
            let mut buf = [b' '; 80];
            let raw = card.as_bytes();
            let copy = raw.len().min(80);
            buf[..copy].copy_from_slice(&raw[..copy]);
            bytes.extend_from_slice(&buf);
        }
        let mut buf = [b' '; 80];
        buf[..3].copy_from_slice(b"END");
        bytes.extend_from_slice(&buf);
        // Pad header to 2880-byte boundary
        let pad = (2880 - (bytes.len() % 2880)) % 2880;
        bytes.extend(std::iter::repeat_n(b' ', pad));
        bytes.extend_from_slice(data);
        let pad = (2880 - (bytes.len() % 2880)) % 2880;
        bytes.extend(std::iter::repeat_n(0u8, pad));
        bytes
    }

    #[test]
    fn test_decode_strips_bscale_bzero_from_header() {
        // Build a U16 file with explicit BSCALE=2.0/BZERO=1000.0 stored as i16
        // big-endian. Decode must apply the scaling AND remove BSCALE/BZERO from
        // the returned header so a follow-up write does not double-apply them.
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    2",
            "NAXIS2  =                    1",
            "BZERO   =               1000.0",
            "BSCALE  =                  2.0",
        ];
        // i16 big-endian: pixels {-100, 50}
        let data: Vec<u8> = vec![0xFF, 0x9C, 0x00, 0x32]; // -100, 50 in BE
        let bytes = synth_fits_with_cards(&cards, &data);

        let (image, header) = read_fits_from_bytes(&bytes).expect("read should succeed");
        assert!(
            header.get("BZERO").is_none(),
            "BZERO must be stripped after decode"
        );
        assert!(
            header.get("BSCALE").is_none(),
            "BSCALE must be stripped after decode"
        );
        // Pixels: physical = raw * 2 + 1000 → {-100*2+1000=800, 50*2+1000=1100}
        assert_eq!(image.pixel_type, PixelType::U16);
        let pix: Vec<u16> = image
            .data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        assert_eq!(pix, vec![800, 1100]);
    }

    #[test]
    fn test_round_trip_with_nontrivial_bscale_bzero() {
        // CRITICAL: write the read-back header to a temp file, reload, and
        // assert pixels are identical (no double-scaling).
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    4",
            "NAXIS2  =                    1",
            "BZERO   =               1000.0",
            "BSCALE  =                  2.0",
            "OBJECT  = 'NGC1'",
        ];
        // Four i16 BE pixels: -200, 100, 0, 32000  →  physical: 600, 1200, 1000, 65000
        let data: Vec<u8> = vec![0xFF, 0x38, 0x00, 0x64, 0x00, 0x00, 0x7D, 0x00];
        let bytes = synth_fits_with_cards(&cards, &data);
        let (image_a, header_a) = read_fits_from_bytes(&bytes).expect("first read");
        let pix_a: Vec<u16> = image_a
            .data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        assert_eq!(pix_a, vec![600, 1200, 1000, 65000]);

        let path = std::env::temp_dir().join(format!(
            "skotiq_bscale_roundtrip_{}.fits",
            std::process::id()
        ));
        write_fits(&path, &image_a, &header_a).expect("write");
        let on_disk = std::fs::read(&path).expect("read back");
        let _ = std::fs::remove_file(&path);

        let (image_b, header_b) = read_fits_from_bytes(&on_disk).expect("second read");
        let pix_b: Vec<u16> = image_b
            .data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        assert_eq!(
            pix_a, pix_b,
            "Pixels must round-trip exactly (no double scaling)"
        );
        // After the second read, BSCALE/BZERO have again been folded into pixels
        // and stripped from the header.
        assert!(header_b.get("BSCALE").is_none());
        assert!(header_b.get("BZERO").is_none());
    }

    #[test]
    fn test_bzero_32768_honours_nonunit_bscale() {
        // The BZERO==32768 fast path must not swallow a non-unit BSCALE. With
        // BSCALE=2 the physical value is v*2 + 32768, not v + 32768.
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    2",
            "NAXIS2  =                    1",
            "BZERO   =                32768",
            "BSCALE  =                    2",
            "OBJECT  = 'NGC1'",
        ];
        // Two i16 BE pixels: 100 (0x0064), 1000 (0x03E8).
        let data: Vec<u8> = vec![0x00, 0x64, 0x03, 0xE8];
        let bytes = synth_fits_with_cards(&cards, &data);
        let (image, _header) = read_fits_from_bytes(&bytes).expect("read");
        let pix: Vec<u16> = image
            .data
            .as_chunks::<2>()
            .0
            .iter()
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        // v*BSCALE + BZERO, NOT v + BZERO (which would give 32868, 33768).
        assert_eq!(pix, vec![100 * 2 + 32768, 1000 * 2 + 32768]);
    }

    #[test]
    fn test_u32_bzero_round_trip_above_2_31() {
        // u32 values above 2^31-1 must survive a write/read cycle. Without the
        // BZERO=2147483648 offset they wrap to negative i32 on disk and are
        // clamped to zero on read.
        let values: Vec<u32> = vec![0, 2_000_000_000, 3_000_000_000, u32::MAX];
        let data: Vec<u8> = values.iter().flat_map(|&v| v.to_le_bytes()).collect();
        let image = ImageData {
            width: 4,
            height: 1,
            channels: 1,
            pixel_type: PixelType::U32,
            data,
            range: crate::SampleRange::of(PixelType::U32),
        };
        let path =
            std::env::temp_dir().join(format!("skotiq_u32_roundtrip_{}.fits", std::process::id()));
        write_fits(&path, &image, &FitsHeader::new()).expect("write");
        let on_disk = std::fs::read(&path).expect("read back");
        let _ = std::fs::remove_file(&path);

        let (image_b, _header_b) = read_fits_from_bytes(&on_disk).expect("read");
        assert_eq!(image_b.pixel_type, PixelType::U32);
        let pix: Vec<u32> = image_b
            .data
            .as_chunks::<4>()
            .0
            .iter()
            .map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect();
        assert_eq!(pix, values);
    }

    // Header invariants

    #[test]
    fn test_format_fits_string_value_pads_short_strings() {
        // FITS 4.2.1.1 — string body must be ≥ 8 chars between the quotes.
        let formatted = format_fits_string_value("ABC");
        assert_eq!(formatted, "'ABC     '", "short strings must pad to 8 chars");
        let formatted = format_fits_string_value("LongerThanEight");
        assert_eq!(formatted, "'LongerThanEight'");
    }

    #[test]
    fn test_format_fits_string_value_escapes_quote() {
        let formatted = format_fits_string_value("O'Brien");
        // Internal `'` becomes `''` per FITS 4.2.1.1; total quoted body is 8 chars.
        assert_eq!(formatted, "'O''Brien'");
    }

    #[test]
    fn test_write_emits_short_string_padded() {
        let mut header = FitsHeader::new();
        header.set_string("OBJECT", "M31");
        let image = ImageData::from_u16(2, 1, 1, &[10, 20]);

        let path = std::env::temp_dir().join(format!("skotiq_strpad_{}.fits", std::process::id()));
        write_fits(&path, &image, &header).expect("write");
        let on_disk = std::fs::read(&path).expect("read");
        let _ = std::fs::remove_file(&path);

        let header_text = String::from_utf8_lossy(&on_disk[..2880]);
        // The OBJECT card must contain the padded form "M31     " between quotes.
        assert!(
            header_text.contains("'M31     '"),
            "OBJECT card must pad short string to 8 chars, header was:\n{}",
            header_text
        );
    }

    #[test]
    fn test_write_emits_comment_and_history_without_equals() {
        let mut header = FitsHeader::new();
        header.add_comment("Calibrated with master flat 2026-04-09");
        header.add_history("STAR-DETECT v2.5 ran 2026-05-09T22:14:11");
        let image = ImageData::from_u16(2, 1, 1, &[1, 2]);

        let path = std::env::temp_dir().join(format!(
            "skotiq_comment_history_{}.fits",
            std::process::id()
        ));
        write_fits(&path, &image, &header).expect("write");
        let on_disk = std::fs::read(&path).expect("read");
        let _ = std::fs::remove_file(&path);

        // Locate the COMMENT card and verify columns 9..10 are NOT "= ".
        let header_block = &on_disk[..2880];
        let mut found_comment = false;
        let mut found_history = false;
        for chunk in header_block.as_chunks::<80>().0.iter() {
            if chunk.starts_with(b"COMMENT ") {
                // Per FITS 4.4.2.4 the text body starts at column 9 (offset 8) and
                // there must be no `=` at offset 8.
                assert_ne!(chunk[8], b'=', "COMMENT card must not have `=` separator");
                let body = String::from_utf8_lossy(&chunk[8..]);
                assert!(body.contains("Calibrated with master flat"));
                found_comment = true;
            }
            if chunk.starts_with(b"HISTORY ") {
                assert_ne!(chunk[8], b'=', "HISTORY card must not have `=` separator");
                let body = String::from_utf8_lossy(&chunk[8..]);
                assert!(body.contains("STAR-DETECT v2.5"));
                found_history = true;
            }
        }
        assert!(found_comment, "COMMENT card not emitted");
        assert!(found_history, "HISTORY card not emitted");
    }

    #[test]
    fn test_read_routes_comment_history_to_dedicated_vectors() {
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    1",
            "NAXIS2  =                    1",
            "COMMENT free-form note one",
            "HISTORY processed at 2026-04-01",
            "COMMENT free-form note two",
        ];
        let data: Vec<u8> = vec![0x00, 0x10];
        let bytes = synth_fits_with_cards(&cards, &data);
        let (_image, header) = read_fits_from_bytes(&bytes).expect("read");
        assert_eq!(header.comments.len(), 2);
        assert!(header.comments[0].contains("note one"));
        assert!(header.comments[1].contains("note two"));
        assert_eq!(header.history.len(), 1);
        assert!(header.history[0].contains("processed at 2026-04-01"));
        // The `keywords` map must NOT contain synthetic COMMENT_<n>/HISTORY_<n> keys.
        for key in header.keywords.keys() {
            assert!(
                !key.starts_with("COMMENT") && !key.starts_with("HISTORY"),
                "keywords map must not contain COMMENT/HISTORY synthetic keys, found: {}",
                key
            );
        }
    }

    /// The Darkroom's own summary line, verbatim from an export. A hard split
    /// at column 72 cuts `fingerprint=e2328f` from `40d1…`.
    const LONG_HISTORY_LINE: &str = "Skotiq Darkroom: stage=final, recipe=1 (4 steps), fingerprint=e2328f40d1890f8d378ab91a6195ab17";

    /// The calibration report's reference-light line, whose path carries spaces.
    const LONG_PATH_HISTORY_LINE: &str = "Calibration compared against light /home/scdouglas/.cache/ns-d3ui-8104/captures/D1 Simulated Field_B_0001.fits";

    #[test]
    fn test_long_history_wraps_at_token_boundaries_and_reassembles() {
        let mut header = FitsHeader::new();
        header.add_history(LONG_HISTORY_LINE);
        header.add_history(LONG_PATH_HISTORY_LINE);
        let image = ImageData::from_u16(2, 1, 1, &[1, 2]);

        let path =
            std::env::temp_dir().join(format!("skotiq_history_wrap_{}.fits", std::process::id()));
        write_fits(&path, &image, &header).expect("write");
        let on_disk = std::fs::read(&path).expect("read");

        // No card may end mid-token: the digest and every path segment land
        // whole on one card. A continued card is marked, and only a continued
        // card may break a run of non-space characters.
        let mut bodies: Vec<String> = Vec::new();
        for chunk in on_disk[..2880].as_chunks::<80>().0.iter() {
            if chunk.starts_with(b"HISTORY ") {
                bodies.push(String::from_utf8_lossy(&chunk[8..]).trim_end().to_string());
            }
        }
        assert!(!bodies.is_empty(), "no HISTORY cards emitted");
        for body in &bodies {
            assert!(
                body.len() <= COMMENTARY_BODY_LEN,
                "card body overruns column 80: {body:?}"
            );
        }
        assert!(
            bodies
                .iter()
                .any(|b| b.contains("fingerprint=e2328f40d1890f8d378ab91a6195ab17")),
            "the fingerprint was split across cards: {bodies:?}"
        );
        assert!(
            bodies.iter().any(|b| b.contains("Field_B_0001.fits")),
            "the reference-light filename was split across cards: {bodies:?}"
        );
        // Every card that continues its line says so; the last one does not.
        let continued: Vec<bool> = bodies
            .iter()
            .map(|b| trailing_marker_run(b) % 2 == 1)
            .collect();
        assert!(
            continued.iter().any(|c| *c),
            "a wrapped line carried no continuation marker: {bodies:?}"
        );
        assert!(
            !continued[continued.len() - 1],
            "the final card claims a continuation that does not exist"
        );

        let (_image, read_back) = read_fits(&path).expect("read");
        let _ = std::fs::remove_file(&path);
        assert_eq!(
            read_back.history,
            vec![
                LONG_HISTORY_LINE.to_string(),
                LONG_PATH_HISTORY_LINE.to_string()
            ],
            "the reader did not reassemble the wrapped lines"
        );
    }

    #[test]
    fn test_commentary_cards_round_trip_edge_cases() {
        // A literal trailing ampersand must not be read as a continuation, a
        // token longer than a card must still break with one, and a line that
        // already fits must be left exactly as it is.
        let cases = [
            "short line",
            "trailing ampersand &",
            "double trailing ampersand &&",
            &"z".repeat(200),
            &format!("prefix {} suffix", "y".repeat(150)),
            LONG_HISTORY_LINE,
            LONG_PATH_HISTORY_LINE,
            "",
        ];
        for case in cases {
            let cards = commentary_cards(case);
            for card in &cards {
                assert!(
                    card.len() <= COMMENTARY_BODY_LEN,
                    "card body overruns column 80 for {case:?}: {card:?}"
                );
            }
            let joined = join_commentary_cards(cards.clone());
            assert_eq!(
                joined,
                vec![case.to_string()],
                "round trip lost text for {case:?} (cards {cards:?})"
            );
        }
    }

    #[test]
    fn test_history_written_before_this_convention_still_reads_as_written() {
        // A file whose HISTORY was hard-split by the old writer carries no
        // markers, so each of its cards stays its own line — the reader invents
        // no join it cannot prove.
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    1",
            "NAXIS2  =                    1",
            "HISTORY Calibration compared against light /home/scdouglas/.cache/ns-d3ui-8104/c",
            "HISTORY aptures/D1 Simulated Field_B_0001.fits",
        ];
        let data: Vec<u8> = vec![0x00, 0x10];
        let bytes = synth_fits_with_cards(&cards, &data);
        let (_image, header) = read_fits_from_bytes(&bytes).expect("read");
        assert_eq!(header.history.len(), 2);
        assert!(header.history[0].ends_with("/c"));
        assert!(header.history[1].starts_with("aptures/"));
    }

    #[test]
    fn test_inline_comment_round_trips() {
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    1",
            "NAXIS2  =                    1",
            "EXPTIME =                300.0 / total integration in seconds",
        ];
        let data: Vec<u8> = vec![0x00, 0x10];
        let bytes = synth_fits_with_cards(&cards, &data);
        let (_image, header) = read_fits_from_bytes(&bytes).expect("read");
        assert_eq!(
            header.get_comment("EXPTIME"),
            Some("total integration in seconds")
        );
    }

    #[test]
    fn test_naxis_4_rejected() {
        // 4-D cubes are not silently truncated; the reader must Err.
        let cards = [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    4",
            "NAXIS1  =                    1",
            "NAXIS2  =                    1",
            "NAXIS3  =                    1",
            "NAXIS4  =                    1",
        ];
        let data: Vec<u8> = vec![0x00, 0x10];
        let bytes = synth_fits_with_cards(&cards, &data);
        let err = read_fits_from_bytes(&bytes).unwrap_err();
        assert!(
            matches!(err, FitsError::Unsupported4DCube { naxis: 4 }),
            "expected Unsupported4DCube, got {:?}",
            err
        );
    }

    // XBAYROFF/YBAYROFF composition

    #[test]
    fn test_effective_bayer_pattern_zero_offset_identity() {
        for src in [
            BayerPattern::Rggb,
            BayerPattern::Bggr,
            BayerPattern::Grbg,
            BayerPattern::Gbrg,
        ] {
            assert_eq!(src.shifted(0, 0), src);
            assert_eq!(src.shifted(2, 4), src);
        }
    }

    #[test]
    fn test_effective_bayer_pattern_rggb_x1_y0_yields_grbg() {
        //6 explicit case.
        assert_eq!(BayerPattern::Rggb.shifted(1, 0), BayerPattern::Grbg);
    }

    #[test]
    fn test_effective_bayer_pattern_rggb_x0_y1_yields_gbrg() {
        assert_eq!(BayerPattern::Rggb.shifted(0, 1), BayerPattern::Gbrg);
    }

    #[test]
    fn test_effective_bayer_pattern_rggb_x1_y1_yields_bggr() {
        assert_eq!(BayerPattern::Rggb.shifted(1, 1), BayerPattern::Bggr);
    }

    #[test]
    fn test_effective_bayer_pattern_negative_offset_wraps() {
        // -1 has the same parity as +1, so result must match.
        assert_eq!(
            BayerPattern::Rggb.shifted(-1, 0),
            BayerPattern::Rggb.shifted(1, 0),
        );
    }

    #[test]
    fn a_frame_s_filter_is_its_pattern_moved_by_its_offsets() {
        let mut header = FitsHeader::new();
        assert_eq!(read_color_filter_array(&header), None);
        header.set_string("BAYERPAT", "BGGR");
        assert_eq!(
            read_color_filter_array(&header),
            Some(ColorFilterArray::Bayer(BayerPattern::Bggr))
        );
        header.set_string("BAYERPAT", "RGGB");
        header.set_int("XBAYROFF", 1);
        header.set_int("YBAYROFF", 0);
        assert_eq!(
            read_color_filter_array(&header),
            Some(ColorFilterArray::Bayer(BayerPattern::Grbg))
        );
    }

    // Header carry-over

    /// The astrometry set must cover the whole WCS a solved frame carries,
    /// including SIP: a partial copy yields a header that reads as solved while
    /// projecting to the wrong sky.
    #[test]
    fn astrometry_keywords_cover_the_wcs_and_sip_sets() {
        for key in [
            "CRVAL1", "CRVAL2", "CRPIX1", "CRPIX2", "CD1_1", "CD2_2", "CDELT1", "CROTA2", "CTYPE1",
            "CUNIT2", "EQUINOX", "RADESYS", "RADECSYS", "LONPOLE", "LATPOLE", "WCSAXES", "PC1_2",
            "PV2_1", "A_ORDER", "B_ORDER", "AP_ORDER", "BP_ORDER", "A_2_0", "B_0_2", "AP_1_1",
            "BP_3_0",
        ] {
            assert!(is_astrometry_keyword(key), "{key} must be astrometry");
        }
        // Neighbours that merely start with the same letters are not.
        for key in [
            "AIRMASS", "APTDIA", "BITPIX", "CCD-TEMP", "PALETTE", "OBJECT", "CALSTAT", "BSCALE",
            "A", "AP", "CD", "A_ORDERX",
        ] {
            assert!(!is_astrometry_keyword(key), "{key} must not be astrometry");
        }
    }

    /// A CFA pattern describes a raw mosaic. Carrying it onto a processed frame
    /// makes a downstream reader debayer an already-colour image, so it is
    /// deliberately outside the observation set.
    #[test]
    fn observation_keywords_exclude_the_cfa_pattern() {
        for key in [
            "OBJECT", "FILTER", "DATE-OBS", "EXPTIME", "GAIN", "CCD-TEMP", "INSTRUME",
        ] {
            assert!(is_observation_keyword(key), "{key} must be observation");
        }
        for key in ["BAYERPAT", "XBAYROFF", "YBAYROFF", "CRVAL1", "NAXIS1"] {
            assert!(!is_observation_keyword(key), "{key} must not be carried");
        }
    }

    /// The carry-over never overwrites what the writing op already stated about
    /// its own output, and it reports what it did — including that it carried
    /// nothing from an unsolved input.
    #[test]
    fn carry_source_header_keeps_the_writer_s_own_cards() {
        let mut source = FitsHeader::new();
        source.set_float("CRVAL1", 83.822);
        source.set_string("CTYPE1", "RA---TAN-SIP");
        source.set_int("A_ORDER", 2);
        source.set_float("EXPTIME", 60.0);
        source.set_string("OBJECT", "M42");

        let mut dst = FitsHeader::new();
        dst.set_string("IMAGETYP", "MASTER_LIGHT");
        // The writer computed a total exposure; the source's per-frame value
        // must not replace it.
        dst.set_float("EXPTIME", 1800.0);

        carry_source_header(&mut dst, &source);

        assert_eq!(dst.get_float("CRVAL1"), Some(83.822));
        assert_eq!(dst.get_string("CTYPE1"), Some("RA---TAN-SIP"));
        assert_eq!(dst.get_int("A_ORDER"), Some(2));
        assert_eq!(dst.get_string("OBJECT"), Some("M42"));
        assert_eq!(
            dst.get_float("EXPTIME"),
            Some(1800.0),
            "the writer's value wins"
        );
        assert_eq!(dst.get_string("IMAGETYP"), Some("MASTER_LIGHT"));
        assert!(
            dst.history
                .iter()
                .any(|h| h.contains("Carried 3 astrometry")),
            "{:?}",
            dst.history
        );

        // An unsolved source states the absence rather than leaving it a mystery.
        let mut empty_dst = FitsHeader::new();
        carry_source_header(&mut empty_dst, &FitsHeader::new());
        assert_eq!(empty_dst.get_float("CRVAL1"), None);
        assert!(empty_dst
            .history
            .iter()
            .any(|h| h.contains("Carried 0 astrometry and 0 observation cards")));
    }

    /// The header-only read must agree card for card with the full read, so a
    /// caller that skips the pixels is not comparing a different header.
    #[test]
    fn read_fits_header_matches_the_full_read() {
        let dir = std::env::temp_dir().join(format!("sk_fits_hdr_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("frame.fits");

        let image = ImageData::from_u16(4, 3, 1, &[1000u16; 12]);
        let mut h = FitsHeader::new();
        h.set_string("IMAGETYP", "LIGHT");
        h.set_float("CCD-TEMP", -10.5);
        h.set_string("DATE-OBS", "2026-08-14T21:00:00");
        write_fits(&path, &image, &h).expect("write frame");

        let (_img, full) = read_fits(&path).expect("full read");
        let only = read_fits_header(&path).expect("header-only read");
        assert_eq!(only.get_string("IMAGETYP"), full.get_string("IMAGETYP"));
        assert_eq!(only.get_float("CCD-TEMP"), full.get_float("CCD-TEMP"));
        assert_eq!(only.get_string("DATE-OBS"), full.get_string("DATE-OBS"));
        assert_eq!(only.get_int("NAXIS1"), Some(4));
        assert_eq!(
            only.get("BZERO").is_none(),
            full.get("BZERO").is_none(),
            "both readers strip the encoding cards they folded into the samples"
        );

        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod write_wcs_tests {
    use super::*;

    /// A solved frame carries its WCS, and nothing else about it changes: the
    /// pixels and every card the save wrote are kept.
    #[test]
    fn a_solved_frame_carries_its_wcs_and_keeps_its_pixels_and_cards() {
        let dir = std::env::temp_dir().join(format!("write-wcs-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("M34_L_0001.fits");
        let pixels: Vec<u16> = (0..400 * 300).map(|i| (i % 4000) as u16).collect();
        let image = ImageData::from_u16(400, 300, 1, &pixels);
        let mut header = FitsHeader::new();
        header.set_float("EXPTIME", 120.0);
        header.set_string("PIERSIDE", "West");
        header.set_string("OBJECT", "M34");
        write_fits(&path, &image, &header).unwrap();

        let wcs = crate::SipWcs::from_pointing(40.1, 42.3, 12.0, 1.46, 400, 300);
        crate::write_wcs_into_frame(&path, &wcs).unwrap();

        let (read_back, parsed) = read_fits(&path).unwrap();
        assert_eq!(parsed.get_float("CRVAL1"), Some(40.1));
        assert_eq!(parsed.get_float("CRVAL2"), Some(42.3));
        assert_eq!(parsed.get_float("CRPIX1"), Some(200.5));
        assert_eq!(parsed.get_float("CRPIX2"), Some(150.5));
        assert_eq!(parsed.get_string("CTYPE1"), Some("RA---TAN"));
        assert_eq!(parsed.get_string("RADESYS"), Some("ICRS"));
        assert_eq!(parsed.get_float("EQUINOX"), Some(2000.0));
        assert_eq!(parsed.get_float("EXPTIME"), Some(120.0));
        assert_eq!(parsed.get_string("PIERSIDE"), Some("West"));
        assert_eq!(parsed.get_string("OBJECT"), Some("M34"));
        assert_eq!(read_back.as_u16().unwrap(), pixels);
        let leftovers: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name())
            .collect();
        assert_eq!(
            leftovers.len(),
            1,
            "no staging file is left behind: {leftovers:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

#[cfg(test)]
mod ascii_header_tests {
    use super::*;

    /// Every header byte is printable ASCII, whatever text a card was given:
    /// a mosaic name with a degree sign, an accented observer, a comment in
    /// microns, a long HISTORY line with a dash.
    #[test]
    fn every_header_byte_is_printable_ascii() {
        let path = std::env::temp_dir().join(format!("ascii-header-{}.fits", std::process::id()));
        let mut header = FitsHeader::new();
        header.set_string("OBJECT", "M31 Mosaic 2×2 at 41.27° · Panel 1");
        header.set_string("OBSERVER", "Zoë Müller");
        header.set_float("XPIXSZ", 3.76);
        header.set_comment("XPIXSZ", "[µm] pixel size");
        header.set_string("MOSNAME", &format!("{} 30′ steps ✓", "a".repeat(80)));
        header.set_string("Field rotation °", "12°");
        header.add_history("Stacked — 40 frames, σ-clipped");
        write_fits(&path, &ImageData::from_u16(2, 2, 1, &[1, 2, 3, 4]), &header).unwrap();

        let bytes = std::fs::read(&path).unwrap();
        let end = bytes
            .chunks(80)
            .position(|card| card.starts_with(b"END "))
            .unwrap();
        assert!(
            bytes[..(end + 1) * 80]
                .iter()
                .all(|b| (0x20..0x7f).contains(b)),
            "{}",
            String::from_utf8_lossy(&bytes[..(end + 1) * 80])
        );
        let (_, back) = read_fits(&path).unwrap();
        std::fs::remove_file(&path).unwrap();
        assert_eq!(
            back.get_string("OBJECT"),
            Some("M31 Mosaic 2x2 at 41.27deg - Panel 1")
        );
        assert_eq!(back.get_string("OBSERVER"), Some("Zoe Muller"));
        assert_eq!(back.get_comment("XPIXSZ"), Some("[um] pixel size"));
        assert!(back
            .get_string("MOSNAME")
            .is_some_and(|name| name.ends_with(" 30' steps ?")));
        assert_eq!(back.history, ["Stacked - 40 frames, ?-clipped"]);
    }
}
