//! The FITS thumbnail generator behind every frame strip in the app.
//!
//! Two properties are pinned here. The first is that the generator samples the
//! frame rather than materialising it: it used to convert the whole frame to
//! `Vec<u16>` before reading one sample in `scale`, which for a 4656 x 3520
//! ASI1600 frame meant 32.8 MB of allocation and 16.4 million conversions to
//! keep 1.2% of them. The second is that every FITS pixel type and both the
//! mono and colour channel layouts come out with the same pixel values they
//! did through the whole-frame conversion, since a thumbnail that changes
//! appearance by pixel type is a bug the operator would see and not be able to
//! explain.

use super::*;
use skotiq_imaging::{FitsHeader, ImageData, PixelType};

fn write_frame(dir: &tempfile::TempDir, name: &str, image: &ImageData) -> String {
    let path = dir.path().join(name);
    let mut header = FitsHeader::new();
    header.set_float("EXPTIME", 1.0);
    skotiq_imaging::write_fits(&path, image, &header).expect("write fixture FITS");
    path.to_string_lossy().into_owned()
}

/// A mono ramp whose value is a known function of position, so a thumbnail
/// pixel can be checked against the source sample it must have come from.
fn mono_ramp(width: u32, height: u32) -> ImageData {
    let mut data = Vec::with_capacity((width * height) as usize * 2);
    for y in 0..height {
        for x in 0..width {
            let value = ((y * width + x) % 65536) as u16;
            data.extend_from_slice(&value.to_le_bytes());
        }
    }
    ImageData {
        width,
        height,
        channels: 1,
        pixel_type: PixelType::U16,
        data,
    }
}

fn decode_jpeg(bytes: &[u8]) -> (u32, u32) {
    let img = image::load_from_memory(bytes).expect("generator emitted a decodable JPEG");
    (
        image::GenericImageView::width(&img),
        image::GenericImageView::height(&img),
    )
}

#[test]
fn emits_a_jpeg_scaled_to_the_requested_max_edge() {
    let dir = tempfile::tempdir().unwrap();
    let path = write_frame(&dir, "ramp.fits", &mono_ramp(640, 480));

    let jpeg = generate_fits_thumbnail_jpeg(&path, 160).expect("thumbnail");

    // 640 / 160 = 4, so the generator keeps one pixel in four on each axis.
    let (w, h) = decode_jpeg(&jpeg);
    assert_eq!((w, h), (160, 120), "thumbnail geometry");
}

#[test]
fn a_frame_already_smaller_than_the_max_edge_is_not_upscaled() {
    let dir = tempfile::tempdir().unwrap();
    let path = write_frame(&dir, "small.fits", &mono_ramp(64, 48));

    let jpeg = generate_fits_thumbnail_jpeg(&path, 512).expect("thumbnail");

    let (w, h) = decode_jpeg(&jpeg);
    assert_eq!(
        (w, h),
        (64, 48),
        "a small frame passes through at its own size"
    );
}

#[test]
fn every_pixel_type_produces_the_same_thumbnail_for_the_same_physical_values() {
    let dir = tempfile::tempdir().unwrap();
    let width = 128u32;
    let height = 96u32;

    // The same physical ramp expressed four ways. The generator's per-type
    // conversions are defined to land on the same u16 value, so the JPEGs must
    // agree pixel for pixel.
    let mut u8_data = Vec::new();
    let mut u16_data = Vec::new();
    let mut u32_data = Vec::new();
    let mut f32_data = Vec::new();
    for y in 0..height {
        for x in 0..width {
            let step = ((y * width + x) % 256) as u8;
            u8_data.push(step);
            let as_u16 = u16::from(step) << 8;
            u16_data.extend_from_slice(&as_u16.to_le_bytes());
            u32_data.extend_from_slice(&(u32::from(as_u16) << 16).to_le_bytes());
            f32_data.extend_from_slice(&(f32::from(as_u16) / 65535.0).to_le_bytes());
        }
    }

    let frames = [
        ("u8.fits", PixelType::U8, u8_data),
        ("u16.fits", PixelType::U16, u16_data),
        ("u32.fits", PixelType::U32, u32_data),
        ("f32.fits", PixelType::F32, f32_data),
    ];

    let mut thumbnails = Vec::new();
    for (name, pixel_type, data) in frames {
        let image = ImageData {
            width,
            height,
            channels: 1,
            pixel_type,
            data,
        };
        let path = write_frame(&dir, name, &image);
        thumbnails.push((
            name,
            generate_fits_thumbnail_jpeg(&path, 32).expect("thumbnail"),
        ));
    }

    let (_, reference) = &thumbnails[0];
    for (name, bytes) in &thumbnails[1..] {
        assert_eq!(
            bytes, reference,
            "{name} disagreed with the u8 frame carrying the same physical values"
        );
    }
}

