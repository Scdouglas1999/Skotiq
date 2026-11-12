//! Writing monolithic XISF files: new files from images, and metadata
//! rewrites that keep every data block of an existing file byte for byte.

use super::block::{BlockLocation, DataBlock};
use super::codec::{
    compress, encode_base64, shuffle, Checksum, ChecksumAlgorithm, Compression,
    XisfCodec,
};
use super::property::{PropertyValue, XisfProperty};
use super::{
    ByteOrder, ColorSpace, PixelStorage, SampleFormat, UnitSource, XisfError, XisfImageHeader,
    XisfUnit, XISF_SIGNATURE,
};
use crate::ImageData;
use quick_xml::events::{BytesDecl, BytesEnd, BytesStart, BytesText, Event};
use quick_xml::Writer;
use rayon::prelude::*;
use std::fs::File;
use std::io::{BufWriter, Cursor, Read, Seek, SeekFrom, Write};
use std::path::Path;

/// Attached blocks start on multiples of this, as PixInsight writes them.
const BLOCK_ALIGNMENT: u64 = 4096;
/// Compressed blocks are cut into subblocks of this size so they compress
/// and decompress in parallel.
const SUBBLOCK: usize = 4 << 20;
const PRODUCT_VERSION: &str = env!("SKOTIQ_VERSION");

/// A compression codec choice for written pixel data.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct XisfCompression {
    pub codec: XisfCodec,
    /// Byte-shuffle samples before compressing; better for 16-bit and wider
    /// data.
    pub shuffle: bool,
    /// Abstract level 1..=100 (`XISF:CompressionLevel`); `None` is the
    /// codec's own default.
    pub level: Option<u8>,
}

