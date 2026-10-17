use super::{api_save_rgba_jpeg_file, api_save_rgba_png_file};
use crate::error::SkotiqError;

/// A deterministic 2x2 RGBA image: red (opaque), green (opaque),
/// blue (opaque), and a half-transparent white pixel.
fn fixture_2x2() -> Vec<u8> {
    vec![
        255, 0, 0, 255, // (0,0) red
        0, 255, 0, 255, // (1,0) green
        0, 0, 255, 255, // (0,1) blue
        255, 255, 255, 128, // (1,1) white @ 50% alpha
    ]
}

#[tokio::test]
async fn writes_rgba_png_and_round_trips_color_and_alpha() {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("share_card.png");

    api_save_rgba_png_file(path.to_string_lossy().into_owned(), 2, 2, fixture_2x2())
        .await
        .expect("RGBA PNG should write successfully");

    // Read it back through the image crate and assert geometry + channels.
    let decoded = image::open(&path).expect("decoded PNG should open");
    let rgba = decoded.to_rgba8();
    assert_eq!(rgba.width(), 2);
    assert_eq!(rgba.height(), 2);
    // RgbaImage is 4 channels by construction.
    assert_eq!(rgba.as_raw().len(), 2 * 2 * 4);

    // Color is preserved verbatim (PNG is lossless and keeps alpha).
    assert_eq!(rgba.get_pixel(0, 0).0, [255, 0, 0, 255]);
    assert_eq!(rgba.get_pixel(1, 0).0, [0, 255, 0, 255]);
    assert_eq!(rgba.get_pixel(0, 1).0, [0, 0, 255, 255]);
    assert_eq!(rgba.get_pixel(1, 1).0, [255, 255, 255, 128]);
}

#[tokio::test]
async fn writes_rgba_jpeg_flattening_alpha_onto_black() {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("share_card.jpg");

    api_save_rgba_jpeg_file(path.to_string_lossy().into_owned(), 2, 2, fixture_2x2(), 90)
        .await
        .expect("RGBA JPEG should write successfully");

    let decoded = image::open(&path).expect("decoded JPEG should open");
    let rgb = decoded.to_rgb8();
    assert_eq!(rgb.width(), 2);
    assert_eq!(rgb.height(), 2);
    // JPEG has no alpha channel.
    assert_eq!(rgb.as_raw().len(), 2 * 2 * 3);

    // The half-transparent white pixel composited over black is ~mid-gray
    // (255 * 128 / 255 = 128 per channel). JPEG is lossy, so allow slack.
    let flattened = rgb.get_pixel(1, 1).0;
    for channel in flattened {
        assert!(
            (channel as i32 - 128).abs() <= 24,
            "flattened white@50% should be ~128 per channel, got {:?}",
            flattened
        );
    }
}

#[tokio::test]
async fn short_png_buffer_is_rejected() {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("bad.png");

    // 2x2 needs 16 bytes; provide 12 (a "short" buffer).
    let err = api_save_rgba_png_file(path.to_string_lossy().into_owned(), 2, 2, vec![0u8; 12])
        .await
        .expect_err("short RGBA buffer must be rejected, not silently truncated");

    assert!(matches!(err, SkotiqError::ImageError(_)));
    // Nothing should have been written for an invalid input.
    assert!(
        !path.exists(),
        "no file should be created on validation failure"
    );
}

#[tokio::test]
async fn short_jpeg_buffer_is_rejected() {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("bad.jpg");

    let err = api_save_rgba_jpeg_file(path.to_string_lossy().into_owned(), 2, 2, vec![0u8; 12], 85)
        .await
        .expect_err("short RGBA buffer must be rejected, not silently truncated");

    assert!(matches!(err, SkotiqError::ImageError(_)));
    assert!(
        !path.exists(),
        "no file should be created on validation failure"
    );
}
