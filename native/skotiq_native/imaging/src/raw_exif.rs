//! What a camera raw file records about its frame that LibRaw does not report
//! (or reports wrongly), read from its EXIF and maker notes.
//!
//! The capture time: LibRaw reads the camera's wall clock in the time zone of
//! the computer reading the file, so the same file gets a different UTC time
//! on every computer outside the camera's zone. Cameras made since about 2018
//! record their UTC offset in EXIF (`OffsetTimeOriginal`); Nikon bodies record
//! their zone only in the maker note (`WorldTime`). This module finds
//! `DateTimeOriginal` and the offset in each container LibRaw reads: TIFF-based
//! raws (CR2, NEF, ARW, PEF, DNG, ORF, RW2, ...), CR3 and RAF.
//!
//! The sensor temperature of Pentax bodies, which their maker note keeps in a
//! block LibRaw does not read (`TempInfo`); LibRaw reports only the body
//! temperature.

use chrono::{DateTime, FixedOffset, NaiveDateTime, Utc};
use std::io::{Read, Seek, SeekFrom};

const MAKE: u16 = 0x010f;
const MODEL: u16 = 0x0110;
const EXIF_IFD: u16 = 0x8769;
const MAKER_NOTE: u16 = 0x927c;
const DNG_VERSION: u16 = 0xc612;
const DNG_PRIVATE_DATA: u16 = 0xc634;
const DATE_TIME_ORIGINAL: u16 = 0x9003;
const OFFSET_TIME_ORIGINAL: u16 = 0x9011;
/// Nikon maker note: time zone (minutes, signed), daylight saving, date format.
const NIKON_WORLD_TIME: u16 = 0x0024;
/// Pentax maker note: a 256-byte block of temperature readings.
const PENTAX_TEMP_INFO: u16 = 0x03ff;
const ASCII: u16 = 2;
const UNDEFINED: u16 = 7;

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

/// What the file records beyond LibRaw's reading.
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub(crate) struct CameraRecord {
    /// `None` when the file holds no EXIF capture time this reader can find.
    pub clock: Option<CameraClock>,
    /// The sensor's own temperature from a maker-note block LibRaw does not
    /// read, in degrees Celsius.
    pub sensor_celsius: Option<f32>,
}

pub(crate) fn camera_record<R: Read + Seek>(r: &mut R) -> CameraRecord {
    let mut head = [0u8; 16];
    if r.seek(SeekFrom::Start(0)).is_err() || r.read_exact(&mut head).is_err() {
        return CameraRecord::default();
    }
    if &head[4..8] == b"ftyp" {
        let clock = cr3_exif_box(r).and_then(|cmt2| {
            let tiff = Tiff::at(r, cmt2)?;
            let exif = tiff.ifd(r, tiff.first_ifd)?;
            clock_in_exif(r, &tiff, &exif)
        });
        return CameraRecord {
            clock,
            sensor_celsius: None,
        };
    }
    if head.starts_with(b"FUJIFILMCCD-RAW") {
        return CameraRecord {
            clock: raf_clock(r),
            sensor_celsius: None,
        };
    }
    record_in_tiff(r).unwrap_or_default()
}

/// A RAF keeps its EXIF in the embedded JPEG whose offset is at byte 84.
fn raf_clock<R: Read + Seek>(r: &mut R) -> Option<CameraClock> {
    r.seek(SeekFrom::Start(84)).ok()?;
    let jpeg = u32::from_be_bytes(read_array(r)?) as u64;
    let start = jpeg_exif_tiff(r, jpeg)?;
    let tiff = Tiff::at(r, start)?;
    let ifd0 = tiff.ifd(r, tiff.first_ifd)?;
    let exif = tiff.ifd(r, tiff.pointer(&ifd0, EXIF_IFD)?)?;
    clock_in_exif(r, &tiff, &exif)
}

