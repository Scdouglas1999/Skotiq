//! The one way the app reads and writes image files.
//!
//! Every consumer — capture saves, the Darkroom, calibration, the viewer,
//! plate solving, thumbnails — calls the free functions here with a path and
//! gets the app's frame: pixels as [`ImageData`] and metadata as a
//! [`FitsHeader`]. Which format a file is in is decided once, here, from its
//! first bytes (its extension when they say nothing). Each format is one
//! [`FrameCodec`]; supporting another format is one more codec in [`CODECS`].

use crate::xisf::{self, XisfError, XisfWriteOptions};
use crate::{FitsError, FitsHeader, ImageData, Maker};
use std::io::Read;
use std::path::Path;

/// The kinds of file the app reads as frames.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    Fits,
    Xisf,
    /// A camera maker's raw file: CR2, CR3, NEF, ARW, RAF, PEF, DNG, ORF, RW2
    /// and the others LibRaw reads.
    CameraRaw,
}

impl ImageFormat {
    /// The format's name in a sentence.
    pub fn name(self) -> &'static str {
        match self {
            ImageFormat::Fits => "FITS",
            ImageFormat::Xisf => "XISF",
            ImageFormat::CameraRaw => "camera raw",
        }
    }

    fn codec(self) -> &'static dyn FrameCodec {
        match self {
            ImageFormat::Fits => &FitsFrames,
            ImageFormat::Xisf => &XisfFrames,
            ImageFormat::CameraRaw => &RawFrames,
        }
    }
}

#[derive(Debug)]
pub enum FrameIoError {
    Io(std::io::Error),
    Fits(FitsError),
    Xisf(XisfError),
    Raw(String),
    /// Neither the content nor the extension names a format the app reads.
    UnknownFormat(String),
    /// The format is read-only in the app.
    WriteUnsupported(ImageFormat),
}

impl std::fmt::Display for FrameIoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FrameIoError::Io(e) => write!(f, "{e}"),
            FrameIoError::Fits(e) => write!(f, "{e}"),
            FrameIoError::Xisf(e) => write!(f, "{e}"),
            FrameIoError::Raw(e) => write!(f, "{e}"),
            FrameIoError::UnknownFormat(name) => write!(
                f,
                "{name} is not an image Skotiq can open (it reads FITS, XISF and camera raw files)"
            ),
            FrameIoError::WriteUnsupported(format) => {
                write!(f, "Skotiq cannot save {} files", format.name())
            }
        }
    }
}

impl std::error::Error for FrameIoError {}

impl From<std::io::Error> for FrameIoError {
    fn from(e: std::io::Error) -> Self {
        FrameIoError::Io(e)
    }
}

impl From<FitsError> for FrameIoError {
    fn from(e: FitsError) -> Self {
        FrameIoError::Fits(e)
    }
}

impl From<crate::RawError> for FrameIoError {
    fn from(e: crate::RawError) -> Self {
        FrameIoError::Raw(e.to_string())
    }
}

impl From<XisfError> for FrameIoError {
    fn from(e: XisfError) -> Self {
        FrameIoError::Xisf(e)
    }
}

/// Choices a format may honor when it writes; a format ignores the ones that
/// are not its own.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FrameWriteOptions {
    pub xisf: XisfWriteOptions,
}

pub trait FrameCodec: Sync {
    fn format(&self) -> ImageFormat;
    /// File extensions, lower case, without the dot. The first is the one new
    /// files get.
    fn extensions(&self) -> &'static [&'static str];
    /// Whether a file starting with `head` (up to [`HEAD_BYTES`]) is this format.
    fn probe(&self, head: &[u8]) -> bool;
    /// The metadata alone, without decoding pixels.
    fn read_header(&self, path: &Path) -> Result<FitsHeader, FrameIoError>;
    fn read(&self, path: &Path) -> Result<(ImageData, FitsHeader), FrameIoError>;
    /// A whole file held in memory.
    fn read_bytes(&self, bytes: &[u8]) -> Result<(ImageData, FitsHeader), FrameIoError>;
    fn write(
        &self,
        path: &Path,
        image: &ImageData,
        header: &FitsHeader,
        options: &FrameWriteOptions,
    ) -> Result<(), FrameIoError> {
        let _ = (path, image, header, options);
        Err(FrameIoError::WriteUnsupported(self.format()))
    }
    /// An 8-bit preview stored in the file, already stretched for display,
    /// when the file holds one whose longer side reaches `min_side`.
    fn read_preview(&self, path: &Path, min_side: u32) -> Result<Option<ImageData>, FrameIoError> {
        let _ = (path, min_side);
        Ok(None)
    }
    /// Change a file's metadata in place, keeping its pixels and anything
    /// else it holds.
    fn rewrite_header(
        &self,
        path: &Path,
        edit: &mut dyn FnMut(&mut FitsHeader),
    ) -> Result<(), FrameIoError> {
        let _ = (path, edit);
        Err(FrameIoError::WriteUnsupported(self.format()))
    }
}

