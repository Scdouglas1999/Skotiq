use super::auto_stretch_color_image;

/// The colour stretch emits opaque-alpha RGBA8 of exactly width*height*4.
#[test]
fn emits_rgba8_with_opaque_alpha() {
    // 2x2 interleaved RGB16 with structure in every channel.
    let data: Vec<u16> = vec![
        1000, 2000, 3000, //
        4000, 5000, 6000, //
        7000, 8000, 9000, //
        10000, 11000, 12000, //
    ];
    let rgba = auto_stretch_color_image(2, 2, data);
    assert_eq!(rgba.len(), 2 * 2 * 4, "RGBA8 length is width*height*4");
    for px in rgba.as_chunks::<4>().0.iter() {
        assert_eq!(px[3], 255, "alpha must be fully opaque");
    }
}

/// Each channel is stretched against its own noise scale (Unlinked STF), so
/// channels with different spreads map the same pixel to different outputs.
#[test]
fn stretches_each_channel_independently() {
    let pixel_count = 64usize;
    let mut data = Vec::with_capacity(pixel_count * 3);
    for i in 0..pixel_count {
        let i = i as u16;
        data.push(800 + i * 16); // narrow red spread
        data.push(800 + i * 128); // medium green spread
        data.push(800 + i * 480); // wide blue spread
    }
    let rgba = auto_stretch_color_image(8, 8, data);

    // Brightest pixel is the last one.
    let probe = (pixel_count - 1) * 4;
    let (r, g, b) = (rgba[probe], rgba[probe + 1], rgba[probe + 2]);
    // A single shared (linked) curve would force r == g == b here.
    let distinct = [r, g, b]
        .into_iter()
        .collect::<std::collections::HashSet<_>>();
    assert!(
        distinct.len() > 1,
        "channels must stretch independently, got r={r} g={g} b={b}"
    );
}

/// A perfectly flat channel has MAD = 0; the STF must return the identity
/// transform for it rather than inventing a stretch. A mid-grey constant
/// (0x8000 ≈ 0.5) therefore maps to ~127.
#[test]
fn constant_channel_is_identity() {
    let pixel_count = 16usize;
    let flat = 0x8000u16;
    let data: Vec<u16> = std::iter::repeat_n(flat, pixel_count * 3).collect();
    let rgba = auto_stretch_color_image(4, 4, data);
    for px in rgba.as_chunks::<4>().0.iter() {
        assert_eq!(px[0], 127, "constant R → identity midtone");
        assert_eq!(px[1], 127, "constant G → identity midtone");
        assert_eq!(px[2], 127, "constant B → identity midtone");
        assert_eq!(px[3], 255);
    }
}

/// A length mismatch yields a black RGBA buffer of the correct size rather
/// than panicking (mirrors the defensive length guard in the imaging crate).
#[test]
fn length_mismatch_returns_black_buffer() {
    let rgba = auto_stretch_color_image(2, 2, vec![1, 2, 3]); // expects 12 samples
    assert_eq!(rgba.len(), 2 * 2 * 4);
    for px in rgba.as_chunks::<4>().0.iter() {
        assert_eq!(px, &[0, 0, 0, 0]);
    }
}
