//! The XISF header (sections 9.5 and 11): XML to [`XisfUnit`].
//!
//! The header is read into a small element tree first, which keeps the byte
//! span of every element, so elements this reader does not model can be
//! written back verbatim, and `Reference` elements can be resolved by `uid`
//! wherever they point.

use super::block::{
    decode_text_block, parse_location, BlockLocation, DataBlock, LocationSpec, MAX_AUXILIARY_BLOCK,
};
use super::codec::{parse_subblocks, Checksum, Compression};
use super::color::RgbWorkingSpace;
use super::property::{kind_of, PropertyKind, PropertyValue, XisfProperty};
use super::{
    ByteOrder, ColorFilterArray, ColorSpace, DisplayFunction, FitsKeyword, PixelStorage,
    Resolution, SampleFormat, UnitSource, XisfError, XisfImageHeader, XisfUnit,
};
use quick_xml::events::{BytesStart, Event};
use quick_xml::Reader;
use std::collections::HashMap;

/// The largest header this reader accepts. Real headers are kilobytes; a
/// header with large inline blocks can reach megabytes.
pub(crate) const MAX_HEADER_LEN: usize = 256 << 20;
/// Deeper nesting than any valid header has; stops a hostile header from
/// exhausting the stack.
const MAX_DEPTH: usize = 64;

#[derive(Debug)]
pub(crate) struct Node {
    pub name: String,
    pub attributes: Vec<(String, String)>,
    pub children: Vec<Node>,
    pub text: String,
    /// The element's byte span in the header.
    pub span: std::ops::Range<usize>,
}

impl Node {
    pub fn attr(&self, name: &str) -> Option<&str> {
        self.attributes
            .iter()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }

    fn local_name(&self) -> &str {
        self.name.rsplit(':').next().unwrap_or(&self.name)
    }
}

fn xml_error(e: impl std::fmt::Display, at: usize) -> XisfError {
    XisfError::Malformed(format!("the XML header is invalid near byte {at}: {e}"))
}

fn start_node(e: &BytesStart, at: usize) -> Result<Node, XisfError> {
    let name = String::from_utf8_lossy(e.name().as_ref()).into_owned();
    let mut attributes = Vec::new();
    for attr in e.attributes() {
        let attr = attr.map_err(|err| xml_error(err, at))?;
        let key = String::from_utf8_lossy(attr.key.as_ref()).into_owned();
        let value = attr
            .unescape_value()
            .map_err(|err| xml_error(err, at))?
            .into_owned();
        attributes.push((key, value));
    }
    Ok(Node {
        name,
        attributes,
        children: Vec::new(),
        text: String::new(),
        span: at..at,
    })
}

