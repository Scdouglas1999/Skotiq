//! Data block transforms: compression codecs, byte shuffling, checksums and
//! the text encodings of inline blocks (XISF 1.0 sections 10.3, 10.5, 10.6).

use super::XisfError;
use sha1::Digest;
use std::io::Read;

/// The four standard compression codecs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum XisfCodec {
    Zlib,
    Lz4,
    Lz4Hc,
    Zstd,
}

impl XisfCodec {
    pub const ALL: [XisfCodec; 4] = [
        XisfCodec::Zlib,
        XisfCodec::Lz4,
        XisfCodec::Lz4Hc,
        XisfCodec::Zstd,
    ];

    /// The codec name of the `compression` attribute, without `+sh`.
    pub fn name(self) -> &'static str {
        match self {
            XisfCodec::Zlib => "zlib",
            XisfCodec::Lz4 => "lz4",
            XisfCodec::Lz4Hc => "lz4hc",
            XisfCodec::Zstd => "zstd",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|codec| codec.name().eq_ignore_ascii_case(name))
    }

    /// The largest input one call of the codec takes; a longer block is cut
    /// into subblocks of at most this many bytes.
    pub(crate) fn max_subblock(self) -> usize {
        match self {
            // LZ4_MAX_INPUT_SIZE is 0x7E000000; stay well under it.
            XisfCodec::Lz4 | XisfCodec::Lz4Hc => 1 << 30,
            XisfCodec::Zlib | XisfCodec::Zstd => 3 << 30,
        }
    }

    /// The codec's own level for an abstract level of 1..=100
    /// (`XISF:CompressionLevel`).
    fn native_level(self, level: u8) -> i32 {
        let t = (f64::from(level.clamp(1, 100)) - 1.0) / 99.0;
        match self {
            XisfCodec::Zlib => (1.0 + t * 8.0).round() as i32,
            XisfCodec::Lz4 => 0,
            XisfCodec::Lz4Hc => (1.0 + t * 11.0).round() as i32,
            XisfCodec::Zstd => (1.0 + t * 21.0).round() as i32,
        }
    }

    /// The abstract level used when the caller names none: each codec's own
    /// default (zlib 6, LZ4_HC 9, Zstandard 3).
    pub fn default_level(self) -> u8 {
        match self {
            XisfCodec::Zlib => 63,
            XisfCodec::Lz4 => 1,
            XisfCodec::Lz4Hc => 73,
            XisfCodec::Zstd => 10,
        }
    }
}

/// A parsed `compression="codec[+sh]:size[:item]"` attribute.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Compression {
    pub codec: XisfCodec,
    /// Item size of the byte shuffling transform, when the codec has `+sh`.
    pub shuffle_item: Option<usize>,
    pub uncompressed_size: u64,
}

impl Compression {
    pub fn parse(text: &str) -> Result<Self, XisfError> {
        let bad = || XisfError::Malformed(format!("compression attribute \"{text}\""));
        let mut parts = text.trim().split(':');
        let name = parts.next().ok_or_else(bad)?.trim();
        let (codec_name, shuffled) = match name.strip_suffix("+sh") {
            Some(base) => (base, true),
            None => (name, false),
        };
        let codec = XisfCodec::from_name(codec_name)
            .ok_or_else(|| XisfError::UnsupportedCodec(name.to_string()))?;
        let uncompressed_size = parts
            .next()
            .and_then(|s| s.trim().parse::<u64>().ok())
            .ok_or_else(bad)?;
        let shuffle_item = if shuffled {
            let item = parts
                .next()
                .and_then(|s| s.trim().parse::<usize>().ok())
                .ok_or_else(bad)?;
            if item == 0 {
                return Err(bad());
            }
            // Shuffling single bytes is the identity.
            (item > 1).then_some(item)
        } else {
            None
        };
        Ok(Self {
            codec,
            shuffle_item,
            uncompressed_size,
        })
    }

