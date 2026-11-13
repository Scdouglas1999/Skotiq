//! XISF data blocks (section 10): where a block is, reading its stored bytes
//! with every length checked against the file, verifying its checksum, and
//! undoing its compression.

use super::codec::{
    decode_base64, decode_hex, decompress_into, unshuffle, Checksum, Compression,
};
use super::header::MAX_HEADER_LEN;
use super::{ByteOrder, UnitSource, XisfError, XISB_SIGNATURE, XISF_SIGNATURE};
use rayon::prelude::*;
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

/// The largest block decoded for anything but pixel data: properties, ICC
/// profiles and the like. Keeps a hostile length from allocating the machine.
pub(crate) const MAX_AUXILIARY_BLOCK: u64 = 256 << 20;

#[derive(Debug, Clone, PartialEq)]
pub(crate) enum BlockLocation {
    Attachment { position: u64, size: u64 },
    /// Base64 or Base16 text in the element (`inline:`) or its `Data` child
    /// (`embedded`), already decoded.
    InHeader(Vec<u8>),
    /// A whole file, or, with an index identifier, one block of a data blocks
    /// file.
    External { file: PathBuf, index: Option<u64> },
}

#[derive(Debug, Clone, PartialEq)]
pub(crate) struct DataBlock {
    pub location: BlockLocation,
    pub compression: Option<Compression>,
    pub subblocks: Option<Vec<(u64, u64)>>,
    pub checksum: Option<Checksum>,
    pub byte_order: ByteOrder,
}

/// The parts of a `location` attribute, before an inline block's text is
/// known.
pub(crate) enum LocationSpec {
    Attachment { position: u64, size: u64 },
    Inline { hex: bool },
    Embedded,
    External { file: PathBuf, index: Option<u64> },
}

pub(crate) fn parse_location(text: &str, source: &UnitSource) -> Result<LocationSpec, XisfError> {
    let t = text.trim();
    let bad = || XisfError::Malformed(format!("block location \"{text}\""));
    if let Some(rest) = t.strip_prefix("attachment:") {
        let (position, size) = rest.split_once(':').ok_or_else(bad)?;
        return Ok(LocationSpec::Attachment {
            position: position.trim().parse().map_err(|_| bad())?,
            size: size.trim().parse().map_err(|_| bad())?,
        });
    }
    if let Some(encoding) = t.strip_prefix("inline:") {
        return Ok(LocationSpec::Inline {
            hex: parse_encoding(encoding)?,
        });
    }
    if t == "embedded" {
        return Ok(LocationSpec::Embedded);
    }
    let (scheme, rest) = if let Some(rest) = t.strip_prefix("url(") {
        ("url", rest)
    } else if let Some(rest) = t.strip_prefix("path(") {
        ("path", rest)
    } else {
        return Err(bad());
    };
    // The resource extends to the last closing parenthesis (section 10.3).
    let close = rest.rfind(')').ok_or_else(bad)?;
    let resource = &rest[..close];
    let index = match rest[close + 1..].strip_prefix(':') {
        Some(id) => Some(parse_index_id(id).ok_or_else(bad)?),
        None if rest[close + 1..].trim().is_empty() => None,
        None => return Err(bad()),
    };
    let file = match scheme {
        "url" => match resource.strip_prefix("file://") {
            Some(local) => PathBuf::from(local),
            None => {
                return Err(XisfError::Unsupported(format!(
                    "its data is on a remote server ({resource}), which Skotiq does not download"
                )))
            }
        },
        _ => match resource.strip_prefix("@header_dir/") {
            Some(relative) => match source {
                UnitSource::Distributed { header_dir } => header_dir.join(relative),
                UnitSource::Monolithic(path) => path
                    .parent()
                    .map(|dir| dir.join(relative))
                    .unwrap_or_else(|| PathBuf::from(relative)),
                UnitSource::InMemory(_) => {
                    return Err(XisfError::Unsupported(format!(
                        "its data is in a file beside a header that has no folder ({resource})"
                    )))
                }
            },
            None => PathBuf::from(resource),
        },
    };
    Ok(LocationSpec::External { file, index })
}

