//! The file format the host saves captured frames in, set from the app's
//! capture settings. Manual captures and sequence frames both read it: the
//! sequencer to name its files, the frame writer to encode them.

use skotiq_imaging::{
    frame_extension, ChecksumAlgorithm, FrameWriteOptions, ImageFormat, XisfCompression,
    XisfWriteOptions,
};
use std::sync::RwLock;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct CaptureFileFormat {
    pub format: ImageFormat,
    pub options: FrameWriteOptions,
}

impl Default for CaptureFileFormat {
    fn default() -> Self {
        Self {
            format: ImageFormat::Fits,
            options: FrameWriteOptions::default(),
        }
    }
}

static CURRENT: RwLock<Option<CaptureFileFormat>> = RwLock::new(None);

pub(crate) fn current() -> CaptureFileFormat {
    CURRENT
        .read()
        .map(|guard| guard.clone().unwrap_or_default())
        .unwrap_or_default()
}

/// The extension, without the dot, of a frame saved now.
pub(crate) fn extension() -> &'static str {
    frame_extension(current().format)
}

/// Set from the capture settings: `format` is `FITS` or `XISF`,
/// `xisf_compression` a codec name such as `zstd+sh` or `none`.
pub(crate) fn set(format: &str, xisf_compression: &str, xisf_checksums: bool) -> Result<(), String> {
    let format = match format.trim().to_ascii_uppercase().as_str() {
        "FITS" => ImageFormat::Fits,
        "XISF" => ImageFormat::Xisf,
        other => return Err(format!("frames cannot be saved as \"{other}\"")),
    };
    let compression = XisfCompression::from_name(xisf_compression).map_err(|e| e.to_string())?;
    let value = CaptureFileFormat {
        format,
        options: FrameWriteOptions {
            xisf: XisfWriteOptions {
                compression,
                checksum: xisf_checksums.then_some(ChecksumAlgorithm::Sha1),
                thumbnail: true,
            },
        },
    };
    *CURRENT.write().map_err(|_| "the capture format is unavailable".to_string())? = Some(value);
    Ok(())
}
