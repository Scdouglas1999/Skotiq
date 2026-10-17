use super::image_data_to_linear_f64;
use skotiq_imaging::{ImageData, PixelType};

/// The star field survives a write_fits -> read_fits -> decode round trip.
/// A big-endian decode passes none of these: 440 ADU reads back as 47105 and
/// the 40614 ADU star as 42654, inverting the contrast so star detection
/// finds nothing.
#[test]
fn round_trips_u16_fits_pixels_through_the_linear_decoder() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("roundtrip.fits");

    let mut image = ImageData::new(4, 4, 1, PixelType::U16);
    // A sky background with one bright star, i.e. the values from the
    // Stack & Share repro.
    let samples: [u16; 16] = [
        440, 441, 439, 440, 440, 40614, 12000, 440, 441, 9000, 3000, 440, 440, 440, 441, 439,
    ];
    for (i, &value) in samples.iter().enumerate() {
        image.data[i * 2..i * 2 + 2].copy_from_slice(&value.to_le_bytes());
    }

    let header = skotiq_imaging::FitsHeader::new();
    skotiq_imaging::write_fits(&path, &image, &header).unwrap();

    let (read_back, _) = skotiq_imaging::read_fits(&path).unwrap();
    let linear = image_data_to_linear_f64(&read_back);

    assert_eq!(linear.len(), samples.len());
    for (i, &expected) in samples.iter().enumerate() {
        assert_eq!(
            linear[i], expected as f64,
            "pixel {i} decoded as {} but the file holds {expected}",
            linear[i]
        );
    }
}

/// Every other consumer in the imaging crate reads `ImageData.data` with
/// `from_le_bytes`; this decoder must agree with them, or the same buffer
/// yields two different images depending on which path touches it.
#[test]
fn agrees_with_image_data_native_accessors() {
    let mut image = ImageData::new(2, 1, 1, PixelType::U16);
    image.data[0..2].copy_from_slice(&440u16.to_le_bytes());
    image.data[2..4].copy_from_slice(&40614u16.to_le_bytes());

    let linear = image_data_to_linear_f64(&image);
    let native = image.as_u16().unwrap();

    assert_eq!(linear, vec![native[0] as f64, native[1] as f64]);
    assert_eq!(linear, vec![440.0, 40614.0]);
}

#[test]
fn round_trips_f32_pixels() {
    let mut image = ImageData::new(2, 1, 1, PixelType::F32);
    image.data[0..4].copy_from_slice(&1.5f32.to_le_bytes());
    image.data[4..8].copy_from_slice(&(-2.25f32).to_le_bytes());

    assert_eq!(image_data_to_linear_f64(&image), vec![1.5, -2.25]);
}