struct FitsFrames;

impl FrameCodec for FitsFrames {
    fn format(&self) -> ImageFormat {
        ImageFormat::Fits
    }
    fn extensions(&self) -> &'static [&'static str] {
        &["fits", "fit", "fts"]
    }
    fn probe(&self, head: &[u8]) -> bool {
        head.starts_with(b"SIMPLE  =")
    }
    fn read_header(&self, path: &Path) -> Result<FitsHeader, FrameIoError> {
        Ok(crate::read_fits_header(path)?)
    }
    fn read(&self, path: &Path) -> Result<(ImageData, FitsHeader), FrameIoError> {
        Ok(crate::read_fits(path)?)
    }
    fn read_bytes(&self, bytes: &[u8]) -> Result<(ImageData, FitsHeader), FrameIoError> {
        Ok(crate::read_fits_from_bytes(bytes)?)
    }
    fn write(
        &self,
        path: &Path,
        image: &ImageData,
        header: &FitsHeader,
        _: &FrameWriteOptions,
    ) -> Result<(), FrameIoError> {
        Ok(crate::write_fits(path, image, header)?)
    }
    fn rewrite_header(
        &self,
        path: &Path,
        edit: &mut dyn FnMut(&mut FitsHeader),
    ) -> Result<(), FrameIoError> {
        let (image, mut header) = crate::read_fits(path)?;
        edit(&mut header);
        replace_file(path, |staged| Ok(crate::write_fits(staged, &image, &header)?))
    }
}

struct XisfFrames;

impl FrameCodec for XisfFrames {
    fn format(&self) -> ImageFormat {
        ImageFormat::Xisf
    }
    fn extensions(&self) -> &'static [&'static str] {
        &["xisf", "xish"]
    }
    fn probe(&self, head: &[u8]) -> bool {
        xisf::is_xisf_head(head)
    }
    fn read_header(&self, path: &Path) -> Result<FitsHeader, FrameIoError> {
        let unit = xisf::read_xisf_unit(path)?;
        Ok(xisf::header_from_image(unit.image(0)?))
    }
    fn read(&self, path: &Path) -> Result<(ImageData, FitsHeader), FrameIoError> {
        let unit = xisf::read_xisf_unit(path)?;
        let header = xisf::header_from_image(unit.image(0)?);
        Ok((unit.read_pixels(0)?, header))
    }
    fn read_bytes(&self, bytes: &[u8]) -> Result<(ImageData, FitsHeader), FrameIoError> {
        let unit = xisf::read_xisf_bytes(bytes)?;
        let header = xisf::header_from_image(unit.image(0)?);
        Ok((unit.read_pixels(0)?, header))
    }
    fn write(
        &self,
        path: &Path,
        image: &ImageData,
        header: &FitsHeader,
        options: &FrameWriteOptions,
    ) -> Result<(), FrameIoError> {
        let image_header = xisf::image_header_from_fits(header, image);
        Ok(xisf::write_images(
            path,
            &[],
            &[(image_header, image)],
            &options.xisf,
        )?)
    }
    fn read_preview(&self, path: &Path, min_side: u32) -> Result<Option<ImageData>, FrameIoError> {
        let unit = xisf::read_xisf_unit(path)?;
        let image = unit.image(0)?;
        let wanted = u64::from(min_side).min(image.width().max(image.height()));
        match image.thumbnail.as_deref() {
            Some(t) if t.width().max(t.height()) >= wanted => {
                Ok(unit.read_thumbnail()?.map(|mut preview| {
                    // Thumbnails may be 16-bit (section 11.12); previews are 8.
                    if preview.pixel_type == crate::PixelType::U16 {
                        preview.data = preview.data.as_chunks::<2>().0.iter().map(|b| b[1]).collect();
                        preview.pixel_type = crate::PixelType::U8;
                    }
                    preview
                }))
            }
            _ => Ok(None),
        }
    }
    fn rewrite_header(
        &self,
        path: &Path,
        edit: &mut dyn FnMut(&mut FitsHeader),
    ) -> Result<(), FrameIoError> {
        let mut unit = xisf::read_xisf_unit(path)?;
        let image = unit.images.first_mut().ok_or(XisfError::NoImage)?;
        let old = xisf::header_from_image(image);
        let mut new = old.clone();
        edit(&mut new);
        xisf::apply_header(image, &old, &new);
        Ok(xisf::rewrite_unit_metadata(path, &unit)?)
    }
}