impl XisfCompression {
    /// A choice by the name the `compression` attribute gives it (`zstd`,
    /// `lz4hc+sh`), at the codec's default level; `none` is no compression.
    pub fn from_name(name: &str) -> Result<Option<Self>, XisfError> {
        let name = name.trim();
        if name.eq_ignore_ascii_case("none") || name.is_empty() {
            return Ok(None);
        }
        let (codec, shuffle) = match name.strip_suffix("+sh") {
            Some(codec) => (codec, true),
            None => (name, false),
        };
        let codec = XisfCodec::from_name(codec)
            .ok_or_else(|| XisfError::UnsupportedCodec(name.to_string()))?;
        Ok(Some(Self {
            codec,
            shuffle,
            level: None,
        }))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct XisfWriteOptions {
    pub compression: Option<XisfCompression>,
    pub checksum: Option<ChecksumAlgorithm>,
    /// Write a small 8-bit preview that file browsers and the app's lists
    /// can show without decoding the image.
    pub thumbnail: bool,
}

impl Default for XisfWriteOptions {
    fn default() -> Self {
        Self {
            compression: None,
            checksum: None,
            thumbnail: true,
        }
    }
}

/// What goes into an attached block when the file is written.
enum Payload<'a> {
    /// Uncompressed pixels, de-interleaved into planar order as they are
    /// written.
    Planar(&'a ImageData),
    Bytes(Vec<u8>),
}

impl Payload<'_> {
    fn len(&self) -> u64 {
        match self {
            Payload::Planar(image) => image.data.len() as u64,
            Payload::Bytes(bytes) => bytes.len() as u64,
        }
    }
}

/// Write `images` (each a header and its pixels) as a new monolithic file.
/// The headers' sample format, geometry and color space are taken from the
/// pixels; everything else in them is written as given.
pub(crate) fn write_images(
    path: &Path,
    metadata: &[XisfProperty],
    images: &[(XisfImageHeader, &ImageData)],
    options: &XisfWriteOptions,
) -> Result<(), XisfError> {
    let mut headers = Vec::with_capacity(images.len());
    let mut payloads = Vec::new();
    for (header, pixels) in images {
        let mut header = header.clone();
        let expected = pixels.pixel_count() * pixels.bytes_per_pixel();
        if pixels.data.len() != expected || expected == 0 {
            return Err(XisfError::Malformed(format!(
                "the image to write holds {} bytes, not the {expected} its size needs",
                pixels.data.len()
            )));
        }
        describe_pixels(&mut header, pixels);
        let (block, payload) = encode_pixels(pixels, options)?;
        header.block = Some(block);
        payloads.push(payload);
        if options.thumbnail && header.thumbnail.is_none() {
            let thumb_pixels = super::thumbnail::make(pixels);
            let mut thumb = XisfImageHeader::new(Vec::new(), 0, SampleFormat::UInt8);
            describe_pixels(&mut thumb, &thumb_pixels);
            let mut bytes = planar_bytes(&thumb_pixels);
            let block = DataBlock {
                location: BlockLocation::Attachment {
                    position: 0,
                    size: bytes.len() as u64,
                },
                compression: None,
                subblocks: None,
                checksum: options.checksum.map(|a| checksum_of(a, &bytes)),
                byte_order: ByteOrder::Little,
            };
            thumb.block = Some(block);
            header.thumbnail = Some(Box::new(thumb));
            payloads.push(Payload::Bytes(std::mem::take(&mut bytes)));
        }
        headers.push(header);
    }

    let mut unit_metadata = vec![
        XisfProperty::new(
            "XISF:CreationTime",
            PropertyValue::TimePoint(now_timepoint()),
        ),
        XisfProperty::new(
            "XISF:CreatorApplication",
            PropertyValue::String(format!("Skotiq {PRODUCT_VERSION}")),
        ),
        XisfProperty::new("XISF:CreatorOS", PropertyValue::String(creator_os().to_string())),
        XisfProperty::new(
            "XISF:BlockAlignmentSize",
            PropertyValue::UInt16(BLOCK_ALIGNMENT as u16),
        ),
    ];
    if let Some(c) = options.compression {
        let name = if c.shuffle {
            format!("{}+sh", c.codec.name())
        } else {
            c.codec.name().to_string()
        };
        unit_metadata.push(XisfProperty::new(
            "XISF:CompressionCodecs",
            PropertyValue::String(name),
        ));
        unit_metadata.push(XisfProperty::new(
            "XISF:CompressionLevel",
            PropertyValue::Int32(c.level.unwrap_or_else(|| c.codec.default_level()) as i32),
        ));
    }
    if let Some(a) = options.checksum {
        unit_metadata.push(XisfProperty::new(
            "XISF:ChecksumAlgorithms",
            PropertyValue::String(a.name().to_string()),
        ));
    }
    for p in metadata {
        match unit_metadata.iter_mut().find(|m| m.id == p.id) {
            Some(existing) => *existing = p.clone(),
            None => unit_metadata.push(p.clone()),
        }
    }

    // Each block's position depends on the header's length, which depends on
    // the positions' digits: settle them.
    let mut start = BLOCK_ALIGNMENT;
    let xml = loop {
        let mut position = start;
        let mut blocks = Vec::new();
        for payload in &payloads {
            blocks.push((position, payload.len()));
            position = align(position + payload.len());
        }
        place_blocks(&mut headers, &blocks);
        let xml = emit_header(&unit_metadata, &[], &headers, &[], 0)?;
        let needed = align(16 + xml.len() as u64);
        if needed <= start {
            break xml;
        }
        start = needed;
    };

    let file = File::create(path)?;
    let mut out = BufWriter::with_capacity(1 << 20, file);
    out.write_all(XISF_SIGNATURE)?;
    out.write_all(&(xml.len() as u32).to_le_bytes())?;
    out.write_all(&[0u8; 4])?;
    out.write_all(&xml)?;
    let mut written = 16 + xml.len() as u64;
    pad_to(&mut out, &mut written, start)?;
    for (i, payload) in payloads.iter().enumerate() {
        if i > 0 {
            let next = align(written);
            pad_to(&mut out, &mut written, next)?;
        }
        match payload {
            Payload::Planar(image) => write_planar(&mut out, image)?,
            Payload::Bytes(bytes) => out.write_all(bytes)?,
        }
        written += payload.len();
    }
    out.flush()?;
    Ok(())
}

fn pad_to(out: &mut impl Write, written: &mut u64, target: u64) -> Result<(), XisfError> {
    const ZEROS: [u8; BLOCK_ALIGNMENT as usize] = [0; BLOCK_ALIGNMENT as usize];
    while *written < target {
        let n = (target - *written).min(ZEROS.len() as u64) as usize;
        out.write_all(&ZEROS[..n])?;
        *written += n as u64;
    }
    Ok(())
}

fn align(position: u64) -> u64 {
    position.div_ceil(BLOCK_ALIGNMENT) * BLOCK_ALIGNMENT
}

/// Give each attached block of the headers its position, in the order the
/// payloads were made: an image, then its thumbnail.
fn place_blocks(headers: &mut [XisfImageHeader], blocks: &[(u64, u64)]) {
    let mut next = blocks.iter();
    for header in headers {
        for block in std::iter::once(header.block.as_mut())
            .chain(std::iter::once(header.thumbnail.as_mut().and_then(|t| t.block.as_mut())))
            .flatten()
        {
            if let BlockLocation::Attachment { .. } = block.location {
                let &(position, size) = next.next().expect("a payload per attached block");
                block.location = BlockLocation::Attachment { position, size };
            }
        }
    }
}

fn describe_pixels(header: &mut XisfImageHeader, pixels: &ImageData) {
    header.dimensions = vec![pixels.width as u64, pixels.height as u64];
    header.channels = pixels.channels as u64;
    header.sample_format = SampleFormat::of(pixels.pixel_type);
    header.pixel_storage = PixelStorage::Planar;
    header.color_space = if pixels.channels >= 3 {
        ColorSpace::Rgb
    } else {
        ColorSpace::Gray
    };
    header.bounds = header
        .sample_format
        .is_float()
        .then(|| float_bounds(pixels));
}

/// `0:1` for normalized data, otherwise a range that holds every sample, so
/// PixInsight neither clips nor rescales what the app stores.
fn float_bounds(pixels: &ImageData) -> (f64, f64) {
    let (lo, hi) = pixels
        .data
        .par_chunks(pixels.pixel_type.byte_size() * 4096)
        .map(|chunk| {
            chunk
                .chunks_exact(pixels.pixel_type.byte_size())
                .map(|b| crate::samples::sample_from_le(b, pixels.pixel_type))
                .filter(|v| v.is_finite())
                .fold((f64::INFINITY, f64::NEG_INFINITY), |(lo, hi), v| {
                    (lo.min(v), hi.max(v))
                })
        })
        .reduce(
            || (f64::INFINITY, f64::NEG_INFINITY),
            |a, b| (a.0.min(b.0), a.1.max(b.1)),
        );
    if !lo.is_finite() {
        return (0.0, 1.0);
    }
    (lo.min(0.0), hi.max(1.0))
}

/// The attached block for an image's pixels, and what to write into it.
fn encode_pixels<'a>(
    pixels: &'a ImageData,
    options: &XisfWriteOptions,
) -> Result<(DataBlock, Payload<'a>), XisfError> {
    let size = pixels.data.len() as u64;
    let sample = pixels.pixel_type.byte_size();
    if let Some(choice) = options.compression {
        let shuffle_item = (choice.shuffle && sample > 1).then_some(sample);
        let stored = match shuffle_item {
            Some(item) => shuffle(&planar_bytes(pixels), item),
            None => planar_bytes(pixels),
        };
        let level = choice.level.unwrap_or_else(|| choice.codec.default_level());
        let pieces: Vec<Vec<u8>> = stored
            .par_chunks(SUBBLOCK.min(choice.codec.max_subblock()))
            .map(|piece| {
                let packed = compress(choice.codec, level, piece)?;
                // A piece that does not shrink is stored as it is
                // (section 10.6.1).
                Ok(if packed.len() < piece.len() {
                    packed
                } else {
                    piece.to_vec()
                })
            })
            .collect::<Result<_, XisfError>>()?;
        let reduced = pieces.iter().map(Vec::len).sum::<usize>() < stored.len();
        if reduced {
            let subblocks: Vec<(u64, u64)> = pieces
                .iter()
                .zip(stored.chunks(SUBBLOCK.min(choice.codec.max_subblock())))
                .map(|(c, u)| (c.len() as u64, u.len() as u64))
                .collect();
            drop(stored);
            let bytes = pieces.concat();
            let block = DataBlock {
                location: BlockLocation::Attachment {
                    position: 0,
                    size: bytes.len() as u64,
                },
                compression: Some(Compression {
                    codec: choice.codec,
                    shuffle_item,
                    uncompressed_size: size,
                }),
                subblocks: (subblocks.len() > 1).then_some(subblocks),
                checksum: options.checksum.map(|a| checksum_of(a, &bytes)),
                byte_order: ByteOrder::Little,
            };
            return Ok((block, Payload::Bytes(bytes)));
        }
    }
    let checksum = options.checksum.map(|a| {
        let mut hasher = a.hasher();
        for_each_planar_chunk(pixels, |chunk| hasher.update(chunk));
        Checksum {
            algorithm: a,
            digest: hasher.finish(),
        }
    });
    Ok((
        DataBlock {
            location: BlockLocation::Attachment { position: 0, size },
            compression: None,
            subblocks: None,
            checksum,
            byte_order: ByteOrder::Little,
        },
        Payload::Planar(pixels),
    ))
}