fn parse_encoding(text: &str) -> Result<bool, XisfError> {
    match text.trim() {
        "base64" => Ok(false),
        "hex" => Ok(true),
        other => Err(XisfError::Malformed(format!(
            "unknown data encoding \"{other}\""
        ))),
    }
}

pub(crate) fn decode_text_block(text: &str, encoding: &str) -> Result<Vec<u8>, XisfError> {
    if parse_encoding(encoding)? {
        decode_hex(text)
    } else {
        decode_base64(text)
    }
}

fn parse_index_id(text: &str) -> Option<u64> {
    let t = text.trim();
    match t.strip_prefix("0x").or_else(|| t.strip_prefix("0X")) {
        Some(hex) => u64::from_str_radix(hex, 16).ok(),
        None => t.parse().ok(),
    }
}

/// Read the XML header of a monolithic file, checking the signature, the
/// reserved field and that the declared length fits the file.
pub(crate) fn read_monolithic_header(path: &Path) -> Result<String, XisfError> {
    let mut file = File::open(path)?;
    let file_len = file.metadata()?.len();
    monolithic_header(&mut file, file_len)
}

/// [`read_monolithic_header`] of a unit of `file_len` bytes read from its
/// start.
pub(crate) fn monolithic_header(file: &mut impl Read, file_len: u64) -> Result<String, XisfError> {
    let mut preamble = [0u8; 16];
    file.read_exact(&mut preamble).map_err(|_| {
        XisfError::Malformed("the file is shorter than an XISF signature".to_string())
    })?;
    if &preamble[..8] != XISF_SIGNATURE {
        return Err(XisfError::Malformed(
            "the file does not start with the XISF signature".to_string(),
        ));
    }
    let length = u32::from_le_bytes(preamble[8..12].try_into().expect("four bytes")) as u64;
    if length < 65 || length > MAX_HEADER_LEN as u64 || 16 + length > file_len {
        return Err(XisfError::Malformed(format!(
            "the header length field says {length} bytes, but the file holds {}",
            file_len.saturating_sub(16)
        )));
    }
    let mut xml = vec![0u8; length as usize];
    file.read_exact(&mut xml)?;
    String::from_utf8(xml)
        .map_err(|_| XisfError::Malformed("the XISF header is not UTF-8 text".to_string()))
}

/// The stored bytes of a block: an open reader positioned at the first byte,
/// and the stored length.
pub(crate) struct StoredRange {
    pub reader: Box<dyn Read>,
    pub len: u64,
}

impl DataBlock {
    /// The decoded length the header declares for this block.
    pub fn uncompressed_len(&self, stored_len: u64) -> u64 {
        self.compression
            .map(|c| c.uncompressed_size)
            .unwrap_or(stored_len)
    }

    /// Open a file-backed block (attachment or external), checking that it
    /// lies inside its file.
    pub(crate) fn open(&self, source: &UnitSource) -> Result<Option<StoredRange>, XisfError> {
        let (path, position, size) = match &self.location {
            BlockLocation::InHeader(_) => return Ok(None),
            BlockLocation::Attachment { position, size } => match source {
                UnitSource::Monolithic(path) => (path.clone(), *position, Some(*size)),
                UnitSource::InMemory(bytes) => {
                    let unit_len = bytes.len() as u64;
                    if position.checked_add(*size).is_none_or(|end| end > unit_len) {
                        return Err(XisfError::Corrupt(format!(
                            "a data block claims bytes {position}..{} of a {unit_len}-byte unit",
                            position.saturating_add(*size)
                        )));
                    }
                    let mut reader = std::io::Cursor::new(bytes.clone());
                    reader.set_position(*position);
                    return Ok(Some(StoredRange {
                        reader: Box::new(reader),
                        len: *size,
                    }));
                }
                UnitSource::Distributed { .. } => {
                    return Err(XisfError::Malformed(
                        "an attached block in a distributed unit".to_string(),
                    ))
                }
            },
            BlockLocation::External { file, index } => {
                let (position, size) = match index {
                    Some(id) => locate_in_blocks_file(file, *id)?,
                    None => (0, None),
                };
                (file.clone(), position, size)
            }
        };
        let file = File::open(&path).map_err(|e| {
            XisfError::Io(std::io::Error::new(
                e.kind(),
                format!("cannot open the XISF data file {}: {e}", path.display()),
            ))
        })?;
        let file_len = file.metadata()?.len();
        let len = size.unwrap_or(file_len.saturating_sub(position));
        if position.checked_add(len).is_none_or(|end| end > file_len) {
            return Err(XisfError::Corrupt(format!(
                "a data block claims bytes {position}..{} of a {file_len}-byte file",
                position.saturating_add(len)
            )));
        }
        let mut reader = BufReader::with_capacity(1 << 20, file);
        reader.seek(SeekFrom::Start(position))?;
        Ok(Some(StoredRange {
            reader: Box::new(reader),
            len,
        }))
    }