/// Camera raw files: the sensor's linear color-filter mosaic. Read-only; the
/// camera's file is never changed.
struct RawFrames;

impl FrameCodec for RawFrames {
    fn format(&self) -> ImageFormat {
        ImageFormat::CameraRaw
    }
    fn extensions(&self) -> &'static [&'static str] {
        &[
            "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "pef", "dng", "orf", "rw2",
            "raw", "crw", "mrw", "erf", "3fr",
        ]
    }
    fn probe(&self, head: &[u8]) -> bool {
        camera_raw_extension(head).is_some()
    }
    fn read_header(&self, path: &Path) -> Result<FitsHeader, FrameIoError> {
        Ok(crate::read_raw_header(path)?)
    }
    fn read(&self, path: &Path) -> Result<(ImageData, FitsHeader), FrameIoError> {
        let frame = crate::read_raw_file(path)?;
        Ok((frame.to_image(), frame.header()))
    }
    fn read_bytes(&self, bytes: &[u8]) -> Result<(ImageData, FitsHeader), FrameIoError> {
        let frame = crate::read_raw_bytes(bytes)?;
        Ok((frame.to_image(), frame.header()))
    }
}

/// The extension a camera raw file whose first bytes are `head` is named
/// with, from its container's signature. `None` when the bytes are no camera
/// raw file: a JPEG, a plain TIFF, or a TIFF-based raw whose maker mark lies
/// beyond `head`.
pub fn camera_raw_extension(head: &[u8]) -> Option<&'static str> {
    const PREFIXES: &[(&[u8], &str)] = &[
        (b"FUJIFILMCCD-RAW", "raf"),
        // Olympus and OM System: TIFF with their own magic numbers.
        (b"IIRO", "orf"),
        (b"IIRS", "orf"),
        (b"MMOR", "orf"),
        // Panasonic and Leica: TIFF with magic number 0x55.
        (b"IIU\0", "rw2"),
        (b"\0MRM", "mrw"),
        (b"II\x1a\0\0\0HEAPCCDR", "crw"),
    ];
    if let Some((_, extension)) = PREFIXES.iter().find(|(prefix, _)| head.starts_with(prefix)) {
        return Some(extension);
    }
    // ISO base media with Canon's brand.
    if head.get(4..12) == Some(b"ftypcrx ".as_slice()) {
        return Some("cr3");
    }
    if head.starts_with(b"II*\0") && head.get(8..10) == Some(b"CR".as_slice()) {
        return Some("cr2");
    }
    // The other makers write classic TIFF, told from a plain one by its first
    // directory: a DNG version, or the maker's name.
    match crate::raw_exif::tiff_raw_make(head)? {
        None => Some("dng"),
        Some(make) => match Maker::from_make(&make) {
            Maker::Nikon => Some("nef"),
            Maker::Sony => Some("arw"),
            Maker::Pentax => Some("pef"),
            _ => None,
        },
    }
}

/// The formats, in the order their probes are asked.
static CODECS: &[&dyn FrameCodec] = &[&FitsFrames, &XisfFrames, &RawFrames];

/// How much of a file the probes see: enough for a TIFF-based raw's first
/// directory and the maker name it points at.
const HEAD_BYTES: usize = 4096;

fn extension_of(path: &Path) -> String {
    path.extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase()
}

fn codec_by_extension(path: &Path) -> Option<&'static dyn FrameCodec> {
    let ext = extension_of(path);
    CODECS
        .iter()
        .copied()
        .find(|c| c.extensions().contains(&ext.as_str()))
}

