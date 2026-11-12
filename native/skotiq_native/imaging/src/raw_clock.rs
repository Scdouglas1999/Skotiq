//! When a camera raw frame was taken, as the camera recorded it in EXIF.
//!
//! LibRaw reports the capture time as the camera's wall clock read in the time
//! zone of the computer reading the file, so the same file gets a different
//! UTC time on every computer that is not in the camera's zone. Cameras made
//! since about 2018 also record their UTC offset (EXIF `OffsetTimeOriginal`);
//! this module finds `DateTimeOriginal` and that offset in each container
//! LibRaw reads: TIFF-based raws (CR2, NEF, ARW, PEF, DNG, ORF, RW2, ...), CR3
//! and RAF.

use chrono::{DateTime, FixedOffset, NaiveDateTime, Utc};
use std::io::{Read, Seek, SeekFrom};

const EXIF_IFD: u16 = 0x8769;
const DATE_TIME_ORIGINAL: u16 = 0x9003;
const OFFSET_TIME_ORIGINAL: u16 = 0x9011;
const ASCII: u16 = 2;

/// Canon's metadata box inside a CR3 `moov`.
const CANON_CR3_UUID: [u8; 16] = [
    0x85, 0xc0, 0xb6, 0x87, 0x82, 0x0f, 0x11, 0xe0, 0x81, 0x11, 0xf4, 0xce, 0x46, 0x2b, 0x6a, 0x48,
];

/// The camera's own record of when it took the frame.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct CameraClock {
    pub wall: NaiveDateTime,
    pub offset: Option<FixedOffset>,
}

impl CameraClock {
    /// The capture time in UTC, when the camera recorded its offset.
    pub fn utc(&self) -> Option<DateTime<Utc>> {
        let offset = self.offset?;
        self.wall
            .and_local_timezone(offset)
            .single()
            .map(|t| t.with_timezone(&Utc))
    }
}

/// `None` when the file holds no EXIF capture time this reader can find.
pub(crate) fn camera_clock<R: Read + Seek>(r: &mut R) -> Option<CameraClock> {
    let mut head = [0u8; 16];
    r.seek(SeekFrom::Start(0)).ok()?;
    r.read_exact(&mut head).ok()?;
    if &head[4..8] == b"ftyp" {
        let cmt2 = cr3_exif_box(r)?;
        return clock_in_tiff(r, cmt2, true);
    }
    if head.starts_with(b"FUJIFILMCCD-RAW") {
        r.seek(SeekFrom::Start(84)).ok()?;
        let jpeg = u32::from_be_bytes(read_array(r)?) as u64;
        let tiff = jpeg_exif_tiff(r, jpeg)?;
        return clock_in_tiff(r, tiff, false);
    }
    clock_in_tiff(r, 0, false)
}

fn read_array<R: Read, const N: usize>(r: &mut R) -> Option<[u8; N]> {
    let mut buf = [0u8; N];
    r.read_exact(&mut buf).ok()?;
    Some(buf)
}

#[derive(Clone, Copy)]
struct ByteOrder {
    little: bool,
}

impl ByteOrder {
    fn u16(self, b: [u8; 2]) -> u16 {
        if self.little {
            u16::from_le_bytes(b)
        } else {
            u16::from_be_bytes(b)
        }
    }
    fn u32(self, b: [u8; 4]) -> u32 {
        if self.little {
            u32::from_le_bytes(b)
        } else {
            u32::from_be_bytes(b)
        }
    }
}

struct Entry {
    tag: u16,
    kind: u16,
    count: u32,
    /// The value itself when it fits in four bytes, else its offset.
    value: [u8; 4],
}