#[test]
fn a_three_channel_frame_is_reduced_by_luminance_not_by_its_first_channel() {
    let dir = tempfile::tempdir().unwrap();
    let width = 32u32;
    let height = 32u32;

    // Red 0, green 40000, blue 0. Taking the first channel would give black;
    // the luminance weights (77/150/29 over 256) give roughly 150/256 of green.
    let mut data = Vec::new();
    for _ in 0..(width * height) {
        for value in [0u16, 40000, 0] {
            data.extend_from_slice(&value.to_le_bytes());
        }
    }
    let image = ImageData {
        width,
        height,
        channels: 3,
        pixel_type: PixelType::U16,
        data,
    };
    let path = write_frame(&dir, "rgb.fits", &image);

    let jpeg = generate_fits_thumbnail_jpeg(&path, 16).expect("thumbnail");
    let decoded = image::load_from_memory(&jpeg).unwrap().to_luma8();

    // Uniform input, so every thumbnail pixel is the same non-black value.
    let sample = decoded.as_raw()[0];
    assert!(
        sample > 16,
        "a green-only frame reduced to {sample}; the first channel was taken \
         instead of the luminance"
    );
    assert!(
        decoded.as_raw().iter().all(|&v| v == sample),
        "a uniform frame produced a non-uniform thumbnail"
    );
}

#[test]
fn a_zero_max_size_is_refused_rather_than_dividing_by_zero() {
    let dir = tempfile::tempdir().unwrap();
    let path = write_frame(&dir, "ramp.fits", &mono_ramp(64, 64));

    let error = generate_fits_thumbnail_jpeg(&path, 0).expect_err("must refuse");
    assert!(
        format!("{error:?}").contains("max_size"),
        "unexpected error: {error:?}"
    );
}

#[test]
fn a_missing_file_reports_the_read_failure() {
    let dir = tempfile::tempdir().unwrap();
    let missing = dir
        .path()
        .join("absent.fits")
        .to_string_lossy()
        .into_owned();

    let error = generate_fits_thumbnail_jpeg(&missing, 128).expect_err("must fail");
    assert!(
        format!("{error:?}").contains("Failed to read FITS"),
        "unexpected error: {error:?}"
    );
}

/// The async wrapper must hand back exactly what the blocking body produces —
/// it exists to get that body off the calling isolate, not to change it.
#[tokio::test]
async fn the_async_entry_point_returns_the_blocking_body_verbatim() {
    let dir = tempfile::tempdir().unwrap();
    let path = write_frame(&dir, "ramp.fits", &mono_ramp(256, 192));

    let direct = generate_fits_thumbnail_jpeg(&path, 64).expect("blocking");
    let through_bridge = api_generate_fits_thumbnail(path.clone(), 64)
        .await
        .expect("async");

    assert_eq!(direct, through_bridge);
}

/// Concurrent callers all get their own correct answer: the admission gate
/// bounds how many decode at once, it must not drop or cross requests.
#[tokio::test]
async fn concurrent_requests_are_all_served() {
    let dir = tempfile::tempdir().unwrap();
    let paths: Vec<String> = (0..THUMBNAIL_GENERATION_CONCURRENCY * 3)
        .map(|i| {
            let mut image = mono_ramp(96, 96);
            // Make each frame distinct so a crossed answer is detectable.
            image.data[0] = i as u8;
            write_frame(&dir, &format!("frame_{i}.fits"), &image)
        })
        .collect();

    let expected: Vec<Vec<u8>> = paths
        .iter()
        .map(|p| generate_fits_thumbnail_jpeg(p, 32).expect("blocking"))
        .collect();

    let mut handles = Vec::new();
    for path in paths.clone() {
        handles.push(tokio::spawn(async move {
            api_generate_fits_thumbnail(path, 32).await
        }));
    }

    for (index, handle) in handles.into_iter().enumerate() {
        let bytes = handle.await.expect("join").expect("thumbnail");
        assert_eq!(bytes, expected[index], "frame {index} got the wrong answer");
    }
}
