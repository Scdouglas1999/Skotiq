//! An open FITS image: the header parsed and the data unit within reach.
//!
//! [`FitsReader`] is the one place FITS samples are decoded. It serves the
//! whole-image read ([`FitsReader::into_image`], which is what
//! [`crate::read_fits`] does) and band reads of rows as physical values
//! ([`FitsReader::read_rows`]) for callers that must not hold a whole stack of
//! frames in memory.

use crate::fits::{geometry_from_header, read_header_measured, FitsError, FitsHeader};
use crate::{ImageData, PixelType};
use rayon::prelude::*;
use std::io::{Read, Seek, SeekFrom};

/// How the data unit stores a sample: `physical = stored · BSCALE + BZERO`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SampleEncoding {
    /// `BITPIX`: 8, 16, 32 (integers), −32, −64 (IEEE floats).
    pub bitpix: i32,
    /// `BZERO`, 0 when the card is absent (FITS 4.4.2.5).
    pub bzero: f64,
    /// `BSCALE`, 1 when the card is absent.
    pub bscale: f64,
}

impl SampleEncoding {
    fn from_header(header: &FitsHeader) -> Result<Self, FitsError> {
        let bitpix = header
            .get_int("BITPIX")
            .ok_or_else(|| FitsError::MissingKeyword("BITPIX".to_string()))?;
        Ok(Self {
            bitpix: bitpix as i32,
            bzero: header.get_float("BZERO").unwrap_or(0.0),
            bscale: header.get_float("BSCALE").unwrap_or(1.0),
        })
    }

    /// Bytes one stored sample occupies.
    pub fn bytes_per_sample(&self) -> usize {
        (self.bitpix.unsigned_abs() / 8) as usize
    }

    /// Decode big-endian stored samples to physical values, appending to `out`.
    fn decode_physical(&self, stored: &[u8], out: &mut Vec<f64>) {
        let (bzero, bscale) = (self.bzero, self.bscale);
        let physical = |stored: f64| stored * bscale + bzero;
        match self.bitpix {
            8 => out.extend(stored.iter().map(|&v| physical(f64::from(v)))),
            16 => out.extend(
                stored
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|c| physical(f64::from(i16::from_be_bytes(*c)))),
            ),
            32 => out.extend(
                stored
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| physical(f64::from(i32::from_be_bytes(*c)))),
            ),
            -32 => out.extend(
                stored
                    .as_chunks::<4>()
                    .0
                    .iter()
                    .map(|c| physical(f64::from(f32::from_be_bytes(*c)))),
            ),
            _ => out.extend(
                stored
                    .as_chunks::<8>()
                    .0
                    .iter()
                    .map(|c| physical(f64::from_be_bytes(*c))),
            ),
        }
    }

    /// Turn big-endian stored samples into the little-endian samples of the
    /// [`PixelType`] this `BITPIX` reads as, in place.
    ///
    /// Integer types have no signed form in [`PixelType`], so a physical value
    /// outside the unsigned range is held at its end. That is what cameras
    /// need (unsigned 16-bit is stored signed with `BZERO = 32768`); data that
    /// can go negative is written as float and kept exactly.
    fn decode_in_place(&self, samples: &mut [u8]) {
        let (bzero, bscale) = (self.bzero, self.bscale);
        match self.bitpix {
            8 => {
                if bzero != 0.0 || bscale != 1.0 {
                    samples.par_iter_mut().for_each(|v| {
                        *v = ((f64::from(*v) * bscale + bzero) as i32).clamp(0, 255) as u8;
                    });
                }
            }
            16 => {
                // A non-unit BSCALE must take the general path or the scaling
                // is dropped.
                let offset_only = bzero == 32768.0 && bscale == 1.0;
                samples.par_chunks_mut(2 << 14).for_each(|chunk| {
                    for sample in chunk.as_chunks_mut::<2>().0 {
                        let stored = i16::from_be_bytes(*sample);
                        let value = if offset_only {
                            (i32::from(stored) + 32768).clamp(0, 65535) as u16
                        } else {
                            (f64::from(stored) * bscale + bzero).clamp(0.0, 65535.0) as u16
                        };
                        *sample = value.to_le_bytes();
                    }
                });
            }
            32 => samples.par_chunks_mut(4 << 14).for_each(|chunk| {
                for sample in chunk.as_chunks_mut::<4>().0 {
                    let stored = i32::from_be_bytes(*sample);
                    let value =
                        (f64::from(stored) * bscale + bzero).clamp(0.0, f64::from(u32::MAX)) as u32;
                    *sample = value.to_le_bytes();
                }
            }),
            -32 => samples.par_chunks_mut(4 << 14).for_each(|chunk| {
                for sample in chunk.as_chunks_mut::<4>().0 {
                    let stored = f32::from_be_bytes(*sample);
                    *sample = (stored * bscale as f32 + bzero as f32).to_le_bytes();
                }
            }),
            _ => samples.par_chunks_mut(8 << 14).for_each(|chunk| {
                for sample in chunk.as_chunks_mut::<8>().0 {
                    let stored = f64::from_be_bytes(*sample);
                    *sample = (stored * bscale + bzero).to_le_bytes();
                }
            }),
        }
    }
}

