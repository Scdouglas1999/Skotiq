//! XISF (Extensible Image Serialization Format) support
//!
//! XISF is PixInsight's native format. Structure:
//! - XML header with metadata
//! - Binary data block(s)
//! - Optional compression (zlib, lz4, zstd)
//!
//! # `unwrap_or` policy
//!
//! All XISF `unwrap_or` sites map to format-spec defaults:
//!
//! * `numberOfImages.unwrap_or(1)` — single image is the XISF spec default
//!   for files without explicit count.
//! * `sampleFormat.unwrap_or("UInt16")` / `colorSpace.unwrap_or("Gray")` —
//!   XISF 1.0 defaults (16-bit unsigned, monochrome) per
//!   <https://pixinsight.com/doc/docs/XISF-1.0-spec/>.
//! * `propertyType.unwrap_or("String")` and the per-type parse fallback
//!   `unwrap_or(XisfProperty::String(value.to_string()))` — when a typed
//!   parse (`Int64`, `Float32`, `Boolean`, …) fails, fall back to the raw
//!   string. PixInsight is permissive about property values and keeping
//!   the raw string preserves round-tripability through the metadata
//!   panel without losing the value entirely.
//! * `boolean header attr.unwrap_or(false)` — XISF optional booleans
//!   default to `false` per the spec.

use crate::{ImageData, PixelType};
use quick_xml::events::{BytesDecl, BytesEnd, BytesStart, Event};
use quick_xml::{Reader, Writer};
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, BufWriter, Cursor, Read, Seek, SeekFrom, Write};
use std::path::Path;

/// XISF file magic signature
const XISF_MAGIC: &[u8; 8] = b"XISF0100";
const XISF_ALIGNMENT: usize = 16;
const MAX_OFFSET_RESOLUTION_PASSES: usize = 8;

/// XISF metadata
#[derive(Debug, Clone, Default)]
pub struct XisfMetadata {
    pub properties: HashMap<String, XisfProperty>,
    pub fits_keywords: HashMap<String, String>,
}

/// XISF property types
#[derive(Debug, Clone)]
pub enum XisfProperty {
    String(String),
    Int8(i8),
    Int16(i16),
    Int32(i32),
    Int64(i64),
    UInt8(u8),
    UInt16(u16),
    UInt32(u32),
    UInt64(u64),
    Float32(f32),
    Float64(f64),
    Boolean(bool),
    TimePoint(String), // ISO 8601 format
}

impl XisfProperty {
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            XisfProperty::Float64(f) => Some(*f),
            XisfProperty::Float32(f) => Some(*f as f64),
            XisfProperty::Int64(i) => Some(*i as f64),
            XisfProperty::Int32(i) => Some(*i as f64),
            XisfProperty::Int16(i) => Some(*i as f64),
            XisfProperty::Int8(i) => Some(*i as f64),
            XisfProperty::UInt64(u) => Some(*u as f64),
            XisfProperty::UInt32(u) => Some(*u as f64),
            XisfProperty::UInt16(u) => Some(*u as f64),
            XisfProperty::UInt8(u) => Some(*u as f64),
            _ => None,
        }
    }

    pub fn as_string(&self) -> Option<&str> {
        match self {
            XisfProperty::String(s) => Some(s),
            XisfProperty::TimePoint(s) => Some(s),
            _ => None,
        }
    }

    /// This property as a FITS on-card value token, so a property flattened
    /// into `ImageReadResult::header` alongside the FITS keywords survives
    /// being written back out. See `FitsValue::to_header_string`.
    pub fn to_header_string(&self) -> String {
        match self {
            XisfProperty::String(s) | XisfProperty::TimePoint(s) => {
                crate::FitsValue::String(s.clone()).to_header_string()
            }
            XisfProperty::Int8(i) => crate::FitsValue::Integer(*i as i64).to_header_string(),
            XisfProperty::Int16(i) => crate::FitsValue::Integer(*i as i64).to_header_string(),
            XisfProperty::Int32(i) => crate::FitsValue::Integer(*i as i64).to_header_string(),
            XisfProperty::Int64(i) => crate::FitsValue::Integer(*i).to_header_string(),
            XisfProperty::UInt8(u) => crate::FitsValue::Integer(*u as i64).to_header_string(),
            XisfProperty::UInt16(u) => crate::FitsValue::Integer(*u as i64).to_header_string(),
            XisfProperty::UInt32(u) => crate::FitsValue::Integer(*u as i64).to_header_string(),
            // Why: FITS integer cards are signed 64-bit, so a u64 above i64::MAX
            // has no integer representation; emit it as a float rather than
            // wrapping to a negative.
            XisfProperty::UInt64(u) => match i64::try_from(*u) {
                Ok(i) => crate::FitsValue::Integer(i).to_header_string(),
                Err(_) => crate::FitsValue::Float(*u as f64).to_header_string(),
            },
            XisfProperty::Float32(f) => crate::FitsValue::Float(*f as f64).to_header_string(),
            XisfProperty::Float64(f) => crate::FitsValue::Float(*f).to_header_string(),
            XisfProperty::Boolean(b) => crate::FitsValue::Boolean(*b).to_header_string(),
        }
    }
}