fn checksum_of(algorithm: ChecksumAlgorithm, bytes: &[u8]) -> Checksum {
    let mut hasher = algorithm.hasher();
    hasher.update(bytes);
    Checksum {
        algorithm,
        digest: hasher.finish(),
    }
}

/// Every sample of channel 0, then of channel 1, and so on.
fn planar_bytes(pixels: &ImageData) -> Vec<u8> {
    if pixels.channels <= 1 {
        return pixels.data.clone();
    }
    let mut out = Vec::with_capacity(pixels.data.len());
    for_each_planar_chunk(pixels, |chunk| out.extend_from_slice(chunk));
    out
}

fn write_planar(out: &mut impl Write, pixels: &ImageData) -> Result<(), XisfError> {
    let mut result = Ok(());
    for_each_planar_chunk(pixels, |chunk| {
        if result.is_ok() {
            result = out.write_all(chunk);
        }
    });
    Ok(result?)
}

/// Hand the planar sample sequence to `sink` in chunks of a few megabytes,
/// without materializing it.
fn for_each_planar_chunk(pixels: &ImageData, mut sink: impl FnMut(&[u8])) {
    let channels = pixels.channels.max(1) as usize;
    if channels == 1 {
        for chunk in pixels.data.chunks(8 << 20) {
            sink(chunk);
        }
        return;
    }
    let size = pixels.pixel_type.byte_size();
    let stride = size * channels;
    let pixels_per_chunk = (8 << 20) / size;
    let mut buffer = Vec::with_capacity(pixels_per_chunk * size);
    for channel in 0..channels {
        for rows in pixels.data.chunks(stride * pixels_per_chunk) {
            buffer.clear();
            buffer.par_extend(
                rows.par_chunks_exact(stride)
                    .flat_map_iter(|pixel| pixel[channel * size..(channel + 1) * size].iter().copied()),
            );
            sink(&buffer);
        }
    }
}

