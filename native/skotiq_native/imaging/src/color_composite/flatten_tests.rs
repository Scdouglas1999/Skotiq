use serde_json::json;

use super::*;
use crate::background_extraction::normalise_xy;
use crate::color_composite::align::Affine2;
use crate::color_composite::test_scene::{mono, render_master, stars, Lcg};

const W: u32 = 768;
const H: u32 = 576;

/// A reference star field and the same field through a filter whose
/// throughput is `10^gain(nx, ny)` times the reference's.
fn field_with_throughput(gain: impl Fn(f64, f64) -> f64) -> (Vec<f32>, Vec<f32>) {
    let field = stars(W, H, 900, 11);
    let reference = render_master(
        W,
        H,
        &field,
        [0.3, 0.4, 0.3],
        &Affine2::IDENTITY,
        1000.0,
        6.0,
        1,
    );
    let filtered: Vec<_> = field
        .iter()
        .map(|s| {
            let (nx, ny) = normalise_xy(s.x, s.y, W, H);
            let mut s = *s;
            s.rgb[0] *= 10f64.powf(gain(nx, ny));
            s
        })
        .collect();
    let plane = render_master(
        W,
        H,
        &filtered,
        [1.0, 0.0, 0.0],
        &Affine2::IDENTITY,
        800.0,
        6.0,
        2,
    );
    (reference, plane)
}

fn field_stars(reference: &[f32]) -> FieldStars {
    FieldStars::detect(&mono(W, H, reference.to_vec(), "L"), &OpContext::new()).expect("detect")
}

#[test]
fn a_surface_reads_back_what_it_wrote_and_refuses_a_wrong_length() {
    let surface = Surface {
        degree: 1,
        coefficients: vec![0.5, -0.25, 0.125],
    };
    assert_eq!(Surface::from_json(&surface.to_json()).unwrap(), surface);
    let err = Surface::from_json(&json!({"degree": 2, "coefficients": [1.0, 2.0, 3.0]}))
        .expect_err("a degree-2 surface has six terms");
    assert!(err.contains("6 coefficients"), "{err}");
    assert!(Surface::from_json(&json!({"degree": 7, "coefficients": []})).is_err());
}

#[test]
fn a_throughput_falling_across_the_field_is_measured_from_the_stars() {
    // Red loses 0.15 dex from the bottom of the frame to the top.
    let (reference, mut plane) = field_with_throughput(|_, ny| 0.075 * ny);
    let stars = field_stars(&reference);
    assert!(
        stars.photometry_count() > 100,
        "{}",
        stars.photometry_count()
    );
    let fit = measure_throughput(&plane, &reference, W as usize, H as usize, &stars)
        .expect("enough stars");
    assert!(fit.surface.degree >= 1, "{fit:?}");
    let drop = column_drop(&fit.surface);
    assert!(
        (drop - 0.15).abs() < 0.03,
        "top-to-bottom {drop} dex: {fit:?}"
    );

    apply_throughput(&mut plane, W as usize, H as usize, &fit.surface);
    let again = measure_throughput(&plane, &reference, W as usize, H as usize, &stars)
        .expect("enough stars");
    let left = column_drop(&again.surface);
    assert!(
        left.abs() < 0.03,
        "the corrected plane still trends {left} dex: {again:?}"
    );
}

/// The surface's change from the top to the bottom of the centre column.
fn column_drop(surface: &Surface) -> f64 {
    let terms = crate::background_extraction::poly_terms(surface.degree);
    let at = |ny| crate::background_extraction::eval_poly(&surface.coefficients, &terms, 0.0, ny);
    at(1.0) - at(-1.0)
}

#[test]
fn a_filter_with_even_throughput_gets_no_correction() {
    let (reference, plane) = field_with_throughput(|_, _| 0.0);
    let stars = field_stars(&reference);
    let fit = measure_throughput(&plane, &reference, W as usize, H as usize, &stars)
        .expect("enough stars");
    assert_eq!(fit.surface.degree, 0, "{fit:?}");
    assert!(fit.surface.coefficients[0].abs() < 1e-12, "{fit:?}");
}

#[test]
fn too_few_stars_measure_no_throughput() {
    let reference = vec![1000.0_f32; (W * H) as usize];
    let stars = field_stars(&reference);
    assert!(measure_throughput(&reference, &reference, W as usize, H as usize, &stars).is_none());
}