/// Parse the header into its top-level elements: the root `xisf` element,
/// and anything after it (an XML signature).
pub(crate) fn parse_tree(xml: &str) -> Result<Vec<Node>, XisfError> {
    let mut reader = Reader::from_str(xml);
    reader.trim_text(false);
    reader.expand_empty_elements(false);
    let mut stack: Vec<Node> = Vec::new();
    let mut top = Vec::new();
    loop {
        let at = reader.buffer_position();
        let event = reader.read_event().map_err(|e| xml_error(e, at))?;
        match event {
            Event::Start(e) => {
                if stack.len() >= MAX_DEPTH {
                    return Err(XisfError::Malformed(
                        "the XML header nests deeper than any XISF header".to_string(),
                    ));
                }
                stack.push(start_node(&e, at)?);
            }
            Event::Empty(e) => {
                let mut node = start_node(&e, at)?;
                node.span = at..reader.buffer_position();
                match stack.last_mut() {
                    Some(parent) => parent.children.push(node),
                    None => top.push(node),
                }
            }
            Event::End(_) => {
                let mut node = stack
                    .pop()
                    .ok_or_else(|| xml_error("a closing tag with no opening tag", at))?;
                node.span.end = reader.buffer_position();
                match stack.last_mut() {
                    Some(parent) => parent.children.push(node),
                    None => top.push(node),
                }
            }
            Event::Text(t) => {
                if let Some(node) = stack.last_mut() {
                    node.text
                        .push_str(&t.unescape().map_err(|e| xml_error(e, at))?);
                }
            }
            Event::CData(t) => {
                if let Some(node) = stack.last_mut() {
                    node.text
                        .push_str(&String::from_utf8_lossy(&t.into_inner()));
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if !stack.is_empty() {
        return Err(XisfError::Malformed(
            "the XML header ends inside an element".to_string(),
        ));
    }
    Ok(top)
}

pub(crate) fn parse_unit(xml: &str, source: UnitSource) -> Result<XisfUnit, XisfError> {
    let top = parse_tree(xml)?;
    let root = top
        .iter()
        .find(|n| n.local_name() == "xisf")
        .ok_or_else(|| XisfError::Malformed("the header has no xisf root element".to_string()))?;
    if let Some(version) = root.attr("version") {
        if version.trim() != "1.0" {
            return Err(XisfError::Unsupported(format!(
                "it is XISF version {version}; Skotiq reads version 1.0"
            )));
        }
    }

    let mut uids: HashMap<&str, &Node> = HashMap::new();
    collect_uids(root, &mut uids);
    let ctx = Context {
        source: &source,
        uids: &uids,
        xml,
    };

    let mut unit = XisfUnit {
        metadata: Vec::new(),
        properties: Vec::new(),
        images: Vec::new(),
        preserved: Vec::new(),
        source: source.clone(),
    };
    for child in &root.children {
        match child.local_name() {
            "Metadata" => {
                for p in child.children.iter().map(|n| ctx.resolve(n)) {
                    if p.local_name() == "Property" {
                        unit.metadata.push(ctx.property(p)?);
                    }
                }
            }
            "Image" => unit.images.push(ctx.image(child, false)?),
            "Property" => unit.properties.push(ctx.property(child)?),
            "Reference" => {
                let target = ctx.resolve(child);
                if target.local_name() == "Image" {
                    unit.images.push(ctx.image(target, false)?);
                }
            }
            _ => unit.preserved.push(ctx.raw(child)),
        }
    }
    Ok(unit)
}

fn collect_uids<'a>(node: &'a Node, uids: &mut HashMap<&'a str, &'a Node>) {
    for child in &node.children {
        if let Some(uid) = child.attr("uid") {
            uids.insert(uid, child);
        }
        collect_uids(child, uids);
    }
}

struct Context<'a> {
    source: &'a UnitSource,
    uids: &'a HashMap<&'a str, &'a Node>,
    xml: &'a str,
}

impl<'a> Context<'a> {
    /// The element a `Reference` points at, or the node itself. References
    /// to references are not allowed (section 11.13), so one step suffices.
    fn resolve(&self, node: &'a Node) -> &'a Node {
        if node.local_name() == "Reference" {
            if let Some(target) = node.attr("ref").and_then(|r| self.uids.get(r)) {
                return target;
            }
        }
        node
    }

    fn raw(&self, node: &Node) -> String {
        self.xml[node.span.clone()].to_string()
    }

    fn block(&self, node: &Node, required: bool) -> Result<Option<DataBlock>, XisfError> {
        let Some(location) = node.attr("location") else {
            if required {
                return Err(XisfError::Malformed(format!(
                    "a {} element has no data location",
                    node.local_name()
                )));
            }
            return Ok(None);
        };
        let byte_order = match node.attr("byteOrder").map(str::trim) {
            None | Some("little") => ByteOrder::Little,
            Some("big") => ByteOrder::Big,
            Some(other) => return Err(XisfError::Malformed(format!("byte order \"{other}\""))),
        };
        let mut compression_node = node;
        let location = match parse_location(location, self.source)? {
            LocationSpec::Attachment { position, size } => {
                BlockLocation::Attachment { position, size }
            }
            LocationSpec::Inline { hex } => BlockLocation::InHeader(decode_text_block(
                &node.text,
                if hex { "hex" } else { "base64" },
            )?),
            LocationSpec::Embedded => {
                let data = node
                    .children
                    .iter()
                    .find(|c| c.local_name() == "Data")
                    .ok_or_else(|| {
                        XisfError::Malformed("an embedded block has no Data element".to_string())
                    })?;
                compression_node = data;
                let encoding = data.attr("encoding").ok_or_else(|| {
                    XisfError::Malformed("an embedded Data element has no encoding".to_string())
                })?;
                BlockLocation::InHeader(decode_text_block(&data.text, encoding)?)
            }
            LocationSpec::External { file, index } => BlockLocation::External { file, index },
        };
        let compression = compression_node
            .attr("compression")
            .map(Compression::parse)
            .transpose()?;
        let subblocks = compression_node
            .attr("subblocks")
            .map(parse_subblocks)
            .transpose()?;
        let checksum = node
            .attr("checksum")
            .or_else(|| compression_node.attr("checksum"))
            .map(Checksum::parse)
            .transpose()?;
        Ok(Some(DataBlock {
            location,
            compression,
            subblocks,
            checksum,
            byte_order,
        }))
    }

    fn property(&self, node: &Node) -> Result<XisfProperty, XisfError> {
        let id = node
            .attr("id")
            .ok_or_else(|| XisfError::Malformed("a property has no id".to_string()))?
            .trim()
            .to_string();
        let type_name = node
            .attr("type")
            .ok_or_else(|| XisfError::Malformed(format!("property {id} has no type")))?
            .trim();
        let kind = kind_of(type_name).ok_or_else(|| {
            XisfError::Malformed(format!("property {id} has unknown type \"{type_name}\""))
        })?;
        let value = match kind {
            PropertyKind::Scalar => {
                let text = node
                    .attr("value")
                    .ok_or_else(|| XisfError::Malformed(format!("property {id} has no value")))?;
                PropertyValue::parse_scalar(type_name, text)?
            }
            PropertyKind::String => match self.block(node, false)? {
                Some(block) => {
                    let bytes = block.read_all(
                        self.source,
                        &format!("property {id}"),
                        None,
                        MAX_AUXILIARY_BLOCK,
                        1,
                    )?;
                    PropertyValue::from_block(&kind, (0, 0), bytes)?
                }
                None => PropertyValue::String(node.text.clone()),
            },
            PropertyKind::Vector(element) | PropertyKind::Matrix(element) => {
                let shape = match kind {
                    PropertyKind::Vector(_) => (dimension(node, "length", &id)?, 1),
                    _ => (
                        dimension(node, "rows", &id)?,
                        dimension(node, "columns", &id)?,
                    ),
                };
                let expected = PropertyValue::block_len(&kind, shape).ok_or_else(|| {
                    XisfError::Malformed(format!("property {id} has an impossible size"))
                })?;
                let bytes = match self.block(node, false)? {
                    Some(block) => block.read_all(
                        self.source,
                        &format!("property {id}"),
                        Some(expected),
                        MAX_AUXILIARY_BLOCK,
                        element.scalar_size(),
                    )?,
                    None if expected == 0 => Vec::new(),
                    None => {
                        return Err(XisfError::Malformed(format!(
                            "property {id} has no data block"
                        )))
                    }
                };
                PropertyValue::from_block(&kind, shape, bytes)?
            }
        };
        Ok(XisfProperty {
            id,
            value,
            format: node.attr("format").map(str::to_string),
            comment: node.attr("comment").map(str::to_string),
        })
    }

    fn image(&self, node: &Node, thumbnail: bool) -> Result<XisfImageHeader, XisfError> {
        let geometry = node
            .attr("geometry")
            .ok_or_else(|| XisfError::Malformed("an image has no geometry".to_string()))?;
        let mut items = geometry
            .split(':')
            .map(|g| g.trim().parse::<u64>().ok().filter(|&v| v > 0))
            .collect::<Option<Vec<u64>>>()
            .filter(|items| items.len() >= 2)
            .ok_or_else(|| XisfError::Malformed(format!("image geometry \"{geometry}\"")))?;
        let channels = items.pop().expect("at least two items");
        let sample_format =
            SampleFormat::parse(node.attr("sampleFormat").ok_or_else(|| {
                XisfError::Malformed("an image has no sample format".to_string())
            })?)?;
        let mut image = XisfImageHeader::new(items, channels, sample_format);
        if image.data_len().is_none() {
            return Err(XisfError::Malformed(format!(
                "image geometry \"{geometry}\" is too large to exist"
            )));
        }
        for (key, value) in &node.attributes {
            match key.as_str() {
                "geometry" | "sampleFormat" | "location" | "compression" | "subblocks"
                | "checksum" | "byteOrder" | "uid" => {}
                "bounds" => image.bounds = Some(parse_bounds(value)?),
                "colorSpace" => image.color_space = ColorSpace::parse(value)?,
                "pixelStorage" => {
                    image.pixel_storage = match value.trim() {
                        "Planar" => PixelStorage::Planar,
                        "Normal" => PixelStorage::Normal,
                        other => {
                            return Err(XisfError::Malformed(format!("pixel storage \"{other}\"")))
                        }
                    }
                }
                "imageType" => image.image_type = Some(value.trim().to_string()),
                "offset" => {
                    image.offset =
                        Some(value.trim().parse().map_err(|_| {
                            XisfError::Malformed(format!("image offset \"{value}\""))
                        })?)
                }
                "orientation" => image.orientation = Some(value.trim().to_string()),
                "id" => image.id = Some(value.clone()),
                "uuid" => image.uuid = Some(value.clone()),
                _ => image.extra_attributes.push((key.clone(), value.clone())),
            }
        }
        if image.sample_format.is_float() && image.bounds.is_none() {
            // Section 11.5.1 requires bounds on floating point images; the
            // normalized range is what every writer that omits them means.
            image.bounds = Some((0.0, 1.0));
        }
        image.block = self.block(node, true)?;

        for child in &node.children {
            let target = self.resolve(child);
            match target.local_name() {
                "Data" => {}
                "Property" => image.properties.push(self.property(target)?),
                "FITSKeyword" => image.fits_keywords.push(FitsKeyword {
                    name: target.attr("name").unwrap_or_default().trim().to_string(),
                    value: target.attr("value").unwrap_or_default().trim().to_string(),
                    comment: target.attr("comment").unwrap_or_default().to_string(),
                }),
                "ColorFilterArray" if !thumbnail => {
                    image.color_filter_array = Some(parse_cfa(target)?)
                }
                "Resolution" => image.resolution = Some(parse_resolution(target)?),
                "ICCProfile" => {
                    if let Some(block) = self.block(target, true)? {
                        image.icc_profile = Some(block.read_all(
                            self.source,
                            "ICC profile",
                            None,
                            MAX_AUXILIARY_BLOCK,
                            1,
                        )?);
                    }
                }
                "DisplayFunction" => image.display_function = Some(parse_display_function(target)?),
                "RGBWorkingSpace" => {
                    image.rgb_working_space = Some(RgbWorkingSpace::parse(target)?)
                }
                "Thumbnail" if !thumbnail => {
                    image.thumbnail = Some(Box::new(self.image(target, true)?))
                }
                _ => image.preserved_children.push(self.raw(child)),
            }
        }
        Ok(image)
    }
}

fn dimension(node: &Node, attr: &str, id: &str) -> Result<u64, XisfError> {
    node.attr(attr)
        .and_then(|v| v.trim().parse().ok())
        .ok_or_else(|| XisfError::Malformed(format!("property {id} has no valid {attr}")))
}

fn parse_floats<const N: usize>(text: &str, what: &str) -> Result<[f64; N], XisfError> {
    let values: Vec<f64> = text
        .split(':')
        .map(|v| v.trim().parse::<f64>())
        .collect::<Result<_, _>>()
        .map_err(|_| XisfError::Malformed(format!("{what} \"{text}\"")))?;
    values
        .try_into()
        .map_err(|_| XisfError::Malformed(format!("{what} \"{text}\"")))
}

fn parse_bounds(text: &str) -> Result<(f64, f64), XisfError> {
    let [lo, hi] = parse_floats::<2>(text, "image bounds")?;
    if !(lo.is_finite() && hi.is_finite() && lo < hi) {
        return Err(XisfError::Malformed(format!("image bounds \"{text}\"")));
    }
    Ok((lo, hi))
}

fn parse_cfa(node: &Node) -> Result<ColorFilterArray, XisfError> {
    let bad = || XisfError::Malformed("a ColorFilterArray element is incomplete".to_string());
    let pattern = node.attr("pattern").ok_or_else(bad)?.trim().to_string();
    let width: u32 = node
        .attr("width")
        .and_then(|v| v.trim().parse().ok())
        .ok_or_else(bad)?;
    let height: u32 = node
        .attr("height")
        .and_then(|v| v.trim().parse().ok())
        .ok_or_else(bad)?;
    if width == 0 || height == 0 || pattern.len() as u64 != width as u64 * height as u64 {
        return Err(bad());
    }
    Ok(ColorFilterArray {
        pattern,
        width,
        height,
        name: node.attr("name").map(str::to_string),
    })
}

fn parse_resolution(node: &Node) -> Result<Resolution, XisfError> {
    let read = |attr: &str| {
        node.attr(attr)
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|v| *v > 0.0)
            .ok_or_else(|| XisfError::Malformed(format!("a Resolution element's {attr}")))
    };
    Ok(Resolution {
        horizontal: read("horizontal")?,
        vertical: read("vertical")?,
        unit: node.attr("unit").unwrap_or("inch").trim().to_string(),
    })
}

fn parse_display_function(node: &Node) -> Result<DisplayFunction, XisfError> {
    let read = |attr: &str| {
        parse_floats::<4>(
            node.attr(attr).unwrap_or_default(),
            &format!("display function parameter {attr}"),
        )
    };
    Ok(DisplayFunction {
        m: read("m")?,
        s: read("s")?,
        h: read("h")?,
        l: read("l")?,
        r: read("r")?,
        name: node.attr("name").map(str::to_string),
    })
}