fn now_timepoint() -> String {
    chrono::Utc::now()
        .format("%Y-%m-%dT%H:%M:%S%.3fZ")
        .to_string()
}

fn creator_os() -> &'static str {
    match std::env::consts::OS {
        "linux" | "android" => "Linux",
        "macos" | "ios" => "macOS",
        "windows" => "Windows",
        "freebsd" => "FreeBSD",
        other => other,
    }
}

/// Rewrite the header of a monolithic file from `unit` (as read from that
/// file, then edited), keeping every attached data block exactly as stored.
/// The blocks move by whole alignment units when the header grows; elements
/// this reader does not model are written back verbatim with their
/// attachment positions moved the same way.
pub(crate) fn rewrite_unit_metadata(path: &Path, unit: &XisfUnit) -> Result<(), XisfError> {
    let UnitSource::Monolithic(source_path) = &unit.source else {
        return Err(XisfError::Unsupported(
            "its metadata is in a separate header file, which Skotiq does not rewrite".to_string(),
        ));
    };
    let mut source = File::open(source_path)?;
    let file_len = source.metadata()?.len();
    let mut preamble = [0u8; 16];
    source.read_exact(&mut preamble)?;
    let old_header_end =
        16 + u32::from_le_bytes(preamble[8..12].try_into().expect("four bytes")) as u64;
    let tail_start = attachment_positions(unit)
        .min()
        .unwrap_or(file_len)
        .max(old_header_end)
        .min(file_len);

    let mut metadata = unit.metadata.clone();
    let original = metadata
        .iter()
        .find(|p| p.id == "XISF:OriginalCreationTime")
        .or_else(|| metadata.iter().find(|p| p.id == "XISF:CreationTime"))
        .map(|p| p.value.clone());
    metadata.retain(|p| {
        !matches!(
            p.id.as_str(),
            "XISF:CreationTime" | "XISF:CreatorApplication" | "XISF:OriginalCreationTime"
        )
    });
    let mut fresh = vec![
        XisfProperty::new("XISF:CreationTime", PropertyValue::TimePoint(now_timepoint())),
        XisfProperty::new(
            "XISF:CreatorApplication",
            PropertyValue::String(format!("Skotiq {PRODUCT_VERSION}")),
        ),
    ];
    if let Some(original) = original {
        fresh.push(XisfProperty::new("XISF:OriginalCreationTime", original));
    }
    fresh.extend(metadata);

    let mut new_start = align(old_header_end).max(BLOCK_ALIGNMENT);
    let xml = loop {
        let shift = new_start as i64 - tail_start as i64;
        let xml = emit_header(&fresh, &unit.properties, &unit.images, &unit.preserved, shift)?;
        let needed = align(16 + xml.len() as u64);
        if needed <= new_start {
            break xml;
        }
        new_start = needed;
    };

    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "image.xisf".to_string());
    let staged = path.with_file_name(format!(".{name}.rewrite-tmp"));
    let result = (|| -> Result<(), XisfError> {
        let mut out = BufWriter::with_capacity(1 << 20, File::create(&staged)?);
        out.write_all(XISF_SIGNATURE)?;
        out.write_all(&(xml.len() as u32).to_le_bytes())?;
        out.write_all(&[0u8; 4])?;
        out.write_all(&xml)?;
        let mut written = 16 + xml.len() as u64;
        pad_to(&mut out, &mut written, new_start)?;
        source.seek(SeekFrom::Start(tail_start))?;
        std::io::copy(&mut source.take(file_len - tail_start), &mut out)?;
        out.flush()?;
        Ok(())
    })();
    if let Err(e) = result {
        let _ = std::fs::remove_file(&staged);
        return Err(e);
    }
    std::fs::rename(&staged, path).map_err(|e| {
        let _ = std::fs::remove_file(&staged);
        XisfError::Io(e)
    })
}