/// XISF error types
#[derive(Debug)]
pub enum XisfError {
    Io(std::io::Error),
    InvalidFormat(String),
    XmlParse(String),
    Compression(String),
    UnsupportedSampleFormat(String),
}

impl std::fmt::Display for XisfError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            XisfError::Io(e) => write!(f, "IO error: {}", e),
            XisfError::InvalidFormat(s) => write!(f, "Invalid XISF format: {}", s),
            XisfError::XmlParse(s) => write!(f, "XML parse error: {}", s),
            XisfError::Compression(s) => write!(f, "Compression error: {}", s),
            XisfError::UnsupportedSampleFormat(s) => {
                write!(f, "Unsupported sample format: {}", s)
            }
        }
    }
}

impl std::error::Error for XisfError {}

impl From<std::io::Error> for XisfError {
    fn from(e: std::io::Error) -> Self {
        XisfError::Io(e)
    }
}

impl From<quick_xml::Error> for XisfError {
    fn from(e: quick_xml::Error) -> Self {
        XisfError::XmlParse(e.to_string())
    }
}

impl From<quick_xml::events::attributes::AttrError> for XisfError {
    fn from(e: quick_xml::events::attributes::AttrError) -> Self {
        XisfError::XmlParse(format!("XML attribute error: {}", e))
    }
}

/// Parsed image header information read from the XISF XML
struct ImageHeader {
    width: u32,
    height: u32,
    channels: u32,
    sample_format: String,
    #[allow(dead_code)]
    color_space: String,
    data_offset: usize,
    data_size: usize,
}

/// Read an XISF file
pub fn read_xisf(path: &Path) -> Result<(ImageData, XisfMetadata), XisfError> {
    let file = File::open(path)?;
    let mut reader = BufReader::new(file);

    // Read and verify magic signature
    let mut magic = [0u8; 8];
    reader.read_exact(&mut magic)?;

    if &magic != XISF_MAGIC {
        return Err(XisfError::InvalidFormat(
            "Invalid XISF magic signature".to_string(),
        ));
    }

    // Read header length (little-endian u32)
    let mut header_len_bytes = [0u8; 4];
    reader.read_exact(&mut header_len_bytes)?;
    let header_len = u32::from_le_bytes(header_len_bytes) as usize;

    // Skip reserved bytes (4 bytes)
    let mut reserved = [0u8; 4];
    reader.read_exact(&mut reserved)?;

    // Read XML header
    let mut xml_bytes = vec![0u8; header_len];
    reader.read_exact(&mut xml_bytes)?;

    // Parse XML header using quick-xml
    let (header, metadata) = parse_xisf_xml(&xml_bytes)?;

    // Seek to data block
    reader.seek(SeekFrom::Start(header.data_offset as u64))?;

    // Read pixel data
    let mut data = vec![0u8; header.data_size];
    reader.read_exact(&mut data)?;

    // Determine pixel type
    let pixel_type = match header.sample_format.as_str() {
        "UInt8" => PixelType::U8,
        "UInt16" => PixelType::U16,
        "UInt32" => PixelType::U32,
        "Float32" => PixelType::F32,
        "Float64" => PixelType::F64,
        other => return Err(XisfError::UnsupportedSampleFormat(other.to_string())),
    };

    // XISF stores data in channel-major order (all R, then all G, then all B)
    // We need to keep it as-is for processing
    let image = ImageData {
        width: header.width,
        height: header.height,
        channels: header.channels,
        pixel_type,
        data,
    };

    Ok((image, metadata))
}