/// A TIFF structure starting at `start`: its byte order and the offset of IFD0.
/// Accepts the magic numbers of the TIFF-based raw formats (42; Olympus `RO`
/// and `RS`; Panasonic 0x55).
fn tiff_header<R: Read + Seek>(r: &mut R, start: u64) -> Option<(ByteOrder, u64)> {
    r.seek(SeekFrom::Start(start)).ok()?;
    let head: [u8; 8] = read_array(r)?;
    let order = match &head[..2] {
        b"II" => ByteOrder { little: true },
        b"MM" => ByteOrder { little: false },
        _ => return None,
    };
    let magic = order.u16([head[2], head[3]]);
    if !matches!(magic, 42 | 0x4f52 | 0x5352 | 0x55) {
        return None;
    }
    Some((
        order,
        start + order.u32([head[4], head[5], head[6], head[7]]) as u64,
    ))
}

fn read_ifd<R: Read + Seek>(r: &mut R, order: ByteOrder, at: u64) -> Option<Vec<Entry>> {
    r.seek(SeekFrom::Start(at)).ok()?;
    let count = order.u16(read_array(r)?);
    if count == 0 || count > 1000 {
        return None;
    }
    (0..count)
        .map(|_| {
            let e: [u8; 12] = read_array(r)?;
            Some(Entry {
                tag: order.u16([e[0], e[1]]),
                kind: order.u16([e[2], e[3]]),
                count: order.u32([e[4], e[5], e[6], e[7]]),
                value: [e[8], e[9], e[10], e[11]],
            })
        })
        .collect()
}

fn ascii<R: Read + Seek>(r: &mut R, order: ByteOrder, tiff: u64, entry: &Entry) -> Option<String> {
    if entry.kind != ASCII || entry.count == 0 || entry.count > 64 {
        return None;
    }
    let bytes = if entry.count <= 4 {
        entry.value[..entry.count as usize].to_vec()
    } else {
        r.seek(SeekFrom::Start(tiff + order.u32(entry.value) as u64))
            .ok()?;
        let mut buf = vec![0u8; entry.count as usize];
        r.read_exact(&mut buf).ok()?;
        buf
    };
    let text: Vec<u8> = bytes.into_iter().take_while(|&b| b != 0).collect();
    Some(String::from_utf8_lossy(&text).trim().to_string())
}

/// `ifd0_is_exif`: CR3's `CMT2` box is a TIFF whose first IFD is the Exif IFD.
fn clock_in_tiff<R: Read + Seek>(r: &mut R, tiff: u64, ifd0_is_exif: bool) -> Option<CameraClock> {
    let (order, ifd0) = tiff_header(r, tiff)?;
    let exif_ifd = if ifd0_is_exif {
        ifd0
    } else {
        let entries = read_ifd(r, order, ifd0)?;
        let pointer = entries.iter().find(|e| e.tag == EXIF_IFD)?;
        tiff + order.u32(pointer.value) as u64
    };
    let entries = read_ifd(r, order, exif_ifd)?;
    let text = |tag: u16, r: &mut R| {
        entries
            .iter()
            .find(|e| e.tag == tag)
            .and_then(|e| ascii(r, order, tiff, e))
    };
    let wall =
        NaiveDateTime::parse_from_str(&text(DATE_TIME_ORIGINAL, r)?, "%Y:%m:%d %H:%M:%S").ok()?;
    let offset = text(OFFSET_TIME_ORIGINAL, r).and_then(|s| parse_offset(&s));
    Some(CameraClock { wall, offset })
}

/// `+HH:MM` or `-HH:MM`, as EXIF 2.31 writes it.
fn parse_offset(text: &str) -> Option<FixedOffset> {
    let bytes = text.as_bytes();
    if bytes.len() != 6 || bytes[3] != b':' {
        return None;
    }
    let hours: i32 = text.get(1..3)?.parse().ok()?;
    let minutes: i32 = text.get(4..6)?.parse().ok()?;
    let seconds = hours * 3600 + minutes * 60;
    match bytes[0] {
        b'+' => FixedOffset::east_opt(seconds),
        b'-' => FixedOffset::west_opt(seconds),
        _ => None,
    }
}