/// The first byte of every attached block the unit refers to, in modeled
/// elements and in the verbatim ones.
pub(super) fn attachment_positions(unit: &XisfUnit) -> impl Iterator<Item = u64> + '_ {
    let modeled = unit.images.iter().flat_map(|image| {
        [
            image.block.as_ref(),
            image.thumbnail.as_ref().and_then(|t| t.block.as_ref()),
        ]
        .into_iter()
        .flatten()
        .filter_map(|block| match block.location {
            BlockLocation::Attachment { position, .. } => Some(position),
            _ => None,
        })
    });
    let verbatim = unit
        .preserved
        .iter()
        .chain(unit.images.iter().flat_map(|i| i.preserved_children.iter()))
        .flat_map(|raw| attachment_spans(raw).into_iter().map(|(_, position)| position));
    modeled.chain(verbatim)
}

/// Each `attachment:<position>` in verbatim XML: the byte range of the
/// position digits and their value.
pub(super) fn attachment_spans(raw: &str) -> Vec<(std::ops::Range<usize>, u64)> {
    const KEY: &str = "attachment:";
    let mut spans = Vec::new();
    let mut from = 0;
    while let Some(found) = raw[from..].find(KEY) {
        let start = from + found + KEY.len();
        let end = start
            + raw[start..]
                .bytes()
                .take_while(u8::is_ascii_digit)
                .count();
        if let Ok(value) = raw[start..end].parse() {
            spans.push((start..end, value));
        }
        from = end.max(start);
    }
    spans
}