/// Parse the XISF XML header using quick-xml, extracting both image header info and metadata.
fn parse_xisf_xml(xml_bytes: &[u8]) -> Result<(ImageHeader, XisfMetadata), XisfError> {
    let mut xml_reader = Reader::from_reader(xml_bytes);
    xml_reader.trim_text(true);

    let mut header: Option<ImageHeader> = None;
    let mut metadata = XisfMetadata::default();
    let mut buf = Vec::new();
    let mut inside_image = false;

    loop {
        match xml_reader.read_event_into(&mut buf) {
            Ok(Event::Start(ref e)) => {
                if e.name().as_ref() == b"Image" {
                    header = Some(parse_image_element(e)?);
                    inside_image = true;
                }
            }
            Ok(Event::Empty(ref e)) => {
                let tag_name = e.name();
                if tag_name.as_ref() == b"Image" {
                    // Self-closing Image element (unlikely but handle it)
                    header = Some(parse_image_element(e)?);
                } else if inside_image && tag_name.as_ref() == b"Property" {
                    parse_property_element(e, &mut metadata)?;
                } else if inside_image && tag_name.as_ref() == b"FITSKeyword" {
                    parse_fits_keyword_element(e, &mut metadata)?;
                }
            }
            Ok(Event::End(ref e)) => {
                if e.name().as_ref() == b"Image" {
                    inside_image = false;
                }
            }
            Ok(Event::Eof) => break,
            Err(e) => {
                return Err(XisfError::XmlParse(format!(
                    "Error at position {}: {}",
                    xml_reader.buffer_position(),
                    e
                )));
            }
            _ => {}
        }
        buf.clear();
    }

    let header = header.ok_or_else(|| XisfError::XmlParse("No Image element found".to_string()))?;

    Ok((header, metadata))
}