/// Whether a classic TIFF starting with `head` was written by a camera as its
/// raw file, and by which maker: `Some(None)` for a DNG, `Some(Some(make))`
/// for a maker's own TIFF-based raw. `None` for a TIFF no camera marked (or
/// whose marks lie beyond `head`).
pub(crate) fn tiff_raw_make(head: &[u8]) -> Option<Option<String>> {
    let r = &mut std::io::Cursor::new(head);
    let tiff = Tiff::at(r, 0).filter(|t| t.magic == 42)?;
    let ifd0 = tiff.ifd(r, tiff.first_ifd)?;
    if ifd0.iter().any(|e| e.tag == DNG_VERSION) {
        return Some(None);
    }
    tiff.text(r, &ifd0, MAKE).filter(|m| !m.is_empty()).map(Some)
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
    fn from_mark(mark: &[u8]) -> Option<Self> {
        match mark {
            b"II" => Some(ByteOrder { little: true }),
            b"MM" => Some(ByteOrder { little: false }),
            _ => None,
        }
    }
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

/// A TIFF structure: its byte order, the position its offsets count from and
/// the position of its first IFD.
struct Tiff {
    order: ByteOrder,
    base: u64,
    magic: u16,
    first_ifd: u64,
}

impl Tiff {
    /// The TIFF header at `start`. Accepts the magic numbers of the TIFF-based
    /// raw formats (42; Olympus `RO` and `RS`; Panasonic 0x55).
    fn at<R: Read + Seek>(r: &mut R, start: u64) -> Option<Self> {
        r.seek(SeekFrom::Start(start)).ok()?;
        let head: [u8; 8] = read_array(r)?;
        let order = ByteOrder::from_mark(&head[..2])?;
        let magic = order.u16([head[2], head[3]]);
        if !matches!(magic, 42 | 0x4f52 | 0x5352 | 0x55) {
            return None;
        }
        Some(Tiff {
            order,
            base: start,
            magic,
            first_ifd: start + order.u32([head[4], head[5], head[6], head[7]]) as u64,
        })
    }

    fn ifd<R: Read + Seek>(&self, r: &mut R, at: u64) -> Option<Vec<Entry>> {
        r.seek(SeekFrom::Start(at)).ok()?;
        let count = self.order.u16(read_array(r)?);
        if count == 0 || count > 1000 {
            return None;
        }
        (0..count)
            .map(|_| {
                let e: [u8; 12] = read_array(r)?;
                Some(Entry {
                    tag: self.order.u16([e[0], e[1]]),
                    kind: self.order.u16([e[2], e[3]]),
                    count: self.order.u32([e[4], e[5], e[6], e[7]]),
                    value: [e[8], e[9], e[10], e[11]],
                })
            })
            .collect()
    }

    /// Where a tag's value (or the IFD a pointer tag names) lies in the file.
    fn pointer(&self, entries: &[Entry], tag: u16) -> Option<u64> {
        let entry = entries.iter().find(|e| e.tag == tag)?;
        Some(self.base + self.order.u32(entry.value) as u64)
    }

    fn text<R: Read + Seek>(&self, r: &mut R, entries: &[Entry], tag: u16) -> Option<String> {
        let entry = entries.iter().find(|e| e.tag == tag)?;
        if entry.kind != ASCII || entry.count == 0 || entry.count > 64 {
            return None;
        }
        let bytes = if entry.count <= 4 {
            entry.value[..entry.count as usize].to_vec()
        } else {
            r.seek(SeekFrom::Start(self.base + self.order.u32(entry.value) as u64))
                .ok()?;
            let mut buf = vec![0u8; entry.count as usize];
            r.read_exact(&mut buf).ok()?;
            buf
        };
        let text: Vec<u8> = bytes.into_iter().take_while(|&b| b != 0).collect();
        Some(String::from_utf8_lossy(&text).trim().to_string())
    }
}

/// A TIFF-based raw file: its EXIF clock (with the Nikon maker note's zone
/// when EXIF has none) and the Pentax maker note's sensor temperature.
fn record_in_tiff<R: Read + Seek>(r: &mut R) -> Option<CameraRecord> {
    let tiff = Tiff::at(r, 0)?;
    let ifd0 = tiff.ifd(r, tiff.first_ifd)?;
    let model = tiff.text(r, &ifd0, MODEL).unwrap_or_default();
    let exif = tiff
        .pointer(&ifd0, EXIF_IFD)
        .and_then(|at| tiff.ifd(r, at))
        .unwrap_or_default();
    let maker_note = tiff.pointer(&exif, MAKER_NOTE);

    let mut clock = clock_in_exif(r, &tiff, &exif);
    if let Some(clock) = clock.as_mut().filter(|c| c.offset.is_none()) {
        clock.offset = maker_note.and_then(|at| nikon_zone(r, at));
    }
    let pentax = maker_note
        .and_then(|at| pentax_maker_note(r, &tiff, at))
        .or_else(|| {
            let at = tiff.pointer(&ifd0, DNG_PRIVATE_DATA)?;
            pentax_maker_note(r, &tiff, at)
        });
    let sensor_celsius = pentax.and_then(|(note, ifd)| pentax_sensor_celsius(r, &note, &ifd, &model));
    Some(CameraRecord {
        clock,
        sensor_celsius,
    })
}

fn clock_in_exif<R: Read + Seek>(r: &mut R, tiff: &Tiff, exif: &[Entry]) -> Option<CameraClock> {
    let wall = NaiveDateTime::parse_from_str(
        &tiff.text(r, exif, DATE_TIME_ORIGINAL)?,
        "%Y:%m:%d %H:%M:%S",
    )
    .ok()?;
    let offset = tiff
        .text(r, exif, OFFSET_TIME_ORIGINAL)
        .and_then(|s| parse_offset(&s));
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

/// The UTC offset of the camera clock from a Nikon maker note (`Nikon\0` then
/// version 2, which embeds its own TIFF 10 bytes in): the zone plus an hour
/// when the camera was set to daylight saving.
fn nikon_zone<R: Read + Seek>(r: &mut R, maker_note: u64) -> Option<FixedOffset> {
    r.seek(SeekFrom::Start(maker_note)).ok()?;
    if &read_array::<_, 7>(r)? != b"Nikon\0\x02" {
        return None;
    }
    let tiff = Tiff::at(r, maker_note + 10)?;
    let ifd = tiff.ifd(r, tiff.first_ifd)?;
    let world = ifd
        .iter()
        .find(|e| e.tag == NIKON_WORLD_TIME && e.kind == UNDEFINED && e.count == 4)?;
    let zone_minutes = tiff.order.u16([world.value[0], world.value[1]]) as i16 as i32;
    let daylight = world.value[2] == 1;
    let minutes = zone_minutes + if daylight { 60 } else { 0 };
    if minutes.abs() > 14 * 60 {
        return None;
    }
    FixedOffset::east_opt(minutes * 60)
}

/// A Pentax maker note: in a PEF the EXIF maker note (`AOC\0`, byte order,
/// IFD; offsets count from the file's TIFF header), in a DNG the private data
/// block (`PENTAX \0`, byte order, IFD; offsets count from the block). Returns
/// the note's own TIFF frame and its IFD.
fn pentax_maker_note<R: Read + Seek>(
    r: &mut R,
    file: &Tiff,
    at: u64,
) -> Option<(Tiff, Vec<Entry>)> {
    r.seek(SeekFrom::Start(at)).ok()?;
    let head: [u8; 10] = read_array(r)?;
    let (order_at, ifd_at, base) = if head.starts_with(b"AOC\0") {
        (4, at + 6, file.base)
    } else if head.starts_with(b"PENTAX \0") {
        (8, at + 10, at)
    } else {
        return None;
    };
    let order = ByteOrder::from_mark(&head[order_at..order_at + 2])?;
    let note = Tiff {
        order,
        base,
        magic: 42,
        first_ifd: ifd_at,
    };
    let ifd = note.ifd(r, ifd_at)?;
    Some((note, ifd))
}

/// The sensor reading in a Pentax `TempInfo` block: a signed tenth-degree value
/// at byte 0x0c, or 0x2a on the K-3 Mark III. Only the bodies ExifTool lists
/// for this block (K-01, K-3, K-30, K-5, K-50, K-500 and their variants)
/// are read; other bodies use the block for something else.
fn pentax_sensor_celsius<R: Read + Seek>(
    r: &mut R,
    note: &Tiff,
    ifd: &[Entry],
    model: &str,
) -> Option<f32> {
    let body = model.trim_start_matches("PENTAX").trim();
    let series = body.strip_prefix("K-")?;
    let known = ["01", "3", "30", "5", "50", "500"].iter().any(|s| {
        series
            .strip_prefix(s)
            .is_some_and(|rest| rest.is_empty() || rest.starts_with(' '))
    });
    if !known {
        return None;
    }
    let field = if series.starts_with("3 Mark III") { 0x2a } else { 0x0c };
    let block = ifd
        .iter()
        .find(|e| e.tag == PENTAX_TEMP_INFO && e.kind == UNDEFINED && e.count >= 0x30)?;
    r.seek(SeekFrom::Start(
        note.base + note.order.u32(block.value) as u64 + field,
    ))
    .ok()?;
    let tenths = note.order.u16(read_array(r)?) as i16;
    let celsius = f32::from(tenths) / 10.0;
    (-40.0..=85.0).contains(&celsius).then_some(celsius)
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

    fn record(bytes: Vec<u8>) -> CameraRecord {
        camera_record(&mut Cursor::new(bytes))
    }

    fn clock(bytes: Vec<u8>) -> Option<CameraClock> {
        record(bytes).clock
    }

    fn utc(text: &str) -> DateTime<Utc> {
        text.parse().unwrap()
    }

    /// One big-endian IFD entry.
    fn entry(tag: u16, kind: u16, count: u32, value: [u8; 4]) -> Vec<u8> {
        let mut e = tag.to_be_bytes().to_vec();
        e.extend(kind.to_be_bytes());
        e.extend(count.to_be_bytes());
        e.extend(value);
        e
    }

    /// A one-entry big-endian IFD with no next IFD.
    fn ifd(entry: Vec<u8>) -> Vec<u8> {
        let mut out = 1u16.to_be_bytes().to_vec();
        out.extend(entry);
        out.extend(0u32.to_be_bytes());
        out
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

    /// The layout of a Nikon NEF: Exif IFD with the capture time and a maker
    /// note whose embedded TIFF holds `WorldTime` (zone -08:00, daylight
    /// saving on), as the D7000 sample records it.
    #[test]
    fn a_nikon_maker_note_supplies_the_zone_exif_lacks() {
        let mut file = b"MM\0*".to_vec();
        file.extend(8u32.to_be_bytes());
        file.extend(ifd(entry(EXIF_IFD, 4, 1, 26u32.to_be_bytes())));
        let wall = b"2017:01:22 14:18:36\0";
        let mut note = b"Nikon\0\x02\x10\0\0MM\0*".to_vec();
        note.extend(8u32.to_be_bytes());
        note.extend(ifd(entry(NIKON_WORLD_TIME, UNDEFINED, 4, [0xfe, 0x20, 1, 1])));
        let mut exif = 2u16.to_be_bytes().to_vec();
        exif.extend(entry(DATE_TIME_ORIGINAL, ASCII, wall.len() as u32, 56u32.to_be_bytes()));
        exif.extend(entry(MAKER_NOTE, UNDEFINED, note.len() as u32, 76u32.to_be_bytes()));
        exif.extend(0u32.to_be_bytes());
        file.extend(exif);
        assert_eq!(file.len(), 56);
        file.extend(wall);
        file.extend(&note);

        let c = clock(file.clone()).unwrap();
        assert_eq!(c.offset, FixedOffset::west_opt(7 * 3600));
        assert_eq!(c.utc(), Some(utc("2017-01-22T21:18:36Z")));

        // Without daylight saving the zone is the plain -08:00.
        let at = file.len() - note.len() + 18 + 2 + 8 + 2;
        file[at] = 0;
        assert_eq!(clock(file).unwrap().utc(), Some(utc("2017-01-22T22:18:36Z")));
    }

    /// The layout of a Pentax PEF: IFD0 names the model and points at the Exif
    /// IFD, whose `AOC` maker note holds `TempInfo` (offsets from the file's
    /// TIFF header), as the K-5 sample records it.
    fn pentax_pef(model: &str, tenths: i16) -> Vec<u8> {
        let model = format!("{model}\0");
        let model_at = 38u32;
        let exif_at = 64u32;
        let mut file = b"MM\0*".to_vec();
        file.extend(8u32.to_be_bytes());
        file.extend(2u16.to_be_bytes());
        file.extend(entry(MODEL, ASCII, model.len() as u32, model_at.to_be_bytes()));
        file.extend(entry(EXIF_IFD, 4, 1, exif_at.to_be_bytes()));
        file.extend(0u32.to_be_bytes());
        file.extend(model.as_bytes());
        file.resize(exif_at as usize, 0);
        let note_at = exif_at + 18;
        let block_at = note_at + 6 + 18;
        let mut note = b"AOC\0MM".to_vec();
        note.extend(ifd(entry(PENTAX_TEMP_INFO, UNDEFINED, 256, block_at.to_be_bytes())));
        file.extend(ifd(entry(MAKER_NOTE, UNDEFINED, note.len() as u32, note_at.to_be_bytes())));
        file.extend(note);
        assert_eq!(file.len(), block_at as usize);
        let mut block = vec![0u8; 256];
        block[0x0c..0x0e].copy_from_slice(&tenths.to_be_bytes());
        file.extend(block);
        file
    }

    #[test]
    fn a_pentax_maker_note_supplies_the_sensor_temperature() {
        assert_eq!(record(pentax_pef("PENTAX K-5", 324)).sensor_celsius, Some(32.4));
        assert_eq!(record(pentax_pef("PENTAX K-5 II s", -55)).sensor_celsius, Some(-5.5));
        // Bodies that use the block for something else, and readings no
        // sensor reports, are not taken.
        assert_eq!(record(pentax_pef("PENTAX K-1", 324)).sensor_celsius, None);
        assert_eq!(record(pentax_pef("PENTAX K-5", 3240)).sensor_celsius, None);
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

    #[test]
    fn a_camera_tiff_names_its_maker_and_a_plain_tiff_none() {
        let mut nef = b"MM\0*".to_vec();
        nef.extend(8u32.to_be_bytes());
        nef.extend(ifd(entry(MAKE, ASCII, 18, 26u32.to_be_bytes())));
        nef.extend(b"NIKON CORPORATION\0");
        assert_eq!(tiff_raw_make(&nef), Some(Some("NIKON CORPORATION".to_string())));
        // A Make string beyond the bytes at hand says nothing.
        assert_eq!(tiff_raw_make(&nef[..30]), None);

        let mut dng = b"MM\0*".to_vec();
        dng.extend(8u32.to_be_bytes());
        dng.extend(ifd(entry(DNG_VERSION, 1, 4, [1, 4, 0, 0])));
        assert_eq!(tiff_raw_make(&dng), Some(None));

        let mut plain = b"II*\0".to_vec();
        plain.extend(8u32.to_le_bytes());
        plain.extend(1u16.to_le_bytes());
        plain.extend(0x0100u16.to_le_bytes());
        plain.extend(3u16.to_le_bytes());
        plain.extend(1u32.to_le_bytes());
        plain.extend(64u32.to_le_bytes());
        plain.extend(0u32.to_le_bytes());
        assert_eq!(tiff_raw_make(&plain), None);
    }
}
