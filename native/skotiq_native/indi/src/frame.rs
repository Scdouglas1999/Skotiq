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

/// Parse the integer value out of a fixed-format 80-byte FITS header card.
///
/// FITS mandates `KEYWORD = value / comment` with the value right-justified in
/// bytes 10..30, so splitting on `=` and taking everything before any `/` is
/// sufficient: no full FITS parser is needed for NAXIS1 and NAXIS2. `None` for
/// a malformed card, so the caller falls back rather than trusting a guess.
fn fits_card_u32(card: &[u8]) -> Option<u32> {
    let text = std::str::from_utf8(card).ok()?;
    let after_eq = text.split_once('=')?.1;
    let value = after_eq.split('/').next()?.trim();
    value.parse::<u32>().ok()
}

/// The pixels of a BLOB. `sensor` is the size to assume for a BLOB that does
/// not say its own.
///
/// A FITS BLOB carries the frame's true geometry in NAXIS1 and NAXIS2, and
/// those win: `CCD_INFO` is the full unbinned sensor, so at bin 2 the CCD
/// simulator's `CCD_INFO` says 1280x1024 while its BLOB is 640x512. Only the
/// FITS block padding past width x height is dropped; a short buffer stays
/// short so the size check downstream still catches it.
pub fn decode_frame(data: &[u8], sensor: (u32, u32)) -> IndiFrame {
    let mut fits_size = None;
    let mut pixels: Vec<u16> = if data.starts_with(b"SIMPLE") {
        let mut offset = 0usize;
        let (mut naxis1, mut naxis2) = (None, None);
        for card in data.chunks(80) {
            offset += 80;
            if card.starts_with(b"NAXIS1") {
                naxis1 = fits_card_u32(card);
            } else if card.starts_with(b"NAXIS2") {
                naxis2 = fits_card_u32(card);
            }
            if card.starts_with(b"END") {
                offset = offset.div_ceil(2880) * 2880;
                break;
            }
        }
        if let (Some(width), Some(height)) = (naxis1, naxis2) {
            if width > 0 && height > 0 {
                fits_size = Some((width, height));
            }
        }
        data[offset.min(data.len())..]
            .as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u16::from_be_bytes(*pair))
            .collect()
    } else {
        data.as_chunks::<2>()
            .0
            .iter()
            .map(|pair| u16::from_le_bytes(*pair))
            .collect()
    };
    let (width, height) = fits_size.unwrap_or(sensor);
    pixels.truncate((width as usize) * (height as usize));
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
            client.clear_blob(self.device_name(), element, element).await;
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

    /// The two cards are the 80-byte headers of a BLOB captured off
    /// `indi_simulator_ccd` at 2x2 binning, where CCD_INFO advertised the
    /// unbinned 1280x1024 while the frame was 640x512.
    #[test]
    fn naxis_cards_of_a_real_blob_are_read() {
        let naxis1 =
            b"NAXIS1  =                  640 / length of data axis 1                          ";
        let naxis2 =
            b"NAXIS2  =                  512 / length of data axis 2                          ";
        assert_eq!(fits_card_u32(naxis1), Some(640));
        assert_eq!(fits_card_u32(naxis2), Some(512));
        assert_eq!(fits_card_u32(b"NAXIS1  =                 4144"), Some(4144));
    }

    #[test]
    fn a_card_that_cannot_be_trusted_is_refused() {
        for card in [
            &b"COMMENT no equals sign here"[..],
            b"NAXIS1  =                    T / bad",
            b"NAXIS1  =                 6.40 / float",
            b"NAXIS1  =                   -1 / negative",
        ] {
            assert_eq!(fits_card_u32(card), None);
        }
    }

    fn card(text: &str) -> Vec<u8> {
        format!("{text:<80}").into_bytes()
    }

    #[test]
    fn a_fits_frame_has_its_own_size_and_big_endian_pixels() {
        let mut blob = Vec::new();
        for text in [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    2 / length of data axis 1",
            "NAXIS2  =                    1 / length of data axis 2",
            "END",
        ] {
            blob.extend(card(text));
        }
        blob.resize(2880, b' ');
        blob.extend([0x01, 0x02, 0x03, 0x04]);
        blob.resize(2880 * 2, 0);
        let frame = decode_frame(&blob, (1280, 1024));
        assert_eq!((frame.width, frame.height), (2, 1));
        assert_eq!(frame.pixels, vec![0x0102, 0x0304]);
    }

    #[test]
    fn a_raw_frame_takes_the_sensor_size_and_little_endian_pixels() {
        let frame = decode_frame(&[1, 0, 2, 0, 3, 0, 4, 0], (2, 2));
        assert_eq!((frame.width, frame.height), (2, 2));
        assert_eq!(frame.pixels, vec![1, 2, 3, 4]);
        let short = decode_frame(&[1, 0], (2, 2));
        assert_eq!(short.pixels.len(), 1, "a short buffer stays short");
    }
}