/// The ISO-BMFF boxes directly inside `[start, end)`: (type, payload start, end).
fn boxes<R: Read + Seek>(r: &mut R, start: u64, end: u64) -> Vec<([u8; 4], u64, u64)> {
    let mut found = Vec::new();
    let mut at = start;
    while at + 8 <= end && found.len() < 256 {
        if r.seek(SeekFrom::Start(at)).is_err() {
            break;
        }
        let Some(head) = read_array::<_, 8>(r) else {
            break;
        };
        let mut size = u32::from_be_bytes([head[0], head[1], head[2], head[3]]) as u64;
        let mut payload = at + 8;
        if size == 1 {
            let Some(large) = read_array::<_, 8>(r) else {
                break;
            };
            size = u64::from_be_bytes(large);
            payload += 8;
        } else if size == 0 {
            size = end - at;
        }
        if size < payload - at || at + size > end {
            break;
        }
        found.push(([head[4], head[5], head[6], head[7]], payload, at + size));
        at += size;
    }
    found
}

/// The start of the `CMT2` (Exif IFD) TIFF inside a CR3.
fn cr3_exif_box<R: Read + Seek>(r: &mut R) -> Option<u64> {
    let end = r.seek(SeekFrom::End(0)).ok()?;
    let (_, moov, moov_end) = boxes(r, 0, end).into_iter().find(|b| &b.0 == b"moov")?;
    for (kind, payload, box_end) in boxes(r, moov, moov_end) {
        if &kind != b"uuid" {
            continue;
        }
        r.seek(SeekFrom::Start(payload)).ok()?;
        if read_array::<_, 16>(r)? != CANON_CR3_UUID {
            continue;
        }
        return boxes(r, payload + 16, box_end)
            .into_iter()
            .find(|b| &b.0 == b"CMT2")
            .map(|b| b.1);
    }
    None
}