/// Parse the <Image> element's attributes to extract geometry, sampleFormat, colorSpace,
/// bounds, and attachment location.
fn parse_image_element(element: &BytesStart) -> Result<ImageHeader, XisfError> {
    let mut geometry: Option<String> = None;
    let mut sample_format: Option<String> = None;
    let mut color_space: Option<String> = None;
    let mut location: Option<String> = None;

    for attr_result in element.attributes() {
        let attr = attr_result?;
        let key = std::str::from_utf8(attr.key.as_ref())
            .map_err(|e| XisfError::XmlParse(format!("Invalid UTF-8 attribute key: {}", e)))?;
        let value = attr.unescape_value().map_err(|e| {
            XisfError::XmlParse(format!("Error unescaping attribute '{}': {}", key, e))
        })?;

        match key {
            "geometry" => geometry = Some(value.into_owned()),
            "sampleFormat" => sample_format = Some(value.into_owned()),
            "colorSpace" => color_space = Some(value.into_owned()),
            "location" => location = Some(value.into_owned()),
            // bounds and other attributes are noted but not needed for reading
            _ => {}
        }
    }

    // Parse geometry "W:H" or "W:H:C"
    let geometry_str = geometry
        .ok_or_else(|| XisfError::XmlParse("Missing geometry attribute on Image".to_string()))?;
    let geo_parts: Vec<&str> = geometry_str.split(':').collect();

    let width: u32 = geo_parts
        .first()
        .ok_or_else(|| XisfError::XmlParse("Missing width in geometry".to_string()))?
        .parse()
        .map_err(|_| XisfError::XmlParse(format!("Invalid width in geometry: {}", geometry_str)))?;

    let height: u32 = geo_parts
        .get(1)
        .ok_or_else(|| XisfError::XmlParse("Missing height in geometry".to_string()))?
        .parse()
        .map_err(|_| {
            XisfError::XmlParse(format!("Invalid height in geometry: {}", geometry_str))
        })?;

    let channels: u32 = geo_parts
        .get(2)
        .map(|s| {
            s.parse().map_err(|_| {
                XisfError::XmlParse(format!("Invalid channels in geometry: {}", geometry_str))
            })
        })
        .transpose()?
        .unwrap_or(1);

    let sample_format = sample_format.unwrap_or_else(|| "UInt16".to_string());
    let color_space = color_space.unwrap_or_else(|| "Gray".to_string());

    // Parse location "attachment:OFFSET:SIZE"
    let location_str = location
        .ok_or_else(|| XisfError::XmlParse("Missing location attribute on Image".to_string()))?;

    let (data_offset, data_size) = parse_attachment_location(&location_str)?;

    Ok(ImageHeader {
        width,
        height,
        channels,
        sample_format,
        color_space,
        data_offset,
        data_size,
    })
}

/// Parse a <Property> element and insert into metadata.
fn parse_property_element(
    element: &BytesStart,
    metadata: &mut XisfMetadata,
) -> Result<(), XisfError> {
    let mut id: Option<String> = None;
    let mut prop_type: Option<String> = None;
    let mut value: Option<String> = None;

    for attr_result in element.attributes() {
        let attr = attr_result?;
        let key = std::str::from_utf8(attr.key.as_ref())
            .map_err(|e| XisfError::XmlParse(format!("Invalid UTF-8 attribute key: {}", e)))?;
        let attr_value = attr.unescape_value().map_err(|e| {
            XisfError::XmlParse(format!("Error unescaping attribute '{}': {}", key, e))
        })?;

        match key {
            "id" => id = Some(attr_value.into_owned()),
            "type" => prop_type = Some(attr_value.into_owned()),
            "value" => value = Some(attr_value.into_owned()),
            _ => {}
        }
    }

    if let (Some(id), Some(value)) = (id, value) {
        let prop_type = prop_type.unwrap_or_else(|| "String".to_string());
        let property = parse_property_value(&value, &prop_type);
        metadata.properties.insert(id, property);
    }

    Ok(())
}

/// Parse a <FITSKeyword> element and insert into metadata.
fn parse_fits_keyword_element(
    element: &BytesStart,
    metadata: &mut XisfMetadata,
) -> Result<(), XisfError> {
    let mut name: Option<String> = None;
    let mut value: Option<String> = None;

    for attr_result in element.attributes() {
        let attr = attr_result?;
        let key = std::str::from_utf8(attr.key.as_ref())
            .map_err(|e| XisfError::XmlParse(format!("Invalid UTF-8 attribute key: {}", e)))?;
        let attr_value = attr.unescape_value().map_err(|e| {
            XisfError::XmlParse(format!("Error unescaping attribute '{}': {}", key, e))
        })?;

        match key {
            "name" => name = Some(attr_value.into_owned()),
            "value" => value = Some(attr_value.into_owned()),
            _ => {}
        }
    }

    if let (Some(name), Some(value)) = (name, value) {
        metadata.fits_keywords.insert(name, value);
    }

    Ok(())
}