    pub fn attribute(&self) -> String {
        match self.shuffle_item {
            Some(item) => format!(
                "{}+sh:{}:{}",
                self.codec.name(),
                self.uncompressed_size,
                item
            ),
            None => format!("{}:{}", self.codec.name(), self.uncompressed_size),
        }
    }
}

/// Parse `subblocks="c1,u1:c2,u2:..."`.
pub(crate) fn parse_subblocks(text: &str) -> Result<Vec<(u64, u64)>, XisfError> {
    let bad = || XisfError::Malformed(format!("subblocks attribute \"{text}\""));
    text.trim()
        .split(':')
        .map(|pair| {
            let (c, u) = pair.split_once(',').ok_or_else(bad)?;
            Ok((
                c.trim().parse::<u64>().map_err(|_| bad())?,
                u.trim().parse::<u64>().map_err(|_| bad())?,
            ))
        })
        .collect()
}

/// Decompress one subblock into `out`, which is exactly the declared
/// uncompressed length. Anything else the stream yields is an error
/// (section 10.6.1: "shall verify that each compressed subblock decompresses
/// to exactly u bytes").
pub(crate) fn decompress_into(
    codec: XisfCodec,
    compressed: &[u8],
    out: &mut [u8],
) -> Result<(), XisfError> {
    let declared_len = out.len();
    let wrong = |detail: String| {
        XisfError::Corrupt(format!(
            "a {} subblock did not decompress to its declared {declared_len} bytes ({detail})",
            codec.name(),
        ))
    };
    match codec {
        XisfCodec::Zlib => {
            let mut decoder = flate2::read::ZlibDecoder::new(compressed);
            decoder
                .read_exact(out)
                .map_err(|e| wrong(e.to_string()))?;
            let mut extra = [0u8; 1];
            match decoder.read(&mut extra) {
                Ok(0) => Ok(()),
                Ok(_) => Err(wrong("the stream holds more".to_string())),
                Err(e) => Err(wrong(e.to_string())),
            }
        }
        XisfCodec::Lz4 | XisfCodec::Lz4Hc => {
            let declared = i32::try_from(out.len())
                .map_err(|_| wrong("an LZ4 subblock cannot exceed 2 GiB".to_string()))?;
            if out.is_empty() {
                return Ok(());
            }
            let written = lz4::block::decompress_to_buffer(compressed, Some(declared), out)
                .map_err(|e| wrong(e.to_string()))?;
            if written != out.len() {
                return Err(wrong(format!("got {written}")));
            }
            Ok(())
        }
        XisfCodec::Zstd => {
            let written = zstd::bulk::decompress_to_buffer(compressed, out)
                .map_err(|e| wrong(e.to_string()))?;
            if written != out.len() {
                return Err(wrong(format!("got {written}")));
            }
            Ok(())
        }
    }
}

/// Compress one subblock. `level` is the abstract 1..=100 level.
pub(crate) fn compress(codec: XisfCodec, level: u8, input: &[u8]) -> Result<Vec<u8>, XisfError> {
    let native = codec.native_level(level);
    let failed = |e: std::io::Error| {
        XisfError::Io(std::io::Error::new(
            e.kind(),
            format!("{} compression failed: {e}", codec.name()),
        ))
    };
    match codec {
        XisfCodec::Zlib => {
            use std::io::Write;
            let mut encoder = flate2::write::ZlibEncoder::new(
                Vec::with_capacity(input.len() / 2 + 64),
                flate2::Compression::new(native as u32),
            );
            encoder.write_all(input).map_err(failed)?;
            encoder.finish().map_err(failed)
        }
        XisfCodec::Lz4 => lz4::block::compress(input, None, false).map_err(failed),
        XisfCodec::Lz4Hc => lz4::block::compress(
            input,
            Some(lz4::block::CompressionMode::HIGHCOMPRESSION(native)),
            false,
        )
        .map_err(failed),
        XisfCodec::Zstd => {
            let mut compressor = zstd::bulk::Compressor::new(native).map_err(failed)?;
            compressor.include_contentsize(true).map_err(failed)?;
            compressor.compress(input).map_err(failed)
        }
    }
}