fn shift_verbatim(raw: &str, shift: i64) -> String {
    let mut out = String::with_capacity(raw.len() + 16);
    let mut last = 0;
    for (range, value) in attachment_spans(raw) {
        out.push_str(&raw[last..range.start]);
        out.push_str(&((value as i64 + shift) as u64).to_string());
        last = range.end;
    }
    out.push_str(&raw[last..]);
    out
}

type XmlWriter = Writer<Cursor<Vec<u8>>>;

fn emit_header(
    metadata: &[XisfProperty],
    root_properties: &[XisfProperty],
    images: &[XisfImageHeader],
    preserved: &[String],
    shift: i64,
) -> Result<Vec<u8>, XisfError> {
    let mut w = Writer::new_with_indent(Cursor::new(Vec::new()), b' ', 3);
    w.write_event(Event::Decl(BytesDecl::new("1.0", Some("UTF-8"), None)))?;
    w.get_mut().write_all(
        format!(
            "\n<!--\nExtensible Image Serialization Format - XISF version 1.0\nCreated with Skotiq {PRODUCT_VERSION} - https://skotiq.com/\n-->"
        )
        .as_bytes(),
    )?;
    let mut root = BytesStart::new("xisf");
    root.push_attribute(("version", "1.0"));
    root.push_attribute(("xmlns", "http://www.pixinsight.com/xisf"));
    root.push_attribute(("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance"));
    root.push_attribute((
        "xsi:schemaLocation",
        "http://www.pixinsight.com/xisf http://pixinsight.com/xisf/xisf-1.0.xsd",
    ));
    w.write_event(Event::Start(root))?;
    for image in images {
        emit_image(&mut w, image, "Image", shift)?;
    }
    for property in root_properties {
        emit_property(&mut w, property)?;
    }
    w.write_event(Event::Start(BytesStart::new("Metadata")))?;
    for property in metadata {
        emit_property(&mut w, property)?;
    }
    w.write_event(Event::End(BytesEnd::new("Metadata")))?;
    for raw in preserved {
        emit_verbatim(&mut w, raw, shift)?;
    }
    w.write_event(Event::End(BytesEnd::new("xisf")))?;
    Ok(w.into_inner().into_inner())
}

fn emit_verbatim(w: &mut XmlWriter, raw: &str, shift: i64) -> Result<(), XisfError> {
    w.get_mut().write_all(b"\n")?;
    w.get_mut().write_all(shift_verbatim(raw, shift).as_bytes())?;
    Ok(())
}