/// Parse attachment location "attachment:OFFSET:SIZE"
fn parse_attachment_location(location: &str) -> Result<(usize, usize), XisfError> {
    let stripped = location.strip_prefix("attachment:").ok_or_else(|| {
        XisfError::XmlParse(format!("Location is not an attachment: {}", location))
    })?;

    let parts: Vec<&str> = stripped.split(':').collect();
    if parts.len() != 2 {
        return Err(XisfError::XmlParse(format!(
            "Invalid attachment format (expected OFFSET:SIZE): {}",
            location
        )));
    }

    let offset: usize = parts[0]
        .parse()
        .map_err(|_| XisfError::XmlParse(format!("Invalid attachment offset in: {}", location)))?;
    let size: usize = parts[1]
        .parse()
        .map_err(|_| XisfError::XmlParse(format!("Invalid attachment size in: {}", location)))?;

    Ok((offset, size))
}

/// Parse property value based on type
fn parse_property_value(value: &str, prop_type: &str) -> XisfProperty {
    match prop_type {
        "Int8" => value
            .parse()
            .map(XisfProperty::Int8)
            .unwrap_or(XisfProperty::String(value.to_string())),
        "Int16" => value
            .parse()
            .map(XisfProperty::Int16)
            .unwrap_or(XisfProperty::String(value.to_string())),
        "Int32" => value
            .parse()
            .map(XisfProperty::Int32)
            .unwrap_or(XisfProperty::String(value.to_string())),
        "Int64" => value
            .parse()
            .map(XisfProperty::Int64)
            .unwrap_or(XisfProperty::String(value.to_string())),
        "UInt8" => value
            .parse()
            .map(XisfProperty::UInt8)
            .unwrap_or(XisfProperty::String(value.to_string())),
        "UInt16" => value
            .parse()
            .map(XisfProperty::UInt16)
            .unwrap_or(XisfProperty::String(value.to_string())),
        "UInt32" => value
            .parse()
            .map(XisfProperty::UInt32)
            .unwrap_or(XisfProperty::String(value.to_string())),
        "UInt64" => value
            .parse()
            .map(XisfProperty::UInt64)
            .unwrap_or(XisfProperty::String(value.to_string())),
        "Float32" => value
            .parse()
            .map(XisfProperty::Float32)
            .unwrap_or(XisfProperty::String(value.to_string())),
        "Float64" => value
            .parse()
            .map(XisfProperty::Float64)
            .unwrap_or(XisfProperty::String(value.to_string())),
        // Why: XISF spec accepts case-insensitive Boolean literals; PixInsight
        // emits "True", external tools may emit "TRUE". Treat anything else as
        // a non-boolean string so downstream code can detect malformed values.
        "Boolean" => parse_boolean_property(value),
        "TimePoint" => XisfProperty::TimePoint(value.to_string()),
        _ => XisfProperty::String(value.to_string()),
    }
}

/// Parse an XISF Boolean attribute value.
///
/// XISF accepts the literals `true`/`false` and `1`/`0`; the spec is
/// case-insensitive. Anything else (including empty strings) is preserved as
/// a `String` so callers can surface a malformed-property error rather than a
/// silent `false`.
fn parse_boolean_property(value: &str) -> XisfProperty {
    let folded = value.trim().to_ascii_lowercase();
    match folded.as_str() {
        "true" | "1" => XisfProperty::Boolean(true),
        "false" | "0" => XisfProperty::Boolean(false),
        _ => XisfProperty::String(value.to_string()),
    }
}

/// Compile-time Skotiq product version sourced from `version.yaml` via
/// `build.rs`. Centralised here so XISF (and any other writer) reports the
/// real version instead of a hardcoded literal.
const SKOTIQ_PRODUCT_VERSION: &str = env!("SKOTIQ_VERSION");