/// The byte shuffling transform of section 10.6.3. Trailing bytes that do not
/// form a whole item stay where they are.
pub fn shuffle(input: &[u8], item: usize) -> Vec<u8> {
    let mut out = vec![0u8; input.len()];
    if item <= 1 {
        out.copy_from_slice(input);
        return out;
    }
    let items = input.len() / item;
    for byte in 0..item {
        let plane = &mut out[byte * items..(byte + 1) * items];
        for (dst, src) in plane.iter_mut().zip(input.iter().skip(byte).step_by(item)) {
            *dst = *src;
        }
    }
    out[items * item..].copy_from_slice(&input[items * item..]);
    out
}

/// The reverse byte shuffling transform.
pub fn unshuffle(input: &[u8], item: usize) -> Vec<u8> {
    let mut out = vec![0u8; input.len()];
    if item <= 1 {
        out.copy_from_slice(input);
        return out;
    }
    let items = input.len() / item;
    for byte in 0..item {
        let plane = &input[byte * items..(byte + 1) * items];
        for (dst, src) in out.iter_mut().skip(byte).step_by(item).zip(plane) {
            *dst = *src;
        }
    }
    out[items * item..].copy_from_slice(&input[items * item..]);
    out
}

/// The hashing algorithms of Table 9.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ChecksumAlgorithm {
    Sha1,
    Sha256,
    Sha512,
    Sha3_256,
    Sha3_512,
}

impl ChecksumAlgorithm {
    pub const ALL: [ChecksumAlgorithm; 5] = [
        ChecksumAlgorithm::Sha1,
        ChecksumAlgorithm::Sha256,
        ChecksumAlgorithm::Sha512,
        ChecksumAlgorithm::Sha3_256,
        ChecksumAlgorithm::Sha3_512,
    ];

    pub fn name(self) -> &'static str {
        match self {
            ChecksumAlgorithm::Sha1 => "sha-1",
            ChecksumAlgorithm::Sha256 => "sha-256",
            ChecksumAlgorithm::Sha512 => "sha-512",
            ChecksumAlgorithm::Sha3_256 => "sha3-256",
            ChecksumAlgorithm::Sha3_512 => "sha3-512",
        }
    }

    pub fn from_name(name: &str) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "sha-1" | "sha1" => Some(ChecksumAlgorithm::Sha1),
            "sha-256" | "sha256" => Some(ChecksumAlgorithm::Sha256),
            "sha-512" | "sha512" => Some(ChecksumAlgorithm::Sha512),
            "sha3-256" => Some(ChecksumAlgorithm::Sha3_256),
            "sha3-512" => Some(ChecksumAlgorithm::Sha3_512),
            _ => None,
        }
    }

    pub(crate) fn hasher(self) -> BlockHasher {
        match self {
            ChecksumAlgorithm::Sha1 => BlockHasher::Sha1(sha1::Sha1::new()),
            ChecksumAlgorithm::Sha256 => BlockHasher::Sha256(sha2::Sha256::new()),
            ChecksumAlgorithm::Sha512 => BlockHasher::Sha512(sha2::Sha512::new()),
            ChecksumAlgorithm::Sha3_256 => BlockHasher::Sha3_256(sha3::Sha3_256::new()),
            ChecksumAlgorithm::Sha3_512 => BlockHasher::Sha3_512(sha3::Sha3_512::new()),
        }
    }
}

pub(crate) enum BlockHasher {
    Sha1(sha1::Sha1),
    Sha256(sha2::Sha256),
    Sha512(sha2::Sha512),
    Sha3_256(sha3::Sha3_256),
    Sha3_512(sha3::Sha3_512),
}