fn block_attributes(e: &mut BytesStart, block: &DataBlock, shift: i64) {
    match &block.location {
        BlockLocation::Attachment { position, size } => {
            let position = (*position as i64 + shift) as u64;
            e.push_attribute(("location", format!("attachment:{position}:{size}").as_str()));
        }
        BlockLocation::External { file, index } => {
            let mut text = format!("path({})", file.to_string_lossy().replace('\\', "/"));
            if let Some(id) = index {
                text.push_str(&format!(":0x{id:x}"));
            }
            e.push_attribute(("location", text.as_str()));
        }
        BlockLocation::InHeader(_) => {}
    }
    if block.byte_order == ByteOrder::Big {
        e.push_attribute(("byteOrder", "big"));
    }
    if let Some(c) = &block.checksum {
        e.push_attribute(("checksum", c.attribute().as_str()));
    }
    if matches!(block.location, BlockLocation::InHeader(_)) {
        // An embedded block's compression goes on its Data element.
        return;
    }
    compression_attributes(e, block);
}

fn compression_attributes(e: &mut BytesStart, block: &DataBlock) {
    if let Some(c) = &block.compression {
        e.push_attribute(("compression", c.attribute().as_str()));
    }
    if let Some(subblocks) = &block.subblocks {
        let text: Vec<String> = subblocks.iter().map(|(c, u)| format!("{c},{u}")).collect();
        e.push_attribute(("subblocks", text.join(":").as_str()));
    }
}

fn emit_image(
    w: &mut XmlWriter,
    image: &XisfImageHeader,
    tag: &str,
    shift: i64,
) -> Result<(), XisfError> {
    let mut e = BytesStart::new(tag);
    let mut geometry: Vec<String> = image.dimensions.iter().map(u64::to_string).collect();
    geometry.push(image.channels.to_string());
    e.push_attribute(("geometry", geometry.join(":").as_str()));
    e.push_attribute(("sampleFormat", image.sample_format.name()));
    if let Some((lo, hi)) = image.bounds {
        e.push_attribute(("bounds", format!("{lo}:{hi}").as_str()));
    }
    e.push_attribute(("colorSpace", image.color_space.name()));
    e.push_attribute((
        "pixelStorage",
        match image.pixel_storage {
            PixelStorage::Planar => "Planar",
            PixelStorage::Normal => "Normal",
        },
    ));
    for (key, value) in [
        ("imageType", image.image_type.clone()),
        ("offset", image.offset.map(|o| o.to_string())),
        ("orientation", image.orientation.clone()),
        ("id", image.id.clone()),
        ("uuid", image.uuid.clone()),
    ] {
        if let Some(value) = value {
            e.push_attribute((key, value.as_str()));
        }
    }
    for (key, value) in &image.extra_attributes {
        e.push_attribute((key.as_str(), value.as_str()));
    }
    let embedded = match &image.block {
        Some(block) => {
            block_attributes(&mut e, block, shift);
            match &block.location {
                BlockLocation::InHeader(bytes) => {
                    e.push_attribute(("location", "embedded"));
                    Some((bytes, block))
                }
                _ => None,
            }
        }
        None => None,
    };
    w.write_event(Event::Start(e))?;
    if let Some((bytes, block)) = embedded {
        let mut data = BytesStart::new("Data");
        data.push_attribute(("encoding", "base64"));
        compression_attributes(&mut data, block);
        w.write_event(Event::Start(data))?;
        w.write_event(Event::Text(BytesText::new(&encode_base64(bytes))))?;
        w.write_event(Event::End(BytesEnd::new("Data")))?;
    }
    for property in &image.properties {
        emit_property(w, property)?;
    }
    for keyword in &image.fits_keywords {
        let mut e = BytesStart::new("FITSKeyword");
        e.push_attribute(("name", keyword.name.as_str()));
        e.push_attribute(("value", keyword.value.as_str()));
        e.push_attribute(("comment", keyword.comment.as_str()));
        w.write_event(Event::Empty(e))?;
    }
    if let Some(cfa) = &image.color_filter_array {
        let mut e = BytesStart::new("ColorFilterArray");
        e.push_attribute(("pattern", cfa.pattern.as_str()));
        e.push_attribute(("width", cfa.width.to_string().as_str()));
        e.push_attribute(("height", cfa.height.to_string().as_str()));
        if let Some(name) = &cfa.name {
            e.push_attribute(("name", name.as_str()));
        }
        w.write_event(Event::Empty(e))?;
    }
    if let Some(r) = &image.resolution {
        let mut e = BytesStart::new("Resolution");
        e.push_attribute(("horizontal", r.horizontal.to_string().as_str()));
        e.push_attribute(("vertical", r.vertical.to_string().as_str()));
        e.push_attribute(("unit", r.unit.as_str()));
        w.write_event(Event::Empty(e))?;
    }
    if let Some(icc) = &image.icc_profile {
        let mut e = BytesStart::new("ICCProfile");
        e.push_attribute(("location", "inline:base64"));
        w.write_event(Event::Start(e))?;
        w.write_event(Event::Text(BytesText::new(&encode_base64(icc))))?;
        w.write_event(Event::End(BytesEnd::new("ICCProfile")))?;
    }
    if let Some(df) = &image.display_function {
        let mut e = BytesStart::new("DisplayFunction");
        let join = |v: &[f64; 4]| format!("{}:{}:{}:{}", v[0], v[1], v[2], v[3]);
        for (key, value) in [("m", &df.m), ("s", &df.s), ("h", &df.h), ("l", &df.l), ("r", &df.r)] {
            e.push_attribute((key, join(value).as_str()));
        }
        if let Some(name) = &df.name {
            e.push_attribute(("name", name.as_str()));
        }
        w.write_event(Event::Empty(e))?;
    }
    if let Some(ws) = &image.rgb_working_space {
        let mut e = BytesStart::new("RGBWorkingSpace");
        for (key, value) in ws.attributes() {
            e.push_attribute((key, value.as_str()));
        }
        w.write_event(Event::Empty(e))?;
    }
    if let Some(thumbnail) = &image.thumbnail {
        emit_image(w, thumbnail, "Thumbnail", shift)?;
    }
    for raw in &image.preserved_children {
        emit_verbatim(w, raw, shift)?;
    }
    w.write_event(Event::End(BytesEnd::new(tag)))?;
    Ok(())
}