    /// Read and decode the whole block: verify the checksum, decompress and
    /// undo byte shuffling, swap to little-endian. `expected` is the decoded
    /// length the header implies, when it implies one; `limit` caps it when
    /// it does not.
    pub(crate) fn read_all(
        &self,
        source: &UnitSource,
        what: &str,
        expected: Option<u64>,
        limit: u64,
        scalar_size: usize,
    ) -> Result<Vec<u8>, XisfError> {
        let stored = self.read_stored(source, what, limit)?;
        let mut data = self.decode(stored, what, expected, limit)?;
        if self.byte_order == ByteOrder::Big && scalar_size > 1 {
            for scalar in data.chunks_exact_mut(scalar_size) {
                scalar.reverse();
            }
        }
        Ok(data)
    }

    /// The stored bytes, checksum verified.
    pub(crate) fn read_stored(
        &self,
        source: &UnitSource,
        what: &str,
        limit: u64,
    ) -> Result<Vec<u8>, XisfError> {
        let stored = match &self.location {
            BlockLocation::InHeader(bytes) => bytes.clone(),
            _ => {
                let mut range = self.open(source)?.expect("file-backed block");
                if range.len > limit {
                    return Err(XisfError::Unsupported(format!(
                        "its {what} is stored in {} bytes, more than Skotiq reads",
                        range.len
                    )));
                }
                let mut bytes = try_alloc(range.len, what)?;
                bytes.resize(range.len as usize, 0);
                range.reader.read_exact(&mut bytes)?;
                bytes
            }
        };
        self.verify(&stored, what)?;
        Ok(stored)
    }

    pub(crate) fn verify(&self, stored: &[u8], what: &str) -> Result<(), XisfError> {
        if let Some(checksum) = &self.checksum {
            let mut hasher = checksum.algorithm.hasher();
            hasher.update(stored);
            if hasher.finish() != checksum.digest {
                return Err(XisfError::ChecksumMismatch {
                    what: what.to_string(),
                    algorithm: checksum.algorithm,
                });
            }
        }
        Ok(())
    }

    /// Decompress verified stored bytes and undo the shuffle. Uncompressed
    /// blocks pass through.
    pub(crate) fn decode(
        &self,
        stored: Vec<u8>,
        what: &str,
        expected: Option<u64>,
        limit: u64,
    ) -> Result<Vec<u8>, XisfError> {
        let declared = self.uncompressed_len(stored.len() as u64);
        if let Some(expected) = expected {
            if declared != expected {
                return Err(XisfError::Corrupt(format!(
                    "the {what} block holds {declared} bytes, not the {expected} its header describes"
                )));
            }
        } else if declared > limit {
            return Err(XisfError::Unsupported(format!(
                "its {what} would take {declared} bytes"
            )));
        }
        let Some(compression) = self.compression else {
            return Ok(stored);
        };
        let shuffled = decompress_block(&compression, self.subblocks.as_deref(), &stored, what)?;
        drop(stored);
        Ok(match compression.shuffle_item {
            Some(item) => unshuffle(&shuffled, item),
            None => shuffled,
        })
    }
}

