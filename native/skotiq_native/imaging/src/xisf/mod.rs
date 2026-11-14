//! XISF 1.0, PixInsight's native image format
//! (<https://pixinsight.com/doc/docs/XISF-1.0-spec/XISF-1.0-spec.html>).
//!
//! Reads monolithic `.xisf` files and distributed units (`.xish` headers with
//! their `.xisb` or plain data files); writes monolithic files. A unit is
//! parsed into [`XisfUnit`]: the file metadata, every image with its
//! properties, FITS keywords and ancillary elements, and, verbatim, every
//! element this reader does not model, so a metadata rewrite keeps them.
//!
//! The app's own frame (`ImageData` + `FitsHeader`) maps to and from a unit in
//! [`fits_map`]; consumers go through `frame_io` and never see this module.

mod block;
mod codec;
mod color;
mod fits_map;
mod header;
mod pixels;
mod property;
mod write;

#[cfg(test)]
mod tests;

pub use codec::{shuffle, unshuffle, Checksum, ChecksumAlgorithm, Compression, XisfCodec};
pub use color::RgbWorkingSpace;
pub use property::{Element, PropertyValue, XisfProperty};
pub use write::{XisfCompression, XisfWriteOptions};

pub(crate) use fits_map::{apply_header, header_from_image, image_header_from_fits};
pub(crate) use write::{rewrite_unit_metadata, write_images};

use crate::{ImageData, PixelType};
use block::DataBlock;
use std::path::{Path, PathBuf};

/// The signature that opens a monolithic XISF file.
pub const XISF_SIGNATURE: &[u8; 8] = b"XISF0100";
/// The signature that opens an XISF data blocks file.
pub(crate) const XISB_SIGNATURE: &[u8; 8] = b"XISB0100";

#[derive(Debug)]
pub enum XisfError {
    Io(std::io::Error),
    /// The file breaks the format in a way that leaves it unreadable.
    Malformed(String),
    /// A data block does not hold what its header says it holds.
    Corrupt(String),
    ChecksumMismatch {
        what: String,
        algorithm: ChecksumAlgorithm,
    },
    UnsupportedCodec(String),
    UnsupportedChecksum(String),
    /// Valid XISF the app cannot represent.
    Unsupported(String),
    NoImage,
    NoSuchImage {
        index: usize,
        count: usize,
    },
}

impl std::fmt::Display for XisfError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            XisfError::Io(e) => write!(f, "{e}"),
            XisfError::Malformed(what) => write!(f, "this is not a readable XISF file: {what}"),
            XisfError::Corrupt(what) => write!(f, "the XISF file is damaged: {what}"),
            XisfError::ChecksumMismatch { what, algorithm } => write!(
                f,
                "the XISF file is damaged: the {what} does not match its {} checksum",
                algorithm.name()
            ),
            XisfError::UnsupportedCodec(name) => write!(
                f,
                "the XISF file is compressed with \"{name}\", which Skotiq cannot read"
            ),
            XisfError::UnsupportedChecksum(name) => write!(
                f,
                "the XISF file is protected with a \"{name}\" checksum, which Skotiq cannot check"
            ),
            XisfError::Unsupported(what) => write!(f, "Skotiq cannot open this XISF image: {what}"),
            XisfError::NoImage => write!(f, "the XISF file holds no image"),
            XisfError::NoSuchImage { index, count } => write!(
                f,
                "the XISF file holds {count} image(s); there is no image {}",
                index + 1
            ),
        }
    }
}

impl std::error::Error for XisfError {}

impl From<std::io::Error> for XisfError {
    fn from(e: std::io::Error) -> Self {
        if e.kind() == std::io::ErrorKind::UnexpectedEof {
            XisfError::Corrupt("the file ends before its data does".to_string())
        } else {
            XisfError::Io(e)
        }
    }
}

/// Image sample formats (Table 11).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SampleFormat {
    UInt8,
    UInt16,
    UInt32,
    UInt64,
    Float32,
    Float64,
    Complex32,
    Complex64,
}