/// The pixel grid of a FITS image and how its samples are stored.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FitsShape {
    pub width: u32,
    pub height: u32,
    /// `NAXIS3`, 1 for a two-dimensional image.
    pub planes: u32,
    /// The [`PixelType`] a whole-image read yields.
    pub pixel_type: PixelType,
    pub encoding: SampleEncoding,
}

impl FitsShape {
    fn sample_count(&self) -> Result<usize, FitsError> {
        let product = u64::from(self.width)
            .checked_mul(u64::from(self.height))
            .and_then(|n| n.checked_mul(u64::from(self.planes)))
            .ok_or_else(|| {
                FitsError::InvalidFormat(format!(
                    "FITS NAXIS dimensions overflow: {}*{}*{}",
                    self.width, self.height, self.planes
                ))
            })?;
        usize::try_from(product).map_err(|_| {
            FitsError::InvalidFormat(format!("FITS pixel count {} exceeds usize::MAX", product))
        })
    }
}

/// A FITS primary HDU with its header read and its data unit not yet decoded.
pub struct FitsReader<R> {
    reader: R,
    header: FitsHeader,
    data_offset: u64,
    /// `None` for a header-only HDU (`NAXIS = 0`).
    shape: Option<FitsShape>,
}

impl<R: Read> FitsReader<R> {
    /// Read the header of the HDU `reader` is positioned at. Fails on a
    /// malformed header, a missing `BITPIX`, an unsupported `BITPIX` or more
    /// than three axes.
    pub fn open(mut reader: R) -> Result<Self, FitsError> {
        let (header, data_offset) = read_header_measured(&mut reader)?;
        let encoding = SampleEncoding::from_header(&header)?;
        let shape = if header.get_int("NAXIS") == Some(0) {
            None
        } else {
            let (width, height, planes, pixel_type) = geometry_from_header(&header)?;
            Some(FitsShape {
                width,
                height,
                planes,
                pixel_type,
                encoding,
            })
        };
        Ok(Self {
            reader,
            header,
            data_offset,
            shape,
        })
    }

    /// The header as the file holds it, `BZERO`/`BSCALE` included.
    pub fn header(&self) -> &FitsHeader {
        &self.header
    }

    /// The image's grid and encoding; `None` for a header-only HDU.
    pub fn shape(&self) -> Option<&FitsShape> {
        self.shape.as_ref()
    }

    /// Byte offset of the data unit from where the header began.
    pub fn data_offset(&self) -> u64 {
        self.data_offset
    }