/// Write an XISF file
pub fn write_xisf(
    path: &Path,
    image: &ImageData,
    metadata: &XisfMetadata,
) -> Result<(), XisfError> {
    let file = File::create(path)?;
    let mut writer = BufWriter::new(file);

    let data_size = image.data.len();

    // XISF format:
    // - 8 bytes: magic signature "XISF0100"
    // - 4 bytes: header length (little-endian u32)
    // - 4 bytes: reserved (zeros)
    // - N bytes: XML header
    // - padding to align data
    // - image data

    let (xml_bytes, data_offset) = resolve_stable_xml_header(image, metadata, data_size)?;

    // Write magic signature
    writer.write_all(XISF_MAGIC)?;

    // Write header length (actual XML size, not padded - per XISF spec)
    writer.write_all(&(xml_bytes.len() as u32).to_le_bytes())?;

    // Write reserved (4 bytes)
    writer.write_all(&[0u8; 4])?;

    // Write XML header
    writer.write_all(&xml_bytes)?;

    // Pad to data offset
    let current_pos = 16 + xml_bytes.len();
    let padding = data_offset - current_pos;
    if padding > 0 {
        writer.write_all(&vec![0u8; padding])?;
    }

    // Write image data
    writer.write_all(&image.data)?;

    writer.flush()?;

    tracing::debug!(
        "XISF written: {}x{}, {} bytes data at offset {}",
        image.width,
        image.height,
        data_size,
        data_offset
    );

    Ok(())
}

fn resolve_stable_xml_header(
    image: &ImageData,
    metadata: &XisfMetadata,
    data_size: usize,
) -> Result<(Vec<u8>, usize), XisfError> {
    let mut candidate_offset = 16 + 4096;

    for _ in 0..MAX_OFFSET_RESOLUTION_PASSES {
        let xml_bytes = build_xisf_xml(image, metadata, candidate_offset, data_size)?;
        let resolved_offset = align_offset(16 + xml_bytes.len());
        if resolved_offset == candidate_offset {
            return Ok((xml_bytes, resolved_offset));
        }
        candidate_offset = resolved_offset;
    }

    let xml_bytes = build_xisf_xml(image, metadata, candidate_offset, data_size)?;
    let resolved_offset = align_offset(16 + xml_bytes.len());
    if resolved_offset == candidate_offset {
        return Ok((xml_bytes, resolved_offset));
    }

    Err(XisfError::InvalidFormat(format!(
        "Failed to resolve stable XISF attachment offset after {} passes",
        MAX_OFFSET_RESOLUTION_PASSES
    )))
}

fn align_offset(position: usize) -> usize {
    (position + (XISF_ALIGNMENT - 1)) & !(XISF_ALIGNMENT - 1)
}