fn emit_property(w: &mut XmlWriter, property: &XisfProperty) -> Result<(), XisfError> {
    let mut e = BytesStart::new("Property");
    e.push_attribute(("id", property.id.as_str()));
    e.push_attribute(("type", property.value.type_name().as_str()));
    if let Some(format) = &property.format {
        e.push_attribute(("format", format.as_str()));
    }
    if let Some(comment) = &property.comment {
        e.push_attribute(("comment", comment.as_str()));
    }
    let body = match &property.value {
        PropertyValue::String(text) => Some(text.clone()),
        PropertyValue::Vector { data, .. } => {
            e.push_attribute((
                "length",
                (data.len() / element_size(&property.value)).to_string().as_str(),
            ));
            e.push_attribute(("location", "inline:base64"));
            Some(encode_base64(data))
        }
        PropertyValue::Matrix {
            rows,
            columns,
            data,
            ..
        } => {
            e.push_attribute(("rows", rows.to_string().as_str()));
            e.push_attribute(("columns", columns.to_string().as_str()));
            e.push_attribute(("location", "inline:base64"));
            Some(encode_base64(data))
        }
        scalar => {
            e.push_attribute((
                "value",
                scalar.scalar_text().unwrap_or_default().as_str(),
            ));
            None
        }
    };
    match body {
        Some(text) => {
            w.write_event(Event::Start(e))?;
            if !text.is_empty() {
                w.write_event(Event::Text(BytesText::new(&text)))?;
            }
            w.write_event(Event::End(BytesEnd::new("Property")))?;
        }
        None => w.write_event(Event::Empty(e))?,
    }
    Ok(())
}

fn element_size(value: &PropertyValue) -> usize {
    match value {
        PropertyValue::Vector { element, .. } | PropertyValue::Matrix { element, .. } => {
            element.size()
        }
        _ => 1,
    }
}

impl From<quick_xml::Error> for XisfError {
    fn from(e: quick_xml::Error) -> Self {
        XisfError::Malformed(format!("XML: {e}"))
    }
}