/// The codec for an existing file: its first bytes decide, its extension
/// when they are not a known signature.
fn codec_for_file(path: &Path) -> Result<&'static dyn FrameCodec, FrameIoError> {
    let mut head = [0u8; HEAD_BYTES];
    let mut file = std::fs::File::open(path)?;
    let mut n = 0;
    while n < head.len() {
        match file.read(&mut head[n..])? {
            0 => break,
            k => n += k,
        }
    }
    CODECS
        .iter()
        .copied()
        .find(|c| c.probe(&head[..n]))
        .or_else(|| codec_by_extension(path))
        .ok_or_else(|| FrameIoError::UnknownFormat(display_name(path)))
}

fn display_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string())
}

/// The format of an existing file.
pub fn frame_format(path: &Path) -> Result<ImageFormat, FrameIoError> {
    Ok(codec_for_file(path)?.format())
}

/// Whether a path names a file the app opens as a frame, by its extension.
pub fn is_frame_path(path: &Path) -> bool {
    codec_by_extension(path).is_some()
}

/// Every extension the app opens as a frame, lower case, without the dot.
pub fn frame_extensions() -> Vec<&'static str> {
    CODECS.iter().flat_map(|c| c.extensions().iter().copied()).collect()
}

/// The extension a new file of `format` gets.
pub fn frame_extension(format: ImageFormat) -> &'static str {
    format.codec().extensions()[0]
}

pub fn read_frame(path: &Path) -> Result<(ImageData, FitsHeader), FrameIoError> {
    codec_for_file(path)?.read(path)
}

/// A frame file held in memory (one a camera server sent), its format told
/// from its first bytes. [`FrameIoError::UnknownFormat`] when they are no
/// format the app reads.
pub fn read_frame_bytes(bytes: &[u8]) -> Result<(ImageData, FitsHeader), FrameIoError> {
    let head = &bytes[..bytes.len().min(HEAD_BYTES)];
    CODECS
        .iter()
        .find(|c| c.probe(head))
        .ok_or_else(|| FrameIoError::UnknownFormat("The frame".to_string()))?
        .read_bytes(bytes)
}

pub fn read_frame_header(path: &Path) -> Result<FitsHeader, FrameIoError> {
    codec_for_file(path)?.read_header(path)
}

/// A display-ready 8-bit preview the file stores, when it has one whose
/// longer side reaches `min_side` (or the image's own size), so a list of
/// frames need not decode every frame.
pub fn read_frame_preview(path: &Path, min_side: u32) -> Result<Option<ImageData>, FrameIoError> {
    codec_for_file(path)?.read_preview(path, min_side)
}

/// Write a frame in the format its extension names, with default choices.
pub fn write_frame(path: &Path, image: &ImageData, header: &FitsHeader) -> Result<(), FrameIoError> {
    write_frame_with(path, image, header, &FrameWriteOptions::default())
}

pub fn write_frame_with(
    path: &Path,
    image: &ImageData,
    header: &FitsHeader,
    options: &FrameWriteOptions,
) -> Result<(), FrameIoError> {
    codec_by_extension(path)
        .ok_or_else(|| FrameIoError::UnknownFormat(display_name(path)))?
        .write(path, image, header, options)
}

/// Write a frame in `format` whatever the path's extension, for a caller that
/// writes to a temporary name first.
pub fn write_frame_as(
    format: ImageFormat,
    path: &Path,
    image: &ImageData,
    header: &FitsHeader,
    options: &FrameWriteOptions,
) -> Result<(), FrameIoError> {
    format.codec().write(path, image, header, options)
}

/// Edit a file's metadata in place; its pixels are not touched.
///
/// One edit at a time: each reads the file, changes it and replaces it whole,
/// so two at once on one frame (the solved WCS and the science keywords both
/// arrive seconds after a capture) would drop one's cards or mix both files.
pub fn rewrite_frame_header(
    path: &Path,
    mut edit: impl FnMut(&mut FitsHeader),
) -> Result<(), FrameIoError> {
    static ONE_AT_A_TIME: std::sync::Mutex<()> = std::sync::Mutex::new(());
    let _held = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    codec_for_file(path)?.rewrite_header(path, &mut edit)
}

/// Write a plate solve's WCS into a frame file, keeping its pixels and
/// everything else it holds.
pub fn write_wcs_into_frame(path: &Path, wcs: &crate::SipWcs) -> Result<(), FrameIoError> {
    rewrite_frame_header(path, |header| wcs.write_to_header(header))
}

