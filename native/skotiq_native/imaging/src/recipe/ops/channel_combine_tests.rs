use std::sync::Arc;

use serde_json::{json, Value};

use super::*;
use crate::color_composite::test_scene::{mono, pyramid, render_master, similarity, stars, Star};
use crate::color_composite::PyramidSources;
use crate::recipe::{MasterSource, OpContext};

const W: u32 = 480;
const H: u32 = 360;

struct Scene {
    field: Vec<Star>,
    base: OpImage,
    sources: Arc<PyramidSources>,
    params: Value,
}

/// An LRGB scene: L is the reference, R, G and B each sit on their own
/// geometry and pedestal.
fn lrgb_scene() -> Scene {
    let field = stars(W, H, 120, 11);
    let l = render_master(
        W,
        H,
        &field,
        [0.9, 0.9, 0.9],
        &Affine2::IDENTITY,
        5500.0,
        6.0,
        1,
    );
    let maps = [
        (
            "red",
            "R",
            similarity(0.6, 18.4, 7.1, W, H),
            [1.0, 0.0, 0.0],
            2500.0,
        ),
        (
            "green",
            "G",
            similarity(-0.3, 2.2, 6.3, W, H),
            [0.0, 1.0, 0.0],
            2300.0,
        ),
        (
            "blue",
            "B",
            similarity(0.2, 16.0, -9.4, W, H),
            [0.0, 0.0, 1.0],
            4000.0,
        ),
    ];
    let mut sources = PyramidSources::new();
    let mut inputs = vec![json!({
        "role": "luminance", "filter": "L", "path": "l.fits",
        "width": W, "height": H, "reference": true,
    })];
    for (i, (role, filter, map, weights, pedestal)) in maps.iter().enumerate() {
        let plane = render_master(W, H, &field, *weights, map, *pedestal, 6.0, 10 + i as u64);
        let path = format!("{}.fits", filter.to_lowercase());
        sources.insert(
            path.clone(),
            format!("id-{filter}"),
            pyramid(mono(W, H, plane, filter)),
        );
        inputs.push(json!({
            "role": role, "filter": filter, "path": path,
            "width": W, "height": H, "transform": map.m.to_vec(),
        }));
    }
    let crop = crate::color_composite::overlap_rect(
        W,
        H,
        &maps.iter().map(|m| (m.2, W, H)).collect::<Vec<_>>(),
        4.0,
        8,
    )
    .expect("overlap");
    Scene {
        field,
        base: mono(W, H, l, "L"),
        sources: Arc::new(sources),
        params: json!({
            "palette": "lrgb",
            "inputs": inputs,
            "crop": {"x": crop.x, "y": crop.y, "width": crop.width, "height": crop.height},
        }),
    }
}

fn ctx(sources: &Arc<PyramidSources>) -> OpContext {
    OpContext::new().with_sources(Arc::clone(sources) as Arc<dyn MasterSource>)
}

/// Background-subtracted aperture flux of one channel at `(x, y)`.
fn aperture(image: &OpImage, channel: usize, x: f64, y: f64) -> f64 {
    let w = image.width() as i64;
    let h = image.height() as i64;
    let mut inner = 0.0;
    let mut count = 0.0;
    let mut annulus = Vec::new();
    for dy in -12i64..=12 {
        for dx in -12i64..=12 {
            let px = x.round() as i64 + dx;
            let py = y.round() as i64 + dy;
            if px < 0 || py < 0 || px >= w || py >= h {
                continue;
            }
            let v = image.data()[((py * w + px) * 3) as usize + channel] as f64;
            let r = ((px as f64 - x).powi(2) + (py as f64 - y).powi(2)).sqrt();
            if r <= 6.0 {
                inner += v;
                count += 1.0;
            } else if r >= 9.0 {
                annulus.push(v);
            }
        }
    }
    annulus.sort_by(f64::total_cmp);
    inner - count * annulus[annulus.len() / 2]
}

