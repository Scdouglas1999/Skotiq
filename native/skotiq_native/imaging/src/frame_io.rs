//! The one way the app reads and writes image files.
//!
//! Every consumer — capture saves, the Darkroom, calibration, the viewer,
//! plate solving, thumbnails — calls the free functions here with a path and
//! gets the app's frame: pixels as [`ImageData`] and metadata as a
//! [`FitsHeader`]. Which format a file is in is decided once, here, from its
//! first bytes (its extension when they say nothing). Each format is one
//! [`FrameCodec`]; supporting another format is one more codec in [`CODECS`].

use crate::{FitsError, FitsHeader, ImageData, ImageFormat};
use std::io::Read;
use std::path::Path;

#[derive(Debug)]
pub enum FrameIoError {
    Io(std::io::Error),
    Fits(FitsError),
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
            FrameIoError::Raw(e) => write!(f, "{e}"),
            FrameIoError::UnknownFormat(name) => write!(
                f,
                "{name} is not an image Skotiq can open (it reads FITS, XISF and camera raw files)"
            ),
            FrameIoError::WriteUnsupported(format) => write!(
                f,
                "Skotiq cannot save {} files",
                format.extension().to_uppercase()
            ),
        }
    }
}

impl std::error::Error for FrameIoError {}

impl From<std::io::Error> for FrameIoError {
    fn from(e: std::io::Error) -> Self {
        FrameIoError::Io(e)
    }
}

impl From<crate::RawError> for FrameIoError {
    fn from(e: crate::RawError) -> Self {
        FrameIoError::Raw(e.to_string())
    }
}

impl From<FitsError> for FrameIoError {
    fn from(e: FitsError) -> Self {
        FrameIoError::Fits(e)
    }
}

/// Choices a format may honor when it writes; a format ignores the ones that
/// are not its own.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FrameWriteOptions {}

pub trait FrameCodec: Sync {
    fn format(&self) -> ImageFormat;
    /// File extensions, lower case, without the dot. The first is the one new
    /// files get.
    fn extensions(&self) -> &'static [&'static str];
    /// Whether a file starting with `head` (up to 512 bytes) is this format.
    fn probe(&self, head: &[u8]) -> bool;
    /// The metadata alone, without decoding pixels.
    fn read_header(&self, path: &Path) -> Result<FitsHeader, FrameIoError>;
    fn read(&self, path: &Path) -> Result<(ImageData, FitsHeader), FrameIoError>;
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

/// Camera raw files: the sensor's linear color-filter mosaic. Read-only; the
/// camera's file is never changed.
struct RawFrames;

impl FrameCodec for RawFrames {
    fn format(&self) -> ImageFormat {
        ImageFormat::GenericRAW
    }
    fn extensions(&self) -> &'static [&'static str] {
        &[
            "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "pef", "dng", "orf", "rw2",
            "raw", "crw", "mrw", "erf", "3fr",
        ]
    }
    fn probe(&self, head: &[u8]) -> bool {
        ImageFormat::from_magic_bytes(head).is_some_and(|f| f.is_raw())
    }
    fn read_header(&self, path: &Path) -> Result<FitsHeader, FrameIoError> {
        Ok(crate::read_raw_header(path)?)
    }
    fn read(&self, path: &Path) -> Result<(ImageData, FitsHeader), FrameIoError> {
        let frame = crate::read_raw_file(path)?;
        Ok((frame.to_image(), frame.header()))
    }
}

/// The formats, in the order their probes are asked.
static CODECS: &[&dyn FrameCodec] = &[&FitsFrames, &RawFrames];

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
    let mut head = [0u8; 512];
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
    let codec = codec_for_file(path)?;
    // The raw codec covers several camera formats; name the specific one.
    if codec.format() == ImageFormat::GenericRAW {
        return Ok(ImageFormat::from_extension(&extension_of(path)).unwrap_or(ImageFormat::GenericRAW));
    }
    Ok(codec.format())
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
    CODECS
        .iter()
        .find(|c| c.format() == format)
        .map(|c| c.extensions()[0])
        .unwrap_or_else(|| format.extension())
}

pub fn read_frame(path: &Path) -> Result<(ImageData, FitsHeader), FrameIoError> {
    codec_for_file(path)?.read(path)
}

pub fn read_frame_header(path: &Path) -> Result<FitsHeader, FrameIoError> {
    codec_for_file(path)?.read_header(path)
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

/// Edit a file's metadata in place; its pixels are not touched.
pub fn rewrite_frame_header(
    path: &Path,
    mut edit: impl FnMut(&mut FitsHeader),
) -> Result<(), FrameIoError> {
    codec_for_file(path)?.rewrite_header(path, &mut edit)
}

/// Write through a sibling file and move it into place, so no reader sees a
/// half-written file.
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
    std::fs::rename(&staged, path).map_err(|e| {
        let _ = std::fs::remove_file(&staged);
        FrameIoError::Io(e)
    })
}