    /// Decode the whole image. The reader must still be at the data unit, so
    /// this is for a reader no rows were read from.
    ///
    /// The returned header has `BZERO`/`BSCALE` removed: they describe the
    /// stored encoding, which is now folded into the samples, and writing them
    /// back would scale the data twice. A header-only HDU yields an empty
    /// image.
    pub fn into_image(mut self) -> Result<(ImageData, FitsHeader), FitsError> {
        let Some(shape) = self.shape else {
            return Ok((ImageData::new(0, 0, 1, PixelType::U16), self.header));
        };
        let size = shape.sample_count()?;
        let bytes = size
            .checked_mul(shape.encoding.bytes_per_sample())
            .ok_or_else(|| {
                FitsError::InvalidFormat(format!("FITS buffer overflow for {} pixels", size))
            })?;
        let mut data = vec![0u8; bytes];
        self.reader.read_exact(&mut data)?;
        shape.encoding.decode_in_place(&mut data);

        let mut header = self.header;
        let data = if shape.planes > 1 {
            let channels = shape.planes as usize;
            let pixels = (shape.width as usize) * (shape.height as usize);
            let layout = crate::fits_layout::layout_from_header(&header).unwrap_or_else(|| {
                crate::fits_layout::detect_layout(
                    shape.width as usize,
                    shape.height as usize,
                    channels,
                    |k| crate::fits_layout::le_sample(&data, shape.pixel_type, k),
                )
            });
            match layout {
                crate::fits_layout::PlaneLayout::Planar => {
                    crate::fits_layout::planar_to_interleaved(
                        &data,
                        pixels,
                        channels,
                        shape.pixel_type.byte_size(),
                    )
                }
                crate::fits_layout::PlaneLayout::Interleaved => data,
            }
        } else {
            data
        };
        header.remove(crate::fits_layout::LAYOUT_KEYWORD);
        header.remove("BZERO");
        header.remove("BSCALE");

        Ok((
            ImageData {
                width: shape.width,
                height: shape.height,
                channels: shape.planes,
                pixel_type: shape.pixel_type,
                data,
            },
            header,
        ))
    }
}