#[test]
fn lrgb_keeps_each_star_its_color() {
    let scene = lrgb_scene();
    let applied = ChannelCombineV1
        .apply_measured(&scene.base, &scene.params, &ctx(&scene.sources))
        .expect("combines");
    let out = &applied.image;
    assert_eq!(out.channels(), 3);
    let crop = &scene.params["crop"];
    let (cx, cy) = (crop["x"].as_f64().unwrap(), crop["y"].as_f64().unwrap());
    let mut checked = 0;
    for star in &scene.field {
        let (x, y) = (star.x - cx, star.y - cy);
        if x < 14.0 || y < 14.0 || x > out.width() as f64 - 14.0 || y > out.height() as f64 - 14.0 {
            continue;
        }
        if star.rgb[1] < 10_000.0 {
            continue;
        }
        let crowded = scene.field.iter().any(|o| {
            let d = ((o.x - star.x).powi(2) + (o.y - star.y).powi(2)).sqrt();
            d > 0.0 && d < 16.0
        });
        if crowded {
            continue;
        }
        let r = aperture(out, 0, x, y);
        let g = aperture(out, 1, x, y);
        let b = aperture(out, 2, x, y);
        let want_rg = star.rgb[0] / star.rgb[1];
        let want_bg = star.rgb[2] / star.rgb[1];
        assert!(
            ((r / g) / want_rg - 1.0).abs() < 0.05,
            "R/G {:.3} vs {want_rg:.3}",
            r / g
        );
        assert!(
            ((b / g) / want_bg - 1.0).abs() < 0.05,
            "B/G {:.3} vs {want_bg:.3}",
            b / g
        );
        checked += 1;
    }
    assert!(checked >= 10, "only {checked} bright stars checked");
    let measured = applied.measurement.expect("a measurement");
    assert_eq!(measured["palette"], "lrgb");
    assert!(
        measured["fits"]["luminanceToRgb"]["scale"]
            .as_f64()
            .unwrap()
            > 0.0
    );
    assert_eq!(measured["fitsPinned"], false);
    assert_eq!(out.header().get_string("FILTER"), Some("LRGB"));
}

#[test]
fn pinned_fits_replay_the_measured_render_bit_for_bit() {
    let scene = lrgb_scene();
    let context = ctx(&scene.sources);
    let first = ChannelCombineV1
        .apply_measured(&scene.base, &scene.params, &context)
        .expect("combines");
    let mut pinned = scene.params.clone();
    pinned["fits"] = first.measurement.as_ref().unwrap()["fits"].clone();
    let second = ChannelCombineV1
        .apply_measured(&scene.base, &pinned, &context)
        .expect("combines");
    assert_eq!(first.image.data(), second.image.data());
    assert_eq!(second.measurement.unwrap()["fitsPinned"], true);
}

#[test]
fn a_preview_level_renders_the_same_picture_smaller() {
    let scene = lrgb_scene();
    let mut pinned = scene.params.clone();
    let full = ChannelCombineV1
        .apply_measured(&scene.base, &scene.params, &ctx(&scene.sources))
        .expect("full");
    pinned["fits"] = full.measurement.as_ref().unwrap()["fits"].clone();
    let base_level1 = crate::recipe::downsample_2x(&scene.base).expect("downsample");
    let preview = ChannelCombineV1
        .apply(&base_level1, &pinned, &ctx(&scene.sources).at_level(1))
        .expect("preview");
    let expected = crate::recipe::downsample_2x(&full.image).expect("downsample");
    assert_eq!(preview.width(), expected.width());
    assert_eq!(preview.height(), expected.height());
    // The channel means agree: the preview is the same balance.
    for c in 0..3 {
        let mean = |img: &OpImage| {
            img.data()
                .iter()
                .skip(c)
                .step_by(3)
                .map(|v| *v as f64)
                .sum::<f64>()
                / img.pixel_count() as f64
        };
        let (a, b) = (mean(&preview), mean(&expected));
        assert!((a / b - 1.0).abs() < 0.01, "channel {c}: {a} vs {b}");
    }
}

#[test]
fn the_reference_header_moves_with_the_crop() {
    let mut scene = lrgb_scene();
    let header = scene.base.header_mut();
    header.set_float("CRPIX1", 240.0);
    header.set_float("CRPIX2", 180.0);
    let out = ChannelCombineV1
        .apply(&scene.base, &scene.params, &ctx(&scene.sources))
        .expect("combines");
    let crop = &scene.params["crop"];
    assert_eq!(
        out.header().get_float("CRPIX1"),
        Some(240.0 - crop["x"].as_f64().unwrap())
    );
    assert_eq!(
        out.header().get_float("CRPIX2"),
        Some(180.0 - crop["y"].as_f64().unwrap())
    );
}

#[test]
fn a_render_without_the_other_masters_is_skipped_with_the_reason() {
    let scene = lrgb_scene();
    match ChannelCombineV1.apply(&scene.base, &scene.params, &OpContext::new()) {
        Err(OpError::Unavailable { reason, .. }) => {
            assert!(reason.contains("other filters"), "{reason}")
        }
        other => panic!("expected an unavailable skip, got {other:?}"),
    }
}

