//! The frame an INDI camera sends: waiting for it and reading its pixels.

use crate::protocol::names::{CCD1, CCD2};
use crate::{IndiCamera, IndiError, IndiEvent, IndiResult};
use std::time::Duration;

/// How long a finished exposure's frame may take to arrive.
const FRAME_WAIT: Duration = Duration::from_secs(30);

/// A frame as 16-bit pixels, row by row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct IndiFrame {
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u16>,
}

/// The pixels of a BLOB. `sensor` is the size of a BLOB that carries only
/// pixels (`FORMAT_NATIVE`).
///
/// A FITS or XISF BLOB is read by the app's frame reader, so its own header
/// decides the geometry, the sample type and the scaling: INDI writes 16-bit
/// frames as cfitsio's unsigned shorts, signed samples with `BZERO = 32768`,
/// and `CCD_INFO` is the full unbinned sensor (at bin 2 the CCD simulator's
/// says 1280x1024 while its BLOB is 640x512). Samples come out as 16-bit
/// levels, as every camera's frames do (an 8-bit sample `v` is `257 v`).
///
/// A BLOB the server compressed with zlib (`.fits.z`, `.bin.z`) is inflated
/// first. A native BLOB is the sensor's samples, little-endian, 8 or 16 bits
/// by its length; a short one stays short so the size check downstream
/// catches it.
pub fn decode_frame(data: &[u8], sensor: (u32, u32)) -> IndiResult<IndiFrame> {
    let inflated = inflate(data);
    let data = inflated.as_deref().unwrap_or(data);
    match skotiq_imaging::read_frame_bytes(data) {
        Ok((image, _)) => frame_of(&image),
        Err(skotiq_imaging::FrameIoError::UnknownFormat(_)) => Ok(native_frame(data, sensor)),
        Err(e) => Err(IndiError::BlobFormatError {
            format: format_name(data).to_string(),
            message: format!("The camera's frame could not be read: {e}"),
        }),
    }
}

fn format_name(data: &[u8]) -> &'static str {
    if data.starts_with(b"SIMPLE") {
        "FITS"
    } else if data.starts_with(skotiq_imaging::xisf::XISF_SIGNATURE) {
        "XISF"
    } else {
        "native"
    }
}

/// The inflated bytes of a zlib stream, or `None` when `data` is not one.
/// A stream whose Adler-32 checks out is not a native frame's pixels by
/// chance.
fn inflate(data: &[u8]) -> Option<Vec<u8>> {
    let header = u16::from_be_bytes([*data.first()?, *data.get(1)?]);
    if data[0] & 0x0F != 8 || header % 31 != 0 {
        return None;
    }
    let mut out = Vec::new();
    std::io::Read::read_to_end(&mut flate2::read::ZlibDecoder::new(data), &mut out).ok()?;
    Some(out)
}

fn frame_of(image: &skotiq_imaging::ImageData) -> IndiResult<IndiFrame> {
    let refused = |message: String| IndiError::BlobFormatError {
        format: "FITS".to_string(),
        message,
    };
    if image.is_empty() {
        // fpack's tile compression (`.fits.fz`) leaves the primary image empty.
        return Err(refused(
            "The camera sent a frame with no image in it. If its INDI compression is on, \
             turn it off: Skotiq reads uncompressed and zlib-compressed frames."
                .to_string(),
        ));
    }
    if image.channels != 1 {
        return Err(refused(format!(
            "The camera sent a {}-plane color frame; Skotiq reads one-plane (mono or Bayer) \
             frames from INDI cameras.",
            image.channels
        )));
    }
    Ok(IndiFrame {
        width: image.width,
        height: image.height,
        pixels: image.adu_levels(),
    })
}

fn native_frame(data: &[u8], (width, height): (u32, u32)) -> IndiFrame {
    let count = (width as usize) * (height as usize);
    let mut pixels: Vec<u16> = if data.len() == count {
        data.iter().map(|&v| u16::from(v) * 257).collect()
    } else {
        data.as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u16::from_le_bytes(*pair))
            .collect()
    };
    pixels.truncate(count);
    IndiFrame {
        width,
        height,
        pixels,
    }
}