/// A frame in another format written out as FITS, for readers that take only
/// FITS (an external plate solver, a band-by-band reader). The copy is removed
/// when this is dropped.
#[derive(Debug)]
pub struct FitsCopy {
    path: std::path::PathBuf,
}

static COPY_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

impl FitsCopy {
    /// Decode `frame` and write it as FITS, with its header, into `dir`.
    pub fn new(frame: &Path, dir: &Path) -> Result<Self, FrameIoError> {
        let (image, header) = read_frame(frame)?;
        let path = dir.join(format!(
            ".skotiq-fits-copy-{}-{}.fits",
            std::process::id(),
            COPY_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        let copy = FitsCopy { path };
        crate::write_fits(&copy.path, &image, &header)?;
        Ok(copy)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for FitsCopy {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

/// Write through a sibling file and move it into place, so no reader sees a
/// half-written file. The new file is flushed to disk before it takes the
/// old one's name: the old file is the only copy of the frame.
fn replace_file(
    path: &Path,
    write: impl FnOnce(&Path) -> Result<(), FrameIoError>,
) -> Result<(), FrameIoError> {
    let name = display_name(path);
    let staged = path.with_file_name(format!(".{name}.tmp"));
    if let Err(e) = write(&staged) {
        let _ = std::fs::remove_file(&staged);
        return Err(e);
    }
    // Opened for writing: Windows flushes only a handle that may write.
    std::fs::OpenOptions::new()
        .write(true)
        .open(&staged)
        .and_then(|file| file.sync_all())
        .and_then(|()| std::fs::rename(&staged, path))
        .map_err(|e| {
            let _ = std::fs::remove_file(&staged);
            FrameIoError::Io(e)
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::PixelType;

    /// A header read tells a frame's size without decoding it, the same way
    /// in every format.
    #[test]
    fn every_format_reports_the_image_size_in_its_header() {
        let dir = std::env::temp_dir().join(format!("sk-frame-size-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for extension in ["fits", "xisf"] {
            for channels in [1, 3] {
                let path = dir.join(format!("frame-{channels}.{extension}"));
                let image = ImageData::new(7, 5, channels, PixelType::U16);
                write_frame(&path, &image, &FitsHeader::new()).unwrap();
                let header = read_frame_header(&path).unwrap();
                let size = |key: &str| header.get_int(key);
                assert_eq!(size("NAXIS"), Some(if channels > 1 { 3 } else { 2 }), "{extension}");
                assert_eq!(size("NAXIS1"), Some(7), "{extension}");
                assert_eq!(size("NAXIS2"), Some(5), "{extension}");
                assert_eq!(size("NAXIS3"), (channels > 1).then_some(3), "{extension}");
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Two edits of one frame at the same moment both land, and the pixels
    /// are the ones saved.
    #[test]
    fn two_edits_of_one_frame_at_once_both_land() {
        let dir = std::env::temp_dir().join(format!("sk-frame-edits-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let pixels: Vec<u16> = (0..640 * 480).map(|i| (i % 60000) as u16).collect();
        let image = ImageData::from_u16(640, 480, 1, &pixels);
        for extension in ["fits", "xisf"] {
            let path = dir.join(format!("frame.{extension}"));
            write_frame(&path, &image, &FitsHeader::new()).unwrap();
            for round in 0..20i64 {
                std::thread::scope(|scope| {
                    for writer in ["SK-ONE", "SK-TWO"] {
                        let path = &path;
                        scope.spawn(move || {
                            rewrite_frame_header(path, |header| {
                                // Cards of growing size, so the two files differ in layout.
                                for card in 0..=round {
                                    header.set_int(&format!("{writer}{card}"), round);
                                }
                            })
                            .unwrap()
                        });
                    }
                });
                let (read_back, header) = read_frame(&path).unwrap();
                for writer in ["SK-ONE", "SK-TWO"] {
                    assert_eq!(
                        header.get_int(&format!("{writer}{round}")),
                        Some(round),
                        "{extension} round {round}: {writer}'s cards were lost"
                    );
                }
                assert_eq!(read_back.as_u16().unwrap(), pixels, "{extension} round {round}");
            }
        }
        let _ = std::fs::remove_dir_all(&dir);
    }
}