impl SampleFormat {
    pub fn name(self) -> &'static str {
        match self {
            SampleFormat::UInt8 => "UInt8",
            SampleFormat::UInt16 => "UInt16",
            SampleFormat::UInt32 => "UInt32",
            SampleFormat::UInt64 => "UInt64",
            SampleFormat::Float32 => "Float32",
            SampleFormat::Float64 => "Float64",
            SampleFormat::Complex32 => "Complex32",
            SampleFormat::Complex64 => "Complex64",
        }
    }

    fn parse(text: &str) -> Result<Self, XisfError> {
        Ok(match text.trim() {
            "UInt8" => SampleFormat::UInt8,
            "UInt16" => SampleFormat::UInt16,
            "UInt32" => SampleFormat::UInt32,
            "UInt64" => SampleFormat::UInt64,
            "Float32" => SampleFormat::Float32,
            "Float64" => SampleFormat::Float64,
            "Complex32" => SampleFormat::Complex32,
            "Complex64" => SampleFormat::Complex64,
            other => {
                return Err(XisfError::Malformed(format!(
                    "unknown sample format \"{other}\""
                )))
            }
        })
    }

    /// Bytes per stored sample.
    pub fn size(self) -> usize {
        match self {
            SampleFormat::UInt8 => 1,
            SampleFormat::UInt16 => 2,
            SampleFormat::UInt32 | SampleFormat::Float32 => 4,
            SampleFormat::UInt64 | SampleFormat::Float64 | SampleFormat::Complex32 => 8,
            SampleFormat::Complex64 => 16,
        }
    }

    pub fn of(pixel_type: PixelType) -> Self {
        match pixel_type {
            PixelType::U8 => SampleFormat::UInt8,
            PixelType::U16 => SampleFormat::UInt16,
            PixelType::U32 => SampleFormat::UInt32,
            PixelType::F32 => SampleFormat::Float32,
            PixelType::F64 => SampleFormat::Float64,
        }
    }

    pub fn is_float(self) -> bool {
        matches!(self, SampleFormat::Float32 | SampleFormat::Float64)
    }

    /// The default representable range of an integer format, `[0, 2^k - 1]`.
    fn integer_range(self) -> Option<(f64, f64)> {
        match self {
            SampleFormat::UInt8 => Some((0.0, u8::MAX as f64)),
            SampleFormat::UInt16 => Some((0.0, u16::MAX as f64)),
            SampleFormat::UInt32 => Some((0.0, u32::MAX as f64)),
            SampleFormat::UInt64 => Some((0.0, u64::MAX as f64)),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColorSpace {
    Gray,
    Rgb,
    CieLab,
}

impl ColorSpace {
    pub fn name(self) -> &'static str {
        match self {
            ColorSpace::Gray => "Gray",
            ColorSpace::Rgb => "RGB",
            ColorSpace::CieLab => "CIELab",
        }
    }

    fn parse(text: &str) -> Result<Self, XisfError> {
        Ok(match text.trim() {
            "Gray" => ColorSpace::Gray,
            "RGB" => ColorSpace::Rgb,
            "CIELab" => ColorSpace::CieLab,
            other => {
                return Err(XisfError::Malformed(format!(
                    "unknown color space \"{other}\""
                )))
            }
        })
    }

    /// Channels that carry color; the rest are alpha channels.
    pub fn nominal_channels(self) -> u64 {
        match self {
            ColorSpace::Gray => 1,
            ColorSpace::Rgb | ColorSpace::CieLab => 3,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PixelStorage {
    Planar,
    Normal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ByteOrder {
    #[default]
    Little,
    Big,
}

/// A `FITSKeyword` element: the value is FITS value text (strings keep their
/// quotes), and `COMMENT`/`HISTORY` carry their text in `comment`.
#[derive(Debug, Clone, PartialEq)]
pub struct FitsKeyword {
    pub name: String,
    pub value: String,
    pub comment: String,
}

/// A `ColorFilterArray` element, oriented as the pattern lies on the image.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ColorFilterArray {
    pub pattern: String,
    pub width: u32,
    pub height: u32,
    pub name: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Resolution {
    pub horizontal: f64,
    pub vertical: f64,
    /// `inch` or `cm`.
    pub unit: String,
}

/// A `DisplayFunction` element: midtones, shadows, highlights and the two
/// dynamic range expansion parameters, each for red/gray, green, blue and
/// lightness.
#[derive(Debug, Clone, PartialEq)]
pub struct DisplayFunction {
    pub m: [f64; 4],
    pub s: [f64; 4],
    pub h: [f64; 4],
    pub l: [f64; 4],
    pub r: [f64; 4],
    pub name: Option<String>,
}

/// One `Image` (or `Thumbnail`) element: everything but the pixels, which are
/// read on demand.
#[derive(Debug, Clone)]
pub struct XisfImageHeader {
    /// Lengths along each axis; a two-dimensional image is `[width, height]`.
    pub dimensions: Vec<u64>,
    pub channels: u64,
    pub sample_format: SampleFormat,
    pub bounds: Option<(f64, f64)>,
    pub color_space: ColorSpace,
    pub pixel_storage: PixelStorage,
    pub image_type: Option<String>,
    pub offset: Option<f64>,
    pub orientation: Option<String>,
    pub id: Option<String>,
    pub uuid: Option<String>,
    pub properties: Vec<XisfProperty>,
    pub fits_keywords: Vec<FitsKeyword>,
    pub color_filter_array: Option<ColorFilterArray>,
    pub resolution: Option<Resolution>,
    /// The ICC profile bytes, big-endian as the ICC specification stores them.
    pub icc_profile: Option<Vec<u8>>,
    pub display_function: Option<DisplayFunction>,
    pub rgb_working_space: Option<RgbWorkingSpace>,
    pub thumbnail: Option<Box<XisfImageHeader>>,
    /// Attributes of the element this reader does not know, kept for rewrites.
    pub(crate) extra_attributes: Vec<(String, String)>,
    /// Child elements this reader does not model, verbatim.
    pub(crate) preserved_children: Vec<String>,
    pub(crate) block: Option<DataBlock>,
}

impl XisfImageHeader {
    pub(crate) fn new(dimensions: Vec<u64>, channels: u64, sample_format: SampleFormat) -> Self {
        Self {
            dimensions,
            channels,
            sample_format,
            bounds: None,
            color_space: ColorSpace::Gray,
            pixel_storage: PixelStorage::Planar,
            image_type: None,
            offset: None,
            orientation: None,
            id: None,
            uuid: None,
            properties: Vec::new(),
            fits_keywords: Vec::new(),
            color_filter_array: None,
            resolution: None,
            icc_profile: None,
            display_function: None,
            rgb_working_space: None,
            thumbnail: None,
            extra_attributes: Vec::new(),
            preserved_children: Vec::new(),
            block: None,
        }
    }

    pub fn width(&self) -> u64 {
        self.dimensions.first().copied().unwrap_or(0)
    }

    /// The height of a two-dimensional image; one-dimensional images are one
    /// row high.
    pub fn height(&self) -> u64 {
        self.dimensions.get(1).copied().unwrap_or(1)
    }

    pub fn pixel_count(&self) -> Option<u64> {
        self.dimensions
            .iter()
            .try_fold(1u64, |acc, &d| acc.checked_mul(d))
    }

    /// Bytes of the uncompressed pixel data, or `None` when the geometry
    /// overflows.
    pub fn data_len(&self) -> Option<u64> {
        self.pixel_count()?
            .checked_mul(self.channels)?
            .checked_mul(self.sample_format.size() as u64)
    }

    pub fn property(&self, id: &str) -> Option<&PropertyValue> {
        self.properties
            .iter()
            .find(|p| p.id == id)
            .map(|p| &p.value)
    }

    /// The representable range: `bounds` when given, else the integer
    /// format's full range.
    pub fn representable_range(&self) -> Option<(f64, f64)> {
        self.bounds.or_else(|| self.sample_format.integer_range())
    }
}

/// Where a unit's header came from, so its data blocks can be found.
#[derive(Debug, Clone)]
pub(crate) enum UnitSource {
    Monolithic(PathBuf),
    Distributed {
        header_dir: PathBuf,
    },
    /// A monolithic unit held in memory, such as a frame a camera server sent.
    InMemory(std::sync::Arc<[u8]>),
}

/// A parsed XISF unit.
#[derive(Debug, Clone)]
pub struct XisfUnit {
    /// The `Metadata` element's properties (`XISF:*`).
    pub metadata: Vec<XisfProperty>,
    /// Properties stored directly under the root element.
    pub properties: Vec<XisfProperty>,
    pub images: Vec<XisfImageHeader>,
    /// Root children this reader does not model (tables, structures,
    /// extension elements), verbatim.
    pub(crate) preserved: Vec<String>,
    pub(crate) source: UnitSource,
}

impl XisfUnit {
    pub fn metadata_property(&self, id: &str) -> Option<&PropertyValue> {
        self.metadata.iter().find(|p| p.id == id).map(|p| &p.value)
    }

    pub fn image(&self, index: usize) -> Result<&XisfImageHeader, XisfError> {
        if self.images.is_empty() {
            return Err(XisfError::NoImage);
        }
        self.images.get(index).ok_or(XisfError::NoSuchImage {
            index,
            count: self.images.len(),
        })
    }

    /// Decode one image's pixels into the app's interleaved layout.
    pub fn read_pixels(&self, index: usize) -> Result<ImageData, XisfError> {
        pixels::read_image(self, self.image(index)?, "image")
    }

    /// Decode the first image's thumbnail, when it has one.
    pub fn read_thumbnail(&self) -> Result<Option<ImageData>, XisfError> {
        match self.image(0)?.thumbnail.as_deref() {
            Some(thumbnail) => pixels::read_image(self, thumbnail, "thumbnail").map(Some),
            None => Ok(None),
        }
    }
}

/// Whether `path` names a distributed unit's header file.
fn is_header_file(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .is_some_and(|e| e.eq_ignore_ascii_case("xish"))
}

/// Parse a unit's header without decoding any pixel data.
pub fn read_xisf_unit(path: &Path) -> Result<XisfUnit, XisfError> {
    if is_header_file(path) {
        let xml = read_bounded_text(path)?;
        let header_dir = path
            .parent()
            .map(Path::to_path_buf)
            .unwrap_or_else(|| PathBuf::from("."));
        header::parse_unit(&xml, UnitSource::Distributed { header_dir })
    } else {
        let xml = block::read_monolithic_header(path)?;
        header::parse_unit(&xml, UnitSource::Monolithic(path.to_path_buf()))
    }
}

/// Parse a monolithic unit held in memory without decoding any pixel data.
pub fn read_xisf_bytes(bytes: &[u8]) -> Result<XisfUnit, XisfError> {
    let xml = block::monolithic_header(&mut std::io::Cursor::new(bytes), bytes.len() as u64)?;
    header::parse_unit(&xml, UnitSource::InMemory(bytes.into()))
}

fn read_bounded_text(path: &Path) -> Result<String, XisfError> {
    let len = std::fs::metadata(path)?.len();
    if len > header::MAX_HEADER_LEN as u64 {
        return Err(XisfError::Malformed(format!(
            "the XISF header file is {len} bytes long, more than any header needs"
        )));
    }
    String::from_utf8(std::fs::read(path)?)
        .map_err(|_| XisfError::Malformed("the XISF header is not UTF-8 text".to_string()))
}

/// Whether the first bytes of a file are those of an XISF unit: the
/// monolithic signature or, for a header file, an XML document whose root is
/// `xisf`.
pub fn is_xisf_head(head: &[u8]) -> bool {
    let window = &head[..head.len().min(512)];
    head.starts_with(XISF_SIGNATURE)
        || (head.starts_with(b"<?xml") && window.windows(5).any(|w| w == b"<xisf"))
}