impl BlockHasher {
    pub(crate) fn update(&mut self, bytes: &[u8]) {
        match self {
            BlockHasher::Sha1(h) => h.update(bytes),
            BlockHasher::Sha256(h) => h.update(bytes),
            BlockHasher::Sha512(h) => h.update(bytes),
            BlockHasher::Sha3_256(h) => h.update(bytes),
            BlockHasher::Sha3_512(h) => h.update(bytes),
        }
    }

    pub(crate) fn finish(self) -> Vec<u8> {
        match self {
            BlockHasher::Sha1(h) => h.finalize().to_vec(),
            BlockHasher::Sha256(h) => h.finalize().to_vec(),
            BlockHasher::Sha512(h) => h.finalize().to_vec(),
            BlockHasher::Sha3_256(h) => h.finalize().to_vec(),
            BlockHasher::Sha3_512(h) => h.finalize().to_vec(),
        }
    }
}

/// A parsed `checksum="algorithm:digest"` attribute.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Checksum {
    pub algorithm: ChecksumAlgorithm,
    pub digest: Vec<u8>,
}

impl Checksum {
    pub fn parse(text: &str) -> Result<Self, XisfError> {
        let (name, digest) = text
            .trim()
            .split_once(':')
            .ok_or_else(|| XisfError::Malformed(format!("checksum attribute \"{text}\"")))?;
        let algorithm = ChecksumAlgorithm::from_name(name)
            .ok_or_else(|| XisfError::UnsupportedChecksum(name.trim().to_string()))?;
        let digest = decode_hex(digest)?;
        Ok(Self { algorithm, digest })
    }

    pub fn attribute(&self) -> String {
        format!("{}:{}", self.algorithm.name(), encode_hex(&self.digest))
    }
}

pub(crate) fn encode_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(DIGITS[(byte >> 4) as usize] as char);
        out.push(DIGITS[(byte & 15) as usize] as char);
    }
    out
}

/// Base16 text to bytes; white space is ignored (section 10.3).
pub(crate) fn decode_hex(text: &str) -> Result<Vec<u8>, XisfError> {
    let mut out = Vec::with_capacity(text.len() / 2);
    let mut high: Option<u8> = None;
    for ch in text.bytes() {
        if ch.is_ascii_whitespace() {
            continue;
        }
        let nibble = match ch {
            b'0'..=b'9' => ch - b'0',
            b'a'..=b'f' => ch - b'a' + 10,
            b'A'..=b'F' => ch - b'A' + 10,
            _ => {
                return Err(XisfError::Malformed(
                    "a character that is not a hexadecimal digit in Base16 data".to_string(),
                ))
            }
        };
        match high.take() {
            Some(h) => out.push((h << 4) | nibble),
            None => high = Some(nibble),
        }
    }
    if high.is_some() {
        return Err(XisfError::Malformed(
            "Base16 data with an odd number of digits".to_string(),
        ));
    }
    Ok(out)
}