/// Build XISF XML header with data location using quick-xml Writer
fn build_xisf_xml(
    image: &ImageData,
    metadata: &XisfMetadata,
    data_offset: usize,
    data_size: usize,
) -> Result<Vec<u8>, XisfError> {
    let sample_format = match image.pixel_type {
        PixelType::U8 => "UInt8",
        PixelType::U16 => "UInt16",
        PixelType::U32 => "UInt32",
        PixelType::F32 => "Float32",
        PixelType::F64 => "Float64",
    };

    let bounds = match image.pixel_type {
        PixelType::U8 => "0:255",
        PixelType::U16 => "0:65535",
        PixelType::U32 => "0:4294967295",
        PixelType::F32 | PixelType::F64 => "0:1",
    };

    let color_space = if image.channels == 1 { "Gray" } else { "RGB" };
    let geometry = if image.channels == 1 {
        format!("{}:{}", image.width, image.height)
    } else {
        format!("{}:{}:{}", image.width, image.height, image.channels)
    };

    let location = format!("attachment:{}:{}", data_offset, data_size);

    let mut xml_buf = Cursor::new(Vec::new());
    let mut xml_writer = Writer::new_with_indent(&mut xml_buf, b' ', 2);

    // XML declaration
    xml_writer.write_event(Event::Decl(BytesDecl::new("1.0", Some("UTF-8"), None)))?;

    // <xisf> root element
    let mut xisf_start = BytesStart::new("xisf");
    xisf_start.push_attribute(("version", "1.0"));
    xisf_start.push_attribute(("xmlns", "http://www.pixinsight.com/xisf"));
    xisf_start.push_attribute(("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance"));
    xisf_start.push_attribute((
        "xsi:schemaLocation",
        "http://www.pixinsight.com/xisf http://pixinsight.com/xisf/xisf-1.0.xsd",
    ));
    xml_writer.write_event(Event::Start(xisf_start))?;

    // <Image> element
    let mut image_start = BytesStart::new("Image");
    image_start.push_attribute(("geometry", geometry.as_str()));
    image_start.push_attribute(("sampleFormat", sample_format));
    image_start.push_attribute(("bounds", bounds));
    image_start.push_attribute(("colorSpace", color_space));
    image_start.push_attribute(("location", location.as_str()));
    xml_writer.write_event(Event::Start(image_start))?;

    // Creator property
    // Why: PixInsight relies on XISF:CreatorApplication for provenance/issue
    // reporting; emit the real product version sourced from version.yaml so
    // bug reports against a specific build don't all read "Skotiq 2.0".
    let creator_value = format!("Skotiq {}", SKOTIQ_PRODUCT_VERSION);
    let mut creator_prop = BytesStart::new("Property");
    creator_prop.push_attribute(("id", "XISF:CreatorApplication"));
    creator_prop.push_attribute(("type", "String"));
    creator_prop.push_attribute(("value", creator_value.as_str()));
    xml_writer.write_event(Event::Empty(creator_prop))?;

    // Creation time property
    let creation_time = chrono::Utc::now()
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string();
    let mut time_prop = BytesStart::new("Property");
    time_prop.push_attribute(("id", "XISF:CreationTime"));
    time_prop.push_attribute(("type", "TimePoint"));
    time_prop.push_attribute(("value", creation_time.as_str()));
    xml_writer.write_event(Event::Empty(time_prop))?;

    // User-provided properties
    for (id, prop) in &metadata.properties {
        let (type_str, value_str) = property_to_strings(prop);
        let mut prop_elem = BytesStart::new("Property");
        prop_elem.push_attribute(("id", id.as_str()));
        prop_elem.push_attribute(("type", type_str));
        prop_elem.push_attribute(("value", value_str.as_str()));
        xml_writer.write_event(Event::Empty(prop_elem))?;
    }

    // FITS keywords
    for (name, value) in &metadata.fits_keywords {
        let mut kw_elem = BytesStart::new("FITSKeyword");
        kw_elem.push_attribute(("name", name.as_str()));
        kw_elem.push_attribute(("value", value.as_str()));
        kw_elem.push_attribute(("comment", ""));
        xml_writer.write_event(Event::Empty(kw_elem))?;
    }

    // </Image>
    xml_writer.write_event(Event::End(BytesEnd::new("Image")))?;

    // </xisf>
    xml_writer.write_event(Event::End(BytesEnd::new("xisf")))?;

    let xml_bytes = xml_buf.into_inner();
    Ok(xml_bytes)
}

