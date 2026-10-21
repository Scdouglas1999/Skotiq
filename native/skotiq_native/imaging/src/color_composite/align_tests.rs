use super::*;
use crate::color_composite::test_scene::{mono, render_master, similarity, stars};

const W: u32 = 640;
const H: u32 = 480;

fn scene_pair(map: &Affine2) -> (OpImage, OpImage) {
    let field = stars(W, H, 160, 7);
    let reference = mono(
        W,
        H,
        render_master(
            W,
            H,
            &field,
            [0.3, 0.4, 0.3],
            &Affine2::IDENTITY,
            1000.0,
            5.0,
            1,
        ),
        "L",
    );
    let frame = mono(
        W,
        H,
        render_master(W, H, &field, [1.0, 0.0, 0.0], map, 800.0, 5.0, 2),
        "R",
    );
    (reference, frame)
}

#[test]
fn level_maps_agree_with_the_full_resolution_map() {
    let map = similarity(1.2, 17.4, -6.3, W, H);
    for level in 1..4u32 {
        let s = (1u32 << level) as f64;
        let c = (s - 1.0) / 2.0;
        let at = map.at_level(level);
        for (x, y) in [(3.0, 5.0), (100.5, 40.25), (200.0, 150.0)] {
            let (lx, ly) = at.apply(x, y);
            let (fx, fy) = map.apply(s * x + c, s * y + c);
            assert!((lx - (fx - c) / s).abs() < 1e-9, "level {level} x");
            assert!((ly - (fy - c) / s).abs() < 1e-9, "level {level} y");
        }
    }
    let inverse = map.inverse().expect("invertible");
    let (x, y) = inverse.apply(map.apply(12.0, 34.0).0, map.apply(12.0, 34.0).1);
    assert!((x - 12.0).abs() < 1e-9 && (y - 34.0).abs() < 1e-9);
    assert!((map.rotation_deg() - 1.2).abs() < 1e-9);
    assert!((map.scale() - 1.0).abs() < 1e-12);
}

#[test]
fn registration_recovers_a_shift_and_rotation() {
    let map = similarity(1.5, 18.3, -7.6, W, H);
    let (reference, frame) = scene_pair(&map);
    let alignment = register_onto(&reference, &frame, &OpContext::new()).expect("registers");
    assert_eq!(alignment.model, "similarity");
    for (x, y) in [(50.0, 50.0), (320.0, 240.0), (600.0, 430.0)] {
        let (ex, ey) = map.apply(x, y);
        let (gx, gy) = alignment.transform.apply(x, y);
        assert!(
            (ex - gx).abs() < 0.05 && (ey - gy).abs() < 0.05,
            "({x}, {y}): expected ({ex:.3}, {ey:.3}), got ({gx:.3}, {gy:.3})"
        );
    }
    assert!(alignment.inliers >= 20, "{alignment:?}");
    assert!(alignment.rms_px < 0.2, "{alignment:?}");
}

#[test]
fn registration_recovers_a_meridian_flip() {
    let map = similarity(180.0, 4.0, -3.0, W, H);
    let (reference, frame) = scene_pair(&map);
    let alignment = register_onto(&reference, &frame, &OpContext::new()).expect("registers");
    let (ex, ey) = map.apply(100.0, 100.0);
    let (gx, gy) = alignment.transform.apply(100.0, 100.0);
    assert!((ex - gx).abs() < 0.05 && (ey - gy).abs() < 0.05);
    assert!((alignment.transform.rotation_deg().abs() - 180.0).abs() < 0.05);
}

#[test]
fn warped_stars_land_on_the_reference_stars() {
    let map = similarity(0.8, 21.7, 9.2, W, H);
    let (reference, frame) = scene_pair(&map);
    let alignment = register_onto(&reference, &frame, &OpContext::new()).expect("registers");
    let rect = overlap_rect(W, H, &[(alignment.transform, W, H)], 4.0, 16).expect("overlap");
    let warped = warp_window(&frame, &alignment.transform, rect, &OpContext::new()).expect("warp");
    let cropped_ref = {
        let mut out = Vec::new();
        for y in rect.y..rect.y + rect.height {
            let start = (y * W + rect.x) as usize;
            out.extend_from_slice(&reference.data()[start..start + rect.width as usize]);
        }
        mono(rect.width, rect.height, out, "L")
    };
    let warped = mono(rect.width, rect.height, warped, "R");
    let check = alignment_check(&cropped_ref, &warped, &OpContext::new())
        .expect("check")
        .expect("stars matched");
    assert!(check.stars >= 40, "{check:?}");
    assert!(check.median_px < 0.1, "{check:?}");
    assert!(
        check.mean_dx.abs() < 0.05 && check.mean_dy.abs() < 0.05,
        "{check:?}"
    );
}

#[test]
fn overlap_is_the_rectangle_every_master_covers_on_the_alignment_grid() {
    let shifted = similarity(0.0, 30.0, -12.0, W, H);
    let other = similarity(0.0, -10.0, 20.0, W, H);
    let rect = overlap_rect(W, H, &[(shifted, W, H), (other, W, H)], 4.0, 16).expect("overlap");
    // Covered x: [30 + 4, W − 10 − 5]; covered y: [20 + 4, H − 12 − 5].
    assert!(rect.x >= 34 && rect.x < 34 + 16, "{rect:?}");
    assert!(rect.y >= 24 && rect.y < 24 + 16, "{rect:?}");
    assert!(rect.x + rect.width <= W - 15, "{rect:?}");
    assert!(rect.y + rect.height <= H - 17, "{rect:?}");
    for edge in [rect.x, rect.y, rect.width, rect.height] {
        assert_eq!(edge % 16, 0, "{rect:?}");
    }
    // Rotation shrinks the overlap further but still yields one.
    let rotated = similarity(3.0, 0.0, 0.0, W, H);
    let r2 = overlap_rect(W, H, &[(rotated, W, H)], 4.0, 16).expect("overlap");
    assert!(r2.width < W && r2.height < H);
    assert!(overlap_rect(W, H, &[(similarity(0.0, 700.0, 0.0, W, H), W, H)], 4.0, 16).is_none());
}

#[test]
fn clamped_lanczos_does_not_ring_past_a_step() {
    let mut plane = vec![100.0_f32; 64 * 64];
    for y in 0..64 {
        for x in 32..64 {
            plane[y * 64 + x] = 10_000.0;
        }
    }
    let src = mono(64, 64, plane, "L");
    let shift = similarity(0.0, 0.37, 0.0, 64, 64);
    let out = warp_window(
        &src,
        &shift,
        Rect {
            x: 8,
            y: 8,
            width: 48,
            height: 48,
        },
        &OpContext::new(),
    )
    .expect("warp");
    let lo = out.iter().copied().fold(f32::INFINITY, f32::min);
    let hi = out.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    assert!(lo >= 100.0 && hi <= 10_000.0, "range {lo}..{hi}");
}

#[test]
fn star_profiles_are_measured_from_the_flux() {
    let field = stars(W, H, 120, 3);
    let image = mono(
        W,
        H,
        render_master(
            W,
            H,
            &field,
            [0.3, 0.4, 0.3],
            &Affine2::IDENTITY,
            1000.0,
            3.0,
            1,
        ),
        "L",
    );
    let sigma = star_sigma(&image, &OpContext::new())
        .expect("measures")
        .expect("enough stars");
    // The scene renders every star as a Gaussian of sigma 1.6 px; the pixel
    // sampling of the half-flux radius biases it by a few hundredths.
    assert!((sigma - 1.6).abs() < 0.15, "{sigma}");
}