/// Undo the codec of a whole block, subblock by subblock, in parallel. The
/// result is still byte-shuffled when the codec shuffles.
pub(crate) fn decompress_block(
    compression: &Compression,
    subblocks: Option<&[(u64, u64)]>,
    stored: &[u8],
    what: &str,
) -> Result<Vec<u8>, XisfError> {
    let single = [(stored.len() as u64, compression.uncompressed_size)];
    let subblocks = subblocks.unwrap_or(&single);
    let total_c = subblocks.iter().try_fold(0u64, |a, (c, _)| a.checked_add(*c));
    let total_u = subblocks.iter().try_fold(0u64, |a, (_, u)| a.checked_add(*u));
    if total_c != Some(stored.len() as u64) || total_u != Some(compression.uncompressed_size) {
        return Err(XisfError::Corrupt(format!(
            "the {what} block's subblocks do not add up to its stored and uncompressed lengths"
        )));
    }
    let mut out = try_alloc(compression.uncompressed_size, what)?;
    out.resize(compression.uncompressed_size as usize, 0);

    let mut jobs = Vec::with_capacity(subblocks.len());
    let (mut input, mut output) = (stored, out.as_mut_slice());
    for &(c, u) in subblocks {
        let (ci, rest_in) = input.split_at(c as usize);
        let (uo, rest_out) = std::mem::take(&mut output).split_at_mut(u as usize);
        jobs.push((ci, uo));
        input = rest_in;
        output = rest_out;
    }
    jobs.into_par_iter().try_for_each(|(ci, uo)| {
        if ci.len() == uo.len() {
            // An uncompressed subblock (section 10.6.1), unless an older
            // encoder compressed it to exactly its own length.
            if decompress_into(compression.codec, ci, uo).is_err() {
                uo.copy_from_slice(ci);
            }
            Ok(())
        } else {
            decompress_into(compression.codec, ci, uo)
        }
    })?;
    Ok(out)
}

/// A buffer of `len` bytes' capacity, or a plain error when the machine does
/// not have the memory.
pub(crate) fn try_alloc(len: u64, what: &str) -> Result<Vec<u8>, XisfError> {
    let n = usize::try_from(len).map_err(|_| {
        XisfError::Unsupported(format!("its {what} is larger than this computer can address"))
    })?;
    let mut v = Vec::new();
    v.try_reserve_exact(n).map_err(|_| {
        XisfError::Unsupported(format!(
            "its {what} needs {} MB of memory, which is not available",
            len >> 20
        ))
    })?;
    Ok(v)
}

/// Find a block in an XISF data blocks file by the unique identifier of its
/// index element. Returns its position and stored length.
fn locate_in_blocks_file(path: &Path, id: u64) -> Result<(u64, Option<u64>), XisfError> {
    const MAX_NODES: usize = 1 << 16;
    let mut file = File::open(path)?;
    let file_len = file.metadata()?.len();
    let mut head = [0u8; 16];
    file.read_exact(&mut head)?;
    if &head[..8] != XISB_SIGNATURE {
        return Err(XisfError::Malformed(format!(
            "{} is not an XISF data blocks file",
            path.display()
        )));
    }
    let mut node = 16u64;
    for _ in 0..MAX_NODES {
        if node.checked_add(16).is_none_or(|end| end > file_len) {
            break;
        }
        file.seek(SeekFrom::Start(node))?;
        let mut node_head = [0u8; 16];
        file.read_exact(&mut node_head)?;
        let count = u32::from_le_bytes(node_head[..4].try_into().expect("4")) as u64;
        let next = u64::from_le_bytes(node_head[8..].try_into().expect("8"));
        if count.saturating_mul(40) > file_len - node - 16 {
            return Err(XisfError::Corrupt(format!(
                "a block index node of {} runs past the end of the file",
                path.display()
            )));
        }
        let mut elements = vec![0u8; (count * 40) as usize];
        file.read_exact(&mut elements)?;
        for element in elements.as_chunks::<40>().0 {
            let field = |i: usize| u64::from_le_bytes(element[i * 8..i * 8 + 8].try_into().expect("8"));
            if field(0) == id && field(1) != 0 {
                return Ok((field(1), Some(field(2))));
            }
        }
        if next == 0 {
            break;
        }
        if next <= node {
            return Err(XisfError::Corrupt(format!(
                "the block index of {} loops back on itself",
                path.display()
            )));
        }
        node = next;
    }
    Err(XisfError::Corrupt(format!(
        "{} has no data block with identifier 0x{id:x}",
        path.display()
    )))
}