#[test]
fn malformed_combinations_are_refused() {
    let scene = lrgb_scene();
    let mut cases: Vec<(Value, &str)> = Vec::new();

    let mut no_blue = scene.params.clone();
    no_blue["inputs"].as_array_mut().unwrap().remove(3);
    cases.push((no_blue, "needs a B master"));

    let mut two_refs = scene.params.clone();
    two_refs["inputs"][1]["reference"] = json!(true);
    two_refs["inputs"][1]
        .as_object_mut()
        .unwrap()
        .remove("transform");
    cases.push((two_refs, "exactly one input"));

    let mut bad_palette = scene.params.clone();
    bad_palette["palette"] = json!("rgbx");
    cases.push((bad_palette, "palette"));

    let mut extra = scene.params.clone();
    extra["palette"] = json!("rgb");
    cases.push((extra, "no place for a L master"));

    let mut outside = scene.params.clone();
    outside["crop"]["width"] = json!(W * 2);
    cases.push((outside, "does not lie inside"));

    let mut unknown = scene.params.clone();
    unknown["mystery"] = json!(1);
    cases.push((unknown, "unknown field"));

    let mut no_transform = scene.params.clone();
    no_transform["inputs"][2]
        .as_object_mut()
        .unwrap()
        .remove("transform");
    cases.push((no_transform, "no registration transform"));

    let mut weight = scene.params.clone();
    weight["haRedWeight"] = json!(1.5);
    cases.push((weight, "haRedWeight"));

    for (params, needle) in cases {
        let error = ChannelCombineV1
            .validate_params(&params)
            .expect_err(needle)
            .to_string();
        assert!(error.contains(needle), "expected '{needle}' in: {error}");
    }
    ChannelCombineV1
        .validate_params(&scene.params)
        .expect("the scene's own parameters validate");
}

/// Three registered narrowband masters with one emission patch each.
fn narrowband(palette: &str) -> (OpImage, Arc<PyramidSources>, Value) {
    let field = stars(W, H, 80, 5);
    let patch = |plane: &mut Vec<f32>, x0: u32, amount: f32| {
        for y in 100..160 {
            for x in x0..x0 + 60 {
                plane[(y * W + x) as usize] += amount;
            }
        }
    };
    let mut ha = render_master(
        W,
        H,
        &field,
        [1.0, 0.0, 0.0],
        &Affine2::IDENTITY,
        800.0,
        3.0,
        1,
    );
    patch(&mut ha, 60, 3000.0);
    // OIII records stars at half the Ha flux; its emission is elsewhere.
    let mut o = render_master(
        W,
        H,
        &field,
        [0.5, 0.0, 0.0],
        &Affine2::IDENTITY,
        500.0,
        3.0,
        2,
    );
    patch(&mut o, 200, 1500.0);
    let mut s = render_master(
        W,
        H,
        &field,
        [0.25, 0.0, 0.0],
        &Affine2::IDENTITY,
        300.0,
        3.0,
        3,
    );
    patch(&mut s, 340, 750.0);
    let mut sources = PyramidSources::new();
    sources.insert("o.fits", "o", pyramid(mono(W, H, o, "OIII")));
    sources.insert("s.fits", "s", pyramid(mono(W, H, s, "SII")));
    let id = Affine2::IDENTITY.m.to_vec();
    let mut inputs = vec![
        json!({"role": "hAlpha", "path": "ha.fits", "width": W, "height": H, "reference": true}),
        json!({"role": "oiii", "path": "o.fits", "width": W, "height": H, "transform": id}),
    ];
    if palette == "sho" {
        inputs.push(
            json!({"role": "sii", "path": "s.fits", "width": W, "height": H, "transform": id}),
        );
    }
    (
        mono(W, H, ha, "Ha"),
        Arc::new(sources),
        json!({
            "palette": palette,
            "inputs": inputs,
            "crop": {"x": 16, "y": 16, "width": W - 32, "height": H - 32},
        }),
    )
}

fn mean_rgb(image: &OpImage, x0: u32, y0: u32, size: u32) -> [f64; 3] {
    // The median, so a star inside the box does not move the level.
    let mut out = [0.0; 3];
    for (c, slot) in out.iter_mut().enumerate() {
        let mut values = Vec::new();
        for y in y0..y0 + size {
            for x in x0..x0 + size {
                values.push(image.data()[((y * image.width() + x) * 3) as usize + c] as f64);
            }
        }
        values.sort_by(f64::total_cmp);
        *slot = values[values.len() / 2];
    }
    out
}