/// Convert property to type and value strings
fn property_to_strings(prop: &XisfProperty) -> (&'static str, String) {
    match prop {
        XisfProperty::String(s) => ("String", s.clone()),
        XisfProperty::Int8(v) => ("Int8", v.to_string()),
        XisfProperty::Int16(v) => ("Int16", v.to_string()),
        XisfProperty::Int32(v) => ("Int32", v.to_string()),
        XisfProperty::Int64(v) => ("Int64", v.to_string()),
        XisfProperty::UInt8(v) => ("UInt8", v.to_string()),
        XisfProperty::UInt16(v) => ("UInt16", v.to_string()),
        XisfProperty::UInt32(v) => ("UInt32", v.to_string()),
        XisfProperty::UInt64(v) => ("UInt64", v.to_string()),
        XisfProperty::Float32(v) => ("Float32", v.to_string()),
        XisfProperty::Float64(v) => ("Float64", v.to_string()),
        XisfProperty::Boolean(v) => ("Boolean", if *v { "true" } else { "false" }.to_string()),
        XisfProperty::TimePoint(s) => ("TimePoint", s.clone()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_offsets_until_fixed_point() {
        let resolved = resolve_stable_xml_header(
            &ImageData {
                width: 64,
                height: 64,
                channels: 1,
                pixel_type: PixelType::U16,
                data: vec![0; 64 * 64 * 2],
            },
            &XisfMetadata {
                properties: HashMap::from([(
                    "XISF:LongProperty".to_string(),
                    XisfProperty::String("x".repeat(10_000)),
                )]),
                fits_keywords: HashMap::new(),
            },
            64 * 64 * 2,
        )
        .expect("offset resolution should converge");

        let expected_offset = align_offset(16 + resolved.0.len());
        assert_eq!(resolved.1, expected_offset);
    }

    /// Boolean parsing must accept all spec-permitted literals
    /// case-insensitively. Matching only `"true"` and `"1"` exactly treats a
    /// PixInsight-emitted `"True"` as `false`, turning real flags into wrong
    /// defaults.
    #[test]
    fn parses_boolean_property_case_insensitive() {
        for truthy in &["true", "True", "TRUE", " true ", "1"] {
            match parse_property_value(truthy, "Boolean") {
                XisfProperty::Boolean(b) => assert!(b, "{:?} should parse as true", truthy),
                other => panic!("{:?} parsed as {:?}, expected Boolean(true)", truthy, other),
            }
        }
        for falsy in &["false", "False", "FALSE", "0"] {
            match parse_property_value(falsy, "Boolean") {
                XisfProperty::Boolean(b) => assert!(!b, "{:?} should parse as false", falsy),
                other => panic!("{:?} parsed as {:?}, expected Boolean(false)", falsy, other),
            }
        }
        // Empty / unrecognised values must NOT silently become `false`.
        for malformed in &["", "yes", "no", "maybe"] {
            match parse_property_value(malformed, "Boolean") {
                XisfProperty::String(s) => assert_eq!(s, *malformed),
                other => panic!(
                    "{:?} parsed as {:?}, expected fallback String preserving the raw value",
                    malformed, other
                ),
            }
        }
    }

    /// The XISF Creator property must reflect the real product version
    /// (sourced from `version.yaml` via `build.rs`), not a hardcoded "2.0".
    #[test]
    fn xisf_creator_contains_real_version() {
        let header = resolve_stable_xml_header(
            &ImageData {
                width: 4,
                height: 4,
                channels: 1,
                pixel_type: PixelType::U16,
                data: vec![0; 4 * 4 * 2],
            },
            &XisfMetadata::default(),
            4 * 4 * 2,
        )
        .expect("header generation should succeed");
        let xml = std::str::from_utf8(&header.0).expect("XISF header is valid UTF-8");

        // The compile-time version constant matches what is written into the file.
        let expected = format!("Skotiq {}", SKOTIQ_PRODUCT_VERSION);
        assert!(
            xml.contains(&expected),
            "XISF header should contain {:?}; got: {}",
            expected,
            xml
        );
        // The emitted version is the dynamic SKOTIQ_PRODUCT_VERSION, so
        // the "2.0" literal may only appear when the real version is 2.0 (in
        // which case the assertion above already matched it).
        if SKOTIQ_PRODUCT_VERSION != "2.0" {
            assert!(
                !xml.contains("\"Skotiq 2.0\""),
                "XISF header must carry the product version, not a \"Skotiq 2.0\" literal"
            );
        }
        // Sanity: version constant is non-empty and matches a SemVer-ish shape.
        // The const-is-empty allow is deliberate: we want this assertion to
        // fail loudly if a future build.rs regression injects an empty value.
        #[allow(clippy::const_is_empty)]
        {
            assert!(
                !SKOTIQ_PRODUCT_VERSION.is_empty(),
                "SKOTIQ_VERSION env var was empty at build time"
            );
        }
        assert!(
            SKOTIQ_PRODUCT_VERSION
                .chars()
                .next()
                .map(|c| c.is_ascii_digit())
                .unwrap_or(false),
            "SKOTIQ_VERSION should start with a digit; got {:?}",
            SKOTIQ_PRODUCT_VERSION
        );
    }
}
