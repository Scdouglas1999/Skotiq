//! Photometry cutouts use the same decoder as whole-frame reads. FITS can
//! seek directly to each region, so measuring a few stars need not decode a
//! full sensor for each frame.

use crate::fits_reader::FitsReader;
use crate::{frame_format, read_frame, FitsError, FrameIoError, ImageFormat};
use std::path::Path;

/// Square mono-frame cutouts in physical file units, concatenated in the
/// order of the zero-based centers. A cutout outside the frame is refused.
pub fn read_frame_cutouts(
    path: &Path,
    centers: &[(i32, i32)],
    half: u32,
) -> Result<Vec<f64>, FrameIoError> {
    let invalid = |message: &str| FrameIoError::Fits(FitsError::InvalidFormat(message.to_string()));
    let side = half
        .checked_mul(2)
        .and_then(|n| n.checked_add(1))
        .ok_or_else(|| invalid("cutout size is too large"))?;
    let origins = |width: u32, height: u32| -> Result<Vec<(u32, u32)>, FrameIoError> {
        centers
            .iter()
            .map(|&(x, y)| {
                let (x, y, half) = (i64::from(x), i64::from(y), i64::from(half));
                if x - half < 0
                    || y - half < 0
                    || x + half >= i64::from(width)
                    || y + half >= i64::from(height)
                {
                    return Err(invalid("a cutout leaves the image"));
                }
                Ok(((x - half) as u32, (y - half) as u32))
            })
            .collect()
    };
    if frame_format(path)? == ImageFormat::Fits {
        let mut reader = FitsReader::open(std::io::BufReader::new(std::fs::File::open(path)?))?;
        let shape = *reader
            .shape()
            .ok_or_else(|| invalid("frame has no image"))?;
        if shape.planes != 1 {
            return Err(invalid("cutouts are taken from single-channel frames"));
        }
        let mut out = Vec::new();
        for (x, y) in origins(shape.width, shape.height)? {
            out.extend(reader.read_region(x, y, side, side)?);
        }
        return Ok(out);
    }
    let (image, _) = read_frame(path)?;
    if image.channels != 1 {
        return Err(invalid("cutouts are taken from single-channel frames"));
    }
    let size = image.pixel_type.byte_size();
    let mut out = Vec::new();
    for (x, y) in origins(image.width, image.height)? {
        for row in y..y + side {
            for col in x..x + side {
                let at = (row as usize * image.width as usize + col as usize) * size;
                out.push(crate::samples::sample_from_le(
                    &image.data[at..at + size],
                    image.pixel_type,
                ));
            }
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{write_frame, FitsHeader, ImageData, PixelType};

    #[test]
    fn cutouts_keep_float_precision_and_row_order_in_fits_and_xisf() {
        let dir = tempfile::tempdir().unwrap();
        let mut image = ImageData::new(9, 7, 1, PixelType::F64);
        image.data = (0..63)
            .flat_map(|i| (i as f64 - 10.125).to_le_bytes())
            .collect();
        let expected: Vec<f64> = [
            11, 12, 13, 20, 21, 22, 29, 30, 31, 40, 41, 42, 49, 50, 51, 58, 59, 60,
        ]
        .into_iter()
        .map(|i| i as f64 - 10.125)
        .collect();
        for ext in ["fits", "xisf"] {
            let path = dir.path().join(format!("frame.{ext}"));
            write_frame(&path, &image, &FitsHeader::new()).unwrap();
            assert_eq!(
                read_frame_cutouts(&path, &[(3, 2), (5, 5)], 1).unwrap(),
                expected
            );
            assert!(read_frame_cutouts(&path, &[(0, 0)], 1).is_err());
            assert_eq!(
                read_frame_cutouts(&path, &[], 1).unwrap(),
                Vec::<f64>::new()
            );
        }
    }

    #[test]
    fn fits_cutouts_apply_bzero_bscale_and_reject_truncated_pixels() {
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("scaled.fits");
        let mut file = std::fs::File::create(&path).unwrap();
        let mut header = String::new();
        for (key, value) in [
            ("SIMPLE", "T"),
            ("BITPIX", "16"),
            ("NAXIS", "2"),
            ("NAXIS1", "3"),
            ("NAXIS2", "3"),
            ("BZERO", "32768"),
            ("BSCALE", "0.5"),
        ] {
            header.push_str(&format!("{:<80}", format!("{key:<8}= {value:>20}")));
        }
        header.push_str(&format!("{:<80}", "END"));
        header.push_str(&" ".repeat(2880 - header.len()));
        file.write_all(header.as_bytes()).unwrap();
        for i in -4i16..5 {
            file.write_all(&i.to_be_bytes()).unwrap();
        }
        drop(file);
        assert_eq!(
            read_frame_cutouts(&path, &[(1, 1)], 1).unwrap(),
            (-4..5)
                .map(|i| 32768.0 + 0.5 * f64::from(i))
                .collect::<Vec<_>>()
        );
        std::fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .set_len(2890)
            .unwrap();
        assert!(read_frame_cutouts(&path, &[(1, 1)], 1).is_err());
    }
}