#[test]
fn sho_maps_each_line_onto_its_channel_with_stars_matched() {
    let (base, sources, params) = narrowband("sho");
    let out = ChannelCombineV1
        .apply_measured(&base, &params, &ctx(&sources))
        .expect("combines");
    let fits = &out.measurement.as_ref().unwrap()["fits"];
    // OIII and SII are matched to Ha on the stars: scales of 2 and 4.
    assert!(
        (fits["oiiiToHAlpha"]["scale"].as_f64().unwrap() - 2.0).abs() < 0.1,
        "{fits}"
    );
    assert!(
        (fits["siiToHAlpha"]["scale"].as_f64().unwrap() - 4.0).abs() < 0.2,
        "{fits}"
    );
    let sky = mean_rgb(&out.image, 10, 300, 20);
    let ha_patch = mean_rgb(&out.image, 60, 94, 30);
    let o_patch = mean_rgb(&out.image, 200, 94, 30);
    let s_patch = mean_rgb(&out.image, 340, 94, 30);
    assert!(ha_patch[1] - sky[1] > 2000.0 && (ha_patch[0] - sky[0]).abs() < 100.0);
    assert!(o_patch[2] - sky[2] > 2000.0 && (o_patch[1] - sky[1]).abs() < 100.0);
    assert!(s_patch[0] - sky[0] > 2000.0 && (s_patch[2] - sky[2]).abs() < 100.0);
}

#[test]
fn hoo_puts_oiii_in_green_and_blue() {
    let (base, sources, params) = narrowband("hoo");
    let out = ChannelCombineV1
        .apply(&base, &params, &ctx(&sources))
        .expect("combines");
    let sky = mean_rgb(&out, 10, 300, 20);
    let o_patch = mean_rgb(&out, 200, 94, 30);
    assert!(o_patch[1] - sky[1] > 2000.0 && o_patch[2] - sky[2] > 2000.0);
    assert!((o_patch[1] - o_patch[2]).abs() < 1.0);
    let ha_patch = mean_rgb(&out, 60, 94, 30);
    assert!(ha_patch[0] - sky[0] > 2000.0 && (ha_patch[1] - sky[1]).abs() < 100.0);
}

#[test]
fn ha_is_blended_into_red() {
    let field = stars(W, H, 80, 8);
    let id = Affine2::IDENTITY;
    let r = render_master(W, H, &field, [1.0, 0.0, 0.0], &id, 1000.0, 3.0, 1);
    let g = render_master(W, H, &field, [0.0, 1.0, 0.0], &id, 1000.0, 3.0, 2);
    let b = render_master(W, H, &field, [0.0, 0.0, 1.0], &id, 1000.0, 3.0, 3);
    let mut ha = render_master(W, H, &field, [0.2, 0.0, 0.0], &id, 400.0, 3.0, 4);
    for y in 100..160 {
        for x in 100..160 {
            ha[(y * W + x) as usize] += 400.0;
        }
    }
    let mut sources = PyramidSources::new();
    for (path, plane, f) in [
        ("g.fits", g, "G"),
        ("b.fits", b, "B"),
        ("ha.fits", ha, "Ha"),
    ] {
        sources.insert(path, path, pyramid(mono(W, H, plane, f)));
    }
    let m = id.m.to_vec();
    let params = json!({
        "palette": "haRgb",
        "inputs": [
            {"role": "red", "path": "r.fits", "width": W, "height": H, "reference": true},
            {"role": "green", "path": "g.fits", "width": W, "height": H, "transform": m},
            {"role": "blue", "path": "b.fits", "width": W, "height": H, "transform": m},
            {"role": "hAlpha", "path": "ha.fits", "width": W, "height": H, "transform": m},
        ],
        "crop": {"x": 0, "y": 0, "width": W, "height": H},
    });
    let sources = Arc::new(sources);
    let out = ChannelCombineV1
        .apply_measured(&mono(W, H, r, "R"), &params, &ctx(&sources))
        .expect("combines");
    let fits = &out.measurement.as_ref().unwrap()["fits"];
    assert!(
        (fits["hAlphaToRed"]["scale"].as_f64().unwrap() - 5.0).abs() < 0.3,
        "{fits}"
    );
    let sky = mean_rgb(&out.image, 300, 300, 20);
    let patch = mean_rgb(&out.image, 110, 110, 40);
    // 400 ADU of Ha emission, scaled ×5 onto red and blended at one half.
    assert!(
        ((patch[0] - sky[0]) - 1000.0).abs() < 60.0,
        "{patch:?} vs {sky:?}"
    );
    assert!((patch[1] - sky[1]).abs() < 30.0);
}