/// The TIFF inside a JPEG's EXIF APP1 segment.
fn jpeg_exif_tiff<R: Read + Seek>(r: &mut R, jpeg: u64) -> Option<u64> {
    r.seek(SeekFrom::Start(jpeg)).ok()?;
    if read_array::<_, 2>(r)? != [0xff, 0xd8] {
        return None;
    }
    let mut at = jpeg + 2;
    for _ in 0..32 {
        r.seek(SeekFrom::Start(at)).ok()?;
        let marker: [u8; 4] = read_array(r)?;
        if marker[0] != 0xff || marker[1] == 0xda {
            return None;
        }
        let length = u16::from_be_bytes([marker[2], marker[3]]) as u64;
        if marker[1] == 0xe1 && read_array::<_, 6>(r)? == *b"Exif\0\0" {
            return Some(at + 10);
        }
        at += 2 + length;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    /// A TIFF whose IFD0 points at an Exif IFD holding the two tags; or, with
    /// `ifd0_is_exif`, whose IFD0 holds them itself (CR3's CMT2).
    fn tiff(little: bool, wall: &str, offset: Option<&str>, ifd0_is_exif: bool) -> Vec<u8> {
        let u16b = |v: u16| {
            if little {
                v.to_le_bytes()
            } else {
                v.to_be_bytes()
            }
        };
        let u32b = |v: u32| {
            if little {
                v.to_le_bytes()
            } else {
                v.to_be_bytes()
            }
        };
        let mut out = if little {
            b"II".to_vec()
        } else {
            b"MM".to_vec()
        };
        out.extend(u16b(42));
        out.extend(u32b(8));
        let mut strings: Vec<(u16, Vec<u8>)> =
            vec![(DATE_TIME_ORIGINAL, format!("{wall}\0").into_bytes())];
        if let Some(o) = offset {
            strings.push((OFFSET_TIME_ORIGINAL, format!("{o}\0").into_bytes()));
        }
        let exif_at = if ifd0_is_exif { 8 } else { 8 + 2 + 12 + 4 };
        if !ifd0_is_exif {
            out.extend(u16b(1));
            out.extend(u16b(EXIF_IFD));
            out.extend(u16b(4));
            out.extend(u32b(1));
            out.extend(u32b(exif_at as u32));
            out.extend(u32b(0));
        }
        let mut data_at = exif_at + 2 + 12 * strings.len() + 4;
        out.extend(u16b(strings.len() as u16));
        for (tag, s) in &strings {
            out.extend(u16b(*tag));
            out.extend(u16b(ASCII));
            out.extend(u32b(s.len() as u32));
            out.extend(u32b(data_at as u32));
            data_at += s.len();
        }
        out.extend(u32b(0));
        for (_, s) in &strings {
            out.extend(s);
        }
        out
    }

    fn clock(bytes: Vec<u8>) -> Option<CameraClock> {
        camera_clock(&mut Cursor::new(bytes))
    }

    fn utc(text: &str) -> DateTime<Utc> {
        text.parse().unwrap()
    }

    #[test]
    fn a_recorded_offset_gives_the_utc_capture_time() {
        for little in [true, false] {
            let c = clock(tiff(little, "2023:10:19 16:13:48", Some("+02:00"), false)).unwrap();
            assert_eq!(c.utc(), Some(utc("2023-10-19T14:13:48Z")));
        }
        let west = clock(tiff(true, "2022:03:05 15:47:24", Some("-05:00"), false)).unwrap();
        assert_eq!(west.utc(), Some(utc("2022-03-05T20:47:24Z")));
    }

    #[test]
    fn without_an_offset_the_wall_clock_has_no_utc_time() {
        let c = clock(tiff(true, "2017:12:29 11:09:16", None, false)).unwrap();
        assert_eq!(c.wall.to_string(), "2017-12-29 11:09:16");
        assert_eq!(c.utc(), None);
    }

    #[test]
    fn a_cr3_is_read_from_its_exif_box() {
        let cmt2 = tiff(true, "2021:05:10 20:08:34", Some("+00:00"), true);
        let bmff_box = |kind: &[u8], payload: &[u8]| {
            let mut b = ((8 + payload.len()) as u32).to_be_bytes().to_vec();
            b.extend(kind);
            b.extend(payload);
            b
        };
        let mut canon = CANON_CR3_UUID.to_vec();
        canon.extend(bmff_box(b"CMT1", b"skip"));
        canon.extend(bmff_box(b"CMT2", &cmt2));
        let moov = bmff_box(b"moov", &bmff_box(b"uuid", &canon));
        let mut file = bmff_box(b"ftyp", b"crx \0\0\0\x01");
        file.extend(moov);
        assert_eq!(
            clock(file).unwrap().utc(),
            Some(utc("2021-05-10T20:08:34Z"))
        );
    }

    #[test]
    fn a_raf_is_read_from_its_embedded_jpeg() {
        let exif = tiff(false, "2018:09:25 16:54:03", Some("+09:00"), false);
        let mut jpeg = vec![0xff, 0xd8, 0xff, 0xe0, 0, 4, 0, 0];
        jpeg.extend([0xff, 0xe1]);
        jpeg.extend(((2 + 6 + exif.len()) as u16).to_be_bytes());
        jpeg.extend(b"Exif\0\0");
        jpeg.extend(exif);
        let mut file = b"FUJIFILMCCD-RAW 0201FF383501".to_vec();
        file.resize(84, 0);
        file.extend(100u32.to_be_bytes());
        file.resize(100, 0);
        file.extend(jpeg);
        assert_eq!(
            clock(file).unwrap().utc(),
            Some(utc("2018-09-25T07:54:03Z"))
        );
    }

    #[test]
    fn files_without_exif_have_no_clock() {
        assert_eq!(clock(vec![0xff; 64]), None);
        assert_eq!(clock(b"II*\0\x08\0\0\0\0\0\0\0\0\0\0\0".to_vec()), None);
        assert_eq!(parse_offset("+2:00"), None);
        assert_eq!(parse_offset("Z"), None);
    }
}