#[test]
fn a_vignetting_bowl_takes_a_higher_degree_than_a_tilt() {
    let field = stars(W, H, 300, 5);
    let base = render_master(
        W,
        H,
        &field,
        [0.3, 0.4, 0.3],
        &Affine2::IDENTITY,
        0.0,
        4.0,
        3,
    );
    let (w, h) = (W as usize, H as usize);
    let with = |shape: &dyn Fn(f64, f64) -> f64| -> Vec<f32> {
        base.iter()
            .enumerate()
            .map(|(i, v)| {
                let (nx, ny) = normalise_xy((i % w) as f64, (i / w) as f64, W, H);
                *v + shape(nx, ny) as f32
            })
            .collect()
    };
    let bowl = with(&|nx, ny| {
        let r2 = nx * nx + ny * ny;
        2000.0 - 300.0 * r2 * r2
    });
    let tilt = with(&|nx, _| 2000.0 + 50.0 * nx);
    let stars = field_stars(&base);
    let ctx = OpContext::new();
    let bowl_fit = measure_background(&bowl, w, h, &stars, &ctx)
        .unwrap()
        .expect("a fit");
    let tilt_fit = measure_background(&tilt, w, h, &stars, &ctx)
        .unwrap()
        .expect("a fit");
    assert!(bowl_fit.surface.degree >= 4, "{bowl_fit:?}");
    assert_eq!(
        tilt_fit.surface.degree, BACKGROUND_DEGREES[0],
        "{tilt_fit:?}"
    );

    let mut flat = bowl.clone();
    apply_background(&mut flat, w, h, &bowl_fit.surface);
    let corner = flat[5 * w + 5] as f64;
    let centre = flat[(h / 2) * w + w / 2] as f64;
    assert!(
        (corner - centre).abs() < 20.0,
        "corner {corner} centre {centre}"
    );
}

/// Three flat sky planes at different levels with `noise`.
fn sky(levels: [f64; 3], noise: f64) -> [Vec<f32>; 3] {
    let mut rng = Lcg::new(17);
    levels.map(|level| {
        (0..(W * H) as usize)
            .map(|_| (level + noise * rng.normal()) as f32)
            .collect()
    })
}

fn mean_over(plane: &[f32], x0: usize, y0: usize, side: usize) -> f64 {
    let mut sum = 0.0;
    for y in y0..y0 + side {
        for x in x0..x0 + side {
            sum += plane[y * W as usize + x] as f64;
        }
    }
    sum / (side * side) as f64
}

#[test]
fn a_dust_shadow_in_one_filter_loses_its_color_and_a_shared_one_is_kept() {
    let (w, h) = (W as usize, H as usize);
    let [mut r, mut g, mut b] = sky([1000.0, 900.0, 1200.0], 5.0);
    // A shadow in green alone at (200, 200), and one in every plane at (550, 380).
    for y in 0..h {
        for x in 0..w {
            let d1 = ((x as f64 - 200.0).powi(2) + (y as f64 - 200.0).powi(2)).sqrt();
            let d2 = ((x as f64 - 550.0).powi(2) + (y as f64 - 380.0).powi(2)).sqrt();
            let i = y * w + x;
            if d1 < 60.0 {
                g[i] -= 30.0;
            }
            if d2 < 60.0 {
                r[i] -= 0.03 * 1000.0;
                g[i] -= 0.03 * 900.0;
                b[i] -= 0.03 * 1200.0;
            }
        }
    }
    let report = flatten_chroma([&mut r, &mut g, &mut b], w, h, 32).expect("a lattice");
    assert_eq!(report.grid, (24, 18));
    // The green-only shadow is now the same fraction of every plane's sky: a
    // neutral dip in lightness, with no color of its own.
    let dip = |plane: &[f32], level: f64| {
        (mean_over(plane, 190, 190, 20) - mean_over(plane, 20, 400, 20)) / level
    };
    let (dr, dg, db) = (dip(&r, 1000.0), dip(&g, 900.0), dip(&b, 1200.0));
    assert!(
        (dg - dr).abs() < 0.002 && (dg - db).abs() < 0.002,
        "{dr} {dg} {db}"
    );
    let shared = mean_over(&r, 540, 370, 20) - mean_over(&r, 20, 400, 20);
    assert!(
        shared < -20.0,
        "the shared shadow is lightness and stays: {shared}"
    );
}

#[test]
fn a_colored_object_keeps_its_color() {
    let (w, h) = (W as usize, H as usize);
    let [mut r, mut g, mut b] = sky([1000.0, 1000.0, 1000.0], 5.0);
    // A red galaxy-sized blob at the centre.
    for y in 0..h {
        for x in 0..w {
            let d2 = (x as f64 - 384.0).powi(2) + (y as f64 - 288.0).powi(2);
            let v = 400.0 * (-d2 / (2.0 * 45.0 * 45.0)).exp();
            let i = y * w + x;
            r[i] += (v * 1.6) as f32;
            g[i] += v as f32;
            b[i] += (v * 0.6) as f32;
        }
    }
    let before = mean_over(&r, 374, 278, 20) / mean_over(&b, 374, 278, 20);
    let report = flatten_chroma([&mut r, &mut g, &mut b], w, h, 32).expect("a lattice");
    assert!(report.object_boxes > 0, "{report:?}");
    let after = mean_over(&r, 374, 278, 20) / mean_over(&b, 374, 278, 20);
    assert!(
        (after / before - 1.0).abs() < 0.01,
        "red/blue {before} -> {after}"
    );
}

#[test]
fn a_frame_too_small_for_the_lattice_is_left_alone() {
    let mut planes = [
        vec![1.0_f32; 64 * 64],
        vec![1.0; 64 * 64],
        vec![1.0; 64 * 64],
    ];
    let [r, g, b] = &mut planes;
    assert!(flatten_chroma([r, g, b], 64, 64, 32).is_none());
}