impl<R: Read + Seek> FitsReader<R> {
    /// Decode rows `row..row + rows` of the first plane into `out` as physical
    /// values (`stored · BSCALE + BZERO`, unclamped), replacing its contents.
    /// `scratch` is the caller's reusable byte buffer.
    ///
    /// The reader must have been opened at the start of the file: rows are
    /// found by seeking to [`Self::data_offset`].
    pub fn read_rows(
        &mut self,
        row: usize,
        rows: usize,
        scratch: &mut Vec<u8>,
        out: &mut Vec<f64>,
    ) -> Result<(), FitsError> {
        let shape = self
            .shape
            .ok_or_else(|| FitsError::InvalidFormat("No image data in FITS file".to_string()))?;
        if row.saturating_add(rows) > shape.height as usize {
            return Err(FitsError::InvalidFormat(format!(
                "rows {row}..{} lie outside an image {} rows high",
                row.saturating_add(rows),
                shape.height
            )));
        }
        let row_bytes = shape.width as usize * shape.encoding.bytes_per_sample();
        scratch.resize(rows * row_bytes, 0);
        self.reader
            .seek(SeekFrom::Start(self.data_offset + (row * row_bytes) as u64))?;
        self.reader.read_exact(scratch)?;
        out.clear();
        out.reserve(rows * shape.width as usize);
        shape.encoding.decode_physical(scratch, out);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fits::write_fits;
    use std::io::Cursor;

    fn fits_bytes(image: &ImageData, header: &FitsHeader) -> Vec<u8> {
        let path = std::env::temp_dir().join(format!(
            "skotiq-fits-reader-{}-{:?}.fits",
            std::process::id(),
            std::thread::current().id()
        ));
        write_fits(&path, image, header).expect("writes");
        let bytes = std::fs::read(&path).expect("reads back");
        let _ = std::fs::remove_file(&path);
        bytes
    }

    #[test]
    fn rows_read_as_physical_values_match_the_whole_image() {
        let (w, h) = (7u32, 5u32);
        let u16_px: Vec<u16> = (0..w * h).map(|i| (i * 1871 % 65536) as u16).collect();
        let f32_px: Vec<f32> = (0..w * h).map(|i| i as f32 * 0.37 - 4.0).collect();
        for image in [
            ImageData::from_u16(w, h, 1, &u16_px),
            ImageData::from_f32(w, h, 1, &f32_px),
        ] {
            let bytes = fits_bytes(&image, &FitsHeader::new());
            let whole = image.samples_f64();

            let mut reader = FitsReader::open(Cursor::new(&bytes)).expect("opens");
            assert_eq!(reader.data_offset() % 2880, 0);
            let shape = *reader.shape().expect("an image");
            assert_eq!((shape.width, shape.height, shape.planes), (w, h, 1));
            assert_eq!(shape.pixel_type, image.pixel_type);

            let (mut scratch, mut rows) = (Vec::new(), Vec::new());
            reader
                .read_rows(1, 3, &mut scratch, &mut rows)
                .expect("rows");
            assert_eq!(rows, &whole[w as usize..4 * w as usize]);
            reader
                .read_rows(0, 1, &mut scratch, &mut rows)
                .expect("first row");
            assert_eq!(rows, &whole[..w as usize]);
            assert!(reader.read_rows(4, 2, &mut scratch, &mut rows).is_err());

            let (decoded, header) = FitsReader::open(Cursor::new(&bytes))
                .expect("opens")
                .into_image()
                .expect("decodes");
            assert_eq!(decoded.data, image.data);
            assert!(header.get("BZERO").is_none() && header.get("BSCALE").is_none());
        }
    }

    #[test]
    fn a_scaled_signed_file_decodes_through_bscale_and_bzero() {
        // Two stored samples, -2 and 3, under BSCALE 2 / BZERO 10.
        let mut bytes = Vec::new();
        for card in [
            "SIMPLE  =                    T",
            "BITPIX  =                   16",
            "NAXIS   =                    2",
            "NAXIS1  =                    2",
            "NAXIS2  =                    1",
            "BSCALE  =                  2.0",
            "BZERO   =                 10.0",
            "END",
        ] {
            bytes.extend_from_slice(format!("{card:<80}").as_bytes());
        }
        bytes.resize(2880, b' ');
        bytes.extend_from_slice(&(-2i16).to_be_bytes());
        bytes.extend_from_slice(&3i16.to_be_bytes());
        bytes.resize(5760, 0);

        let mut reader = FitsReader::open(Cursor::new(&bytes)).expect("opens");
        assert_eq!(reader.shape().unwrap().encoding.bscale, 2.0);
        let (mut scratch, mut rows) = (Vec::new(), Vec::new());
        reader
            .read_rows(0, 1, &mut scratch, &mut rows)
            .expect("row");
        assert_eq!(rows, [6.0, 16.0]);

        let (image, _) = FitsReader::open(Cursor::new(&bytes))
            .unwrap()
            .into_image()
            .unwrap();
        assert_eq!(image.as_u16().unwrap(), [6, 16]);
    }

    #[test]
    fn a_header_only_file_has_no_shape_and_an_empty_image() {
        let mut bytes = Vec::new();
        for card in [
            "SIMPLE  =                    T",
            "BITPIX  =                    8",
            "NAXIS   =                    0",
            "END",
        ] {
            bytes.extend_from_slice(format!("{card:<80}").as_bytes());
        }
        bytes.resize(2880, b' ');
        let mut reader = FitsReader::open(Cursor::new(&bytes)).expect("opens");
        assert!(reader.shape().is_none());
        assert!(reader
            .read_rows(0, 1, &mut Vec::new(), &mut Vec::new())
            .is_err());
        let (image, _) = FitsReader::open(Cursor::new(&bytes))
            .unwrap()
            .into_image()
            .unwrap();
        assert!(image.is_empty());
    }
}