pub(crate) fn encode_base64(bytes: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Base64 text to bytes; white space is ignored (section 10.3).
pub(crate) fn decode_base64(text: &str) -> Result<Vec<u8>, XisfError> {
    use base64::Engine;
    let compact: Vec<u8> = text
        .bytes()
        .filter(|b| !b.is_ascii_whitespace())
        .collect();
    base64::engine::general_purpose::STANDARD
        .decode(compact)
        .or_else(|_| {
            // Some writers leave the padding off.
            let trimmed: Vec<u8> = text
                .bytes()
                .filter(|b| !b.is_ascii_whitespace() && *b != b'=')
                .collect();
            base64::engine::general_purpose::STANDARD_NO_PAD.decode(trimmed)
        })
        .map_err(|e| XisfError::Malformed(format!("Base64 data: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shuffle_matches_the_specification_and_reverses() {
        // Three 2-byte items and one trailing byte.
        let input = [1u8, 2, 3, 4, 5, 6, 7];
        let shuffled = shuffle(&input, 2);
        assert_eq!(shuffled, [1, 3, 5, 2, 4, 6, 7]);
        assert_eq!(unshuffle(&shuffled, 2), input);
        for item in [1usize, 2, 3, 4, 8, 16] {
            let data: Vec<u8> = (0..251u32).map(|i| (i * 7 % 256) as u8).collect();
            assert_eq!(unshuffle(&shuffle(&data, item), item), data, "item {item}");
        }
    }

    #[test]
    fn every_codec_round_trips_and_checks_the_declared_length() {
        let data: Vec<u8> = (0..100_000u32).map(|i| (i / 300) as u8).collect();
        for codec in XisfCodec::ALL {
            let packed = compress(codec, codec.default_level(), &data).unwrap();
            assert!(packed.len() < data.len(), "{codec:?} did not reduce");
            let mut out = vec![0u8; data.len()];
            decompress_into(codec, &packed, &mut out).unwrap();
            assert_eq!(out, data, "{codec:?}");

            let mut short = vec![0u8; data.len() - 1];
            assert!(decompress_into(codec, &packed, &mut short).is_err(), "{codec:?} short");
            let mut long = vec![0u8; data.len() + 1];
            assert!(decompress_into(codec, &packed, &mut long).is_err(), "{codec:?} long");
            assert!(
                decompress_into(codec, &packed[..packed.len() / 2], &mut out).is_err(),
                "{codec:?} truncated"
            );
        }
    }

    #[test]
    fn compression_attribute_forms() {
        let c = Compression::parse("zstd+sh:201326592:4").unwrap();
        assert_eq!(c.codec, XisfCodec::Zstd);
        assert_eq!(c.shuffle_item, Some(4));
        assert_eq!(c.uncompressed_size, 201_326_592);
        assert_eq!(c.attribute(), "zstd+sh:201326592:4");
        let c = Compression::parse("lz4hc:537068").unwrap();
        assert_eq!((c.codec, c.shuffle_item), (XisfCodec::Lz4Hc, None));
        assert!(matches!(
            Compression::parse("brotli:12"),
            Err(XisfError::UnsupportedCodec(_))
        ));
        assert!(Compression::parse("zlib").is_err());
        assert!(Compression::parse("zlib+sh:10").is_err());
        assert_eq!(
            parse_subblocks("10,20:30,30").unwrap(),
            vec![(10, 20), (30, 30)]
        );
        assert!(parse_subblocks("10:20").is_err());
    }

    #[test]
    fn checksums_match_known_digests() {
        // FIPS 180 / FIPS 202 test vectors for "abc".
        let cases = [
            (ChecksumAlgorithm::Sha1, "a9993e364706816aba3e25717850c26c9cd0d89d"),
            (
                ChecksumAlgorithm::Sha256,
                "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            ),
            (
                ChecksumAlgorithm::Sha3_256,
                "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532",
            ),
        ];
        for (algorithm, expected) in cases {
            let mut hasher = algorithm.hasher();
            hasher.update(b"abc");
            assert_eq!(encode_hex(&hasher.finish()), expected, "{algorithm:?}");
        }
        let parsed = Checksum::parse("sha1:A9993E364706816ABA3E25717850C26C9CD0D89D").unwrap();
        assert_eq!(parsed.algorithm, ChecksumAlgorithm::Sha1);
        assert_eq!(
            parsed.attribute(),
            "sha-1:a9993e364706816aba3e25717850c26c9cd0d89d"
        );
        assert!(matches!(
            Checksum::parse("md5:00"),
            Err(XisfError::UnsupportedChecksum(_))
        ));
    }

    #[test]
    fn text_encodings_ignore_white_space() {
        assert_eq!(
            decode_base64(" VGhpcyBpcyBhIHRlc3QgLSBURVNUIC0g\n  MTIzNDU2Nzg5MA== ").unwrap(),
            b"This is a test - TEST - 1234567890"
        );
        assert_eq!(decode_hex("0a ff\n10").unwrap(), [0x0a, 0xff, 0x10]);
        assert!(decode_hex("abc").is_err());
        assert!(decode_hex("zz").is_err());
        assert_eq!(encode_hex(&[0, 171, 255]), "00abff");
    }
}