impl IndiCamera {
    /// Forgets a frame kept from an earlier exposure, so [`Self::read_frame`]
    /// cannot return it for the next one.
    pub async fn forget_frame(&self) {
        let client = self.client().read().await;
        for element in [CCD1, CCD2] {
            client
                .clear_blob(self.device_name(), element, element)
                .await;
        }
    }

    async fn take_kept_frame(&self) -> Option<Vec<u8>> {
        let client = self.client().read().await;
        match client.take_blob(self.device_name(), CCD1, CCD1).await {
            Some(data) => Some(data),
            None => client.take_blob(self.device_name(), CCD2, CCD2).await,
        }
    }

    /// The raw frame of the exposure that has just ended.
    ///
    /// The driver sends the frame before it reports the exposure done, so
    /// the frame is usually here already, kept by the connection's reader;
    /// otherwise it comes as an event. The kept frame is looked for on every
    /// turn: the events of the other devices on the connection (a tracking
    /// mount sends one a second) would otherwise keep the wait from ever
    /// getting to it.
    pub async fn read_frame(&self) -> IndiResult<Vec<u8>> {
        let mut events = self.client().read().await.subscribe();
        // A refused enableBLOB means no image can arrive on this connection,
        // and the only other sign of it is the timeout below.
        if let Err(e) = self.enable_blob().await {
            tracing::warn!(
                "Failed to enable INDI BLOB transfer for {}: {}. No image can be delivered \
                 on this connection until it succeeds.",
                self.device_name(),
                e
            );
        }
        let started = std::time::Instant::now();
        loop {
            if let Some(data) = self.take_kept_frame().await {
                return Ok(data);
            }
            if started.elapsed() > FRAME_WAIT {
                return Err(IndiError::Incomplete(
                    "Timeout waiting for INDI image BLOB".to_string(),
                ));
            }
            match tokio::time::timeout(Duration::from_secs(1), events.recv()).await {
                Ok(Ok(IndiEvent::BlobReceived {
                    device,
                    element,
                    data,
                    ..
                })) if device == self.device_name() && (element == CCD1 || element == CCD2) => {
                    // The reader kept a copy; a later exposure must not find
                    // this frame there.
                    self.forget_frame().await;
                    return Ok(data);
                }
                Ok(Ok(_)) | Err(_) => {}
                // Events were dropped because this receiver fell behind; the
                // kept frame is read on the next turn.
                Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => {}
                Ok(Err(tokio::sync::broadcast::error::RecvError::Closed)) => {
                    return Err(IndiError::ChannelClosed(
                        "INDI event channel closed".to_string(),
                    ));
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(text: &str) -> Vec<u8> {
        format!("{text:<80}").into_bytes()
    }

    /// A FITS file as cfitsio lays one out: the cards, padding to 2880, the
    /// big-endian samples, padding.
    fn fits(bitpix: i32, size: (u32, u32), extra: &[&str], samples: &[u8]) -> Vec<u8> {
        let mut blob = Vec::new();
        for text in [
            "SIMPLE  =                    T".to_string(),
            format!("BITPIX  = {bitpix:>20}"),
            "NAXIS   =                    2".to_string(),
            format!("NAXIS1  = {:>20} / length of data axis 1", size.0),
            format!("NAXIS2  = {:>20} / length of data axis 2", size.1),
        ]
        .iter()
        .map(String::as_str)
        .chain(extra.iter().copied())
        .chain(["END"])
        {
            blob.extend(card(text));
        }
        blob.resize(blob.len().div_ceil(2880) * 2880, b' ');
        blob.extend(samples);
        blob.resize(blob.len().div_ceil(2880) * 2880, 0);
        blob
    }

    /// INDI writes 16-bit frames as `USHORT_IMG`: cfitsio stores `v - 32768`
    /// as a signed short and says `BZERO = 32768`.
    fn indi_u16(size: (u32, u32), levels: &[u16]) -> Vec<u8> {
        let samples: Vec<u8> = levels
            .iter()
            .flat_map(|&v| ((i32::from(v) - 32768) as i16).to_be_bytes())
            .collect();
        fits(
            16,
            size,
            &[
                "BZERO   =                32768 / offset data range to that of unsigned short",
                "BSCALE  =                    1 / default scaling factor",
            ],
            &samples,
        )
    }

    #[test]
    fn an_indi_16_bit_frame_reads_its_own_levels() {
        let levels = [0, 5, 1000, 32768, 65535, 9];
        let frame = decode_frame(&indi_u16((3, 2), &levels), (1280, 1024)).unwrap();
        assert_eq!(
            (frame.width, frame.height),
            (3, 2),
            "the BLOB's own size wins"
        );
        assert_eq!(frame.pixels, levels);
    }

    #[test]
    fn an_8_and_a_32_bit_frame_come_out_as_16_bit_levels() {
        let frame = decode_frame(&fits(8, (2, 1), &[], &[0, 255]), (2, 1)).unwrap();
        assert_eq!(frame.pixels, [0, 65535]);

        // ULONG_IMG: signed longs with BZERO 2^31.
        let samples: Vec<u8> = [0u32, u32::MAX, 1 << 31]
            .iter()
            .flat_map(|&v| ((i64::from(v) - (1 << 31)) as i32).to_be_bytes())
            .collect();
        let frame = decode_frame(
            &fits(32, (3, 1), &["BZERO   =           2147483648"], &samples),
            (3, 1),
        )
        .unwrap();
        assert_eq!(frame.pixels, [0, 65535, 32768]);
    }

    #[test]
    fn a_zlib_compressed_frame_reads_like_the_plain_one() {
        use std::io::Write;
        let plain = indi_u16((2, 2), &[10, 20, 30, 40]);
        let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::best());
        encoder.write_all(&plain).unwrap();
        let compressed = encoder.finish().unwrap();
        assert_eq!(
            decode_frame(&compressed, (9, 9)).unwrap(),
            decode_frame(&plain, (9, 9)).unwrap()
        );
    }

    #[test]
    fn an_xisf_frame_is_read() {
        let dir = std::env::temp_dir().join(format!("indi-xisf-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("frame.xisf");
        let image = skotiq_imaging::ImageData::from_u16(2, 2, 1, &[1, 2, 3, 60000]);
        skotiq_imaging::write_frame(&path, &image, &skotiq_imaging::FitsHeader::new()).unwrap();
        let blob = std::fs::read(&path).unwrap();
        std::fs::remove_dir_all(&dir).unwrap();
        let frame = decode_frame(&blob, (9, 9)).unwrap();
        assert_eq!((frame.width, frame.height), (2, 2));
        assert_eq!(frame.pixels, [1, 2, 3, 60000]);
    }

    #[test]
    fn frames_that_cannot_be_shown_are_refused_with_the_reason() {
        // fpack leaves the primary image empty and the tiles in an extension.
        let mut fpacked = Vec::new();
        for text in [
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "EXTEND  =                    T",
            "END",
        ] {
            fpacked.extend(card(text));
        }
        fpacked.resize(2880, b' ');
        let refused = decode_frame(&fpacked, (2, 2)).unwrap_err().to_string();
        assert!(refused.contains("compression"), "{refused}");

        let mut cube = Vec::new();
        for text in [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    3",
            "NAXIS1  =                    1",
            "NAXIS2  =                    1",
            "NAXIS3  =                    3",
            "END",
        ] {
            cube.extend(card(text));
        }
        cube.resize(2880, b' ');
        cube.resize(2 * 2880, 0);
        let refused = decode_frame(&cube, (1, 1)).unwrap_err().to_string();
        assert!(refused.contains("3-plane"), "{refused}");
    }

    #[test]
    fn a_native_frame_takes_the_sensor_size() {
        let frame = decode_frame(&[1, 0, 2, 0, 3, 0, 4, 0], (2, 2)).unwrap();
        assert_eq!((frame.width, frame.height), (2, 2));
        assert_eq!(frame.pixels, [1, 2, 3, 4]);
        let eight_bit = decode_frame(&[0, 1, 2, 255], (2, 2)).unwrap();
        assert_eq!(eight_bit.pixels, [0, 257, 514, 65535]);
        let short = decode_frame(&[1, 0, 2, 0, 3, 0], (2, 2)).unwrap();
        assert_eq!(short.pixels.len(), 3, "a short buffer stays short");
    }
}
