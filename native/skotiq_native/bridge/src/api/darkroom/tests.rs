//! Round-trip tests for the Darkroom surface: every entry point against a
//! synthetic master written to a temporary FITS, plus the cross-check that keeps
//! the published parameter schema honest against each operation's own
//! validation.

use std::path::{Path, PathBuf};

use serde_json::{json, Value};
use skotiq_imaging::recipe::{canonical_json, fingerprint_hex, OpRegistry, RECIPE_SCHEMA_VERSION};
use skotiq_imaging::{read_fits, write_fits, FitsHeader, ImageData};

use super::export::recipe_from_history;
use super::schema::{example_params, ParamKind, OP_DOCS};
use super::state::MAX_TRACKED_RENDERS;
use super::{
    api_darkroom_cancel, api_darkroom_registry, api_darkroom_render_export,
    api_darkroom_render_preview, api_darkroom_validate,
};

// ---------------------------------------------------------------------------
// Synthetic master
// ---------------------------------------------------------------------------

/// A deterministic linear congruential generator, so a test image is
/// reproducible without a random dependency.
struct Lcg(u64);

impl Lcg {
    fn next_unit(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((self.0 >> 11) as f64) / ((1u64 << 53) as f64)
    }
}

/// A synthetic linear master: a pedestal, Gaussian-ish noise and a lattice of
/// round stars, in `F32` ADU, carrying a complete CD-only WCS.
fn write_master(dir: &Path, name: &str, width: u32, height: u32, channels: u32) -> PathBuf {
    write_master_seeded(dir, name, width, height, channels, 0x51ED_2701_C0FF_EE01)
}

/// The same master under a different noise seed: the geometry, the header and
/// the star lattice match, and every sample differs.
fn write_master_seeded(
    dir: &Path,
    name: &str,
    width: u32,
    height: u32,
    channels: u32,
    seed: u64,
) -> PathBuf {
    let mut rng = Lcg(seed);
    let pedestal = 1000.0_f32;
    let mut data = vec![0.0_f32; (width * height * channels) as usize];
    for sample in data.iter_mut() {
        let noise = (rng.next_unit() + rng.next_unit() + rng.next_unit() - 1.5) * 60.0;
        *sample = pedestal + noise as f32;
    }
    for star_y in (8..height).step_by(19) {
        for star_x in (8..width).step_by(23) {
            for dy in -3i32..=3 {
                for dx in -3i32..=3 {
                    let x = star_x as i32 + dx;
                    let y = star_y as i32 + dy;
                    if x < 0 || y < 0 || x >= width as i32 || y >= height as i32 {
                        continue;
                    }
                    let radius2 = (dx * dx + dy * dy) as f64;
                    let flux = 4000.0 * (-radius2 / 2.5).exp();
                    for channel in 0..channels {
                        let index = ((y as u32 * width + x as u32) * channels + channel) as usize;
                        data[index] += flux as f32;
                    }
                }
            }
        }
    }

    let mut header = FitsHeader::new();
    header.set_string("OBJECT", "NGC 7000");
    header.set_string("FILTER", "L");
    header.set_string("DATE-OBS", "2026-08-16T03:14:15");
    header.set_float("EXPTIME", 300.0);
    header.set_float("CRVAL1", 314.75);
    header.set_float("CRVAL2", 44.5);
    header.set_float("CRPIX1", (width as f64 + 1.0) / 2.0);
    header.set_float("CRPIX2", (height as f64 + 1.0) / 2.0);
    header.set_float("CD1_1", -0.000_5);
    header.set_float("CD1_2", 0.0);
    header.set_float("CD2_1", 0.0);
    header.set_float("CD2_2", 0.000_5);
    header.set_string("CTYPE1", "RA---TAN");
    header.set_string("CTYPE2", "DEC--TAN");

    let image = ImageData::from_f32(width, height, channels, &data);
    let path = dir.join(name);
    write_fits(&path, &image, &header).expect("the synthetic master must write");
    path
}

/// A recipe payload in the wire form the engine reads.
fn recipe_json(id: &str, base_ref: &str, steps: Value) -> String {
    json!({
        "id": id,
        "schemaVersion": RECIPE_SCHEMA_VERSION,
        "baseMasterRef": base_ref,
        "createdBy": "user",
        "steps": steps,
    })
    .to_string()
}

/// A stretch step whose points bracket the synthetic master's own range.
fn stretch_step() -> Value {
    json!({
        "opId": "stretch",
        "opVersion": 1,
        "params": {"blackPoint": 800.0, "whitePoint": 3000.0, "d": 1.5},
        "enabled": true,
    })
}

fn parse(text: &str) -> Value {
    serde_json::from_str(text).expect("the reply must be JSON")
}

// ---------------------------------------------------------------------------
// validate
// ---------------------------------------------------------------------------

#[test]
fn validate_accepts_a_registered_recipe_and_reports_the_master() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "validate.fits", 64, 64, 1);
    let recipe = recipe_json("r-validate", "master:validate", json!([stretch_step()]));

    let reply = parse(
        &api_darkroom_validate(
            recipe,
            json!({"masterPath": master.to_string_lossy()}).to_string(),
        )
        .expect("validation must run"),
    );

    assert_eq!(reply["ok"], json!(true), "reply: {reply}");
    assert!(reply["error"].is_null());
    assert_eq!(reply["steps"][0]["registered"], json!(true));
    assert_eq!(reply["steps"][0]["stage"], json!("stretched"));
    assert_eq!(reply["base"]["channels"], json!(1));
    assert_eq!(reply["base"]["hasWcs"], json!(true));
}

/// A crop step in the wire form the engine reads.
fn crop_step(x: u32, y: u32, width: u32, height: u32, enabled: bool) -> Value {
    json!({
        "opId": "crop",
        "opVersion": 1,
        "params": {"x": x, "y": y, "width": width, "height": height},
        "enabled": enabled,
    })
}

#[test]
fn validate_reports_a_crop_the_master_cannot_hold() {
    // The import case: a sidecar written over a 1920x1080 master, replayed over
    // a 64x64 one. The recipe is valid — it renders — and silently frames
    // something else, so the answer is a finding, not `ok: false`.
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "fit.fits", 64, 64, 1);
    let recipe = recipe_json(
        "r-crop-fit",
        "master:fit",
        json!([crop_step(0, 0, 1920, 1080, true)]),
    );

    let reply = parse(
        &api_darkroom_validate(
            recipe,
            json!({"masterPath": master.to_string_lossy()}).to_string(),
        )
        .expect("validation must run"),
    );

    assert_eq!(reply["ok"], json!(true), "reply: {reply}");
    assert_eq!(reply["geometryChecked"], json!(true));
    let finding = &reply["findings"][0];
    assert_eq!(finding["index"], json!(0));
    assert_eq!(finding["kind"], json!("cropDoesNotFit"));
    assert_eq!(
        finding["requested"],
        json!({"x": 0, "y": 0, "width": 1920, "height": 1080})
    );
    assert_eq!(
        finding["applied"],
        json!({"x": 0, "y": 0, "width": 64, "height": 64})
    );
    assert!(
        finding["message"]
            .as_str()
            .is_some_and(|m| m.contains("does not fit the 64x64 image")),
        "finding: {finding}"
    );
}

#[test]
fn validate_reports_nothing_for_a_crop_that_fits_and_follows_the_geometry_down() {
    // Two crops in a row: the second is measured against what the first leaves,
    // not against the master, which is the only way a chained recipe can be
    // judged. The first fits, the second asks for more than 32x32 holds.
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "chain.fits", 64, 64, 1);
    let fits_recipe = recipe_json(
        "r-crop-ok",
        "master:chain",
        json!([crop_step(0, 0, 32, 32, true)]),
    );
    let reply = parse(
        &api_darkroom_validate(
            fits_recipe,
            json!({"masterPath": master.to_string_lossy()}).to_string(),
        )
        .expect("validation must run"),
    );
    assert_eq!(reply["geometryChecked"], json!(true));
    assert_eq!(reply["findings"], json!([]), "reply: {reply}");

    let chained = recipe_json(
        "r-crop-chain",
        "master:chain",
        json!([crop_step(0, 0, 32, 32, true), crop_step(0, 0, 64, 64, true)]),
    );
    let reply = parse(
        &api_darkroom_validate(
            chained,
            json!({"masterPath": master.to_string_lossy()}).to_string(),
        )
        .expect("validation must run"),
    );
    let findings = reply["findings"].as_array().expect("findings is a list");
    assert_eq!(findings.len(), 1, "reply: {reply}");
    assert_eq!(findings[0]["index"], json!(1));
    assert_eq!(findings[0]["imageWidth"], json!(32));
}

#[test]
fn validate_leaves_a_disabled_crop_alone_and_says_when_it_checked_nothing() {
    // A disabled step is not on the render path: it frames nothing and moves no
    // geometry. And without a master there is no geometry to check at all,
    // which `geometryChecked` states rather than letting an empty list imply a
    // clean bill of health.
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "disabled.fits", 64, 64, 1);
    let recipe = recipe_json(
        "r-crop-off",
        "master:disabled",
        json!([crop_step(0, 0, 1920, 1080, false)]),
    );

    let reply = parse(
        &api_darkroom_validate(
            recipe.clone(),
            json!({"masterPath": master.to_string_lossy()}).to_string(),
        )
        .expect("validation must run"),
    );
    assert_eq!(reply["geometryChecked"], json!(true));
    assert_eq!(reply["findings"], json!([]), "reply: {reply}");

    let reply =
        parse(&api_darkroom_validate(recipe, "{}".to_string()).expect("validation must run"));
    assert_eq!(reply["geometryChecked"], json!(false));
    assert_eq!(reply["findings"], json!([]));
}

#[test]
fn validate_names_every_bad_step_rather_than_only_the_first() {
    let recipe = recipe_json(
        "r-bad",
        "master:bad",
        json!([
            {"opId": "no_such_op", "opVersion": 1, "params": {}, "enabled": true},
            {"opId": "denoise", "opVersion": 1, "params": {"strength": 9.0}, "enabled": true},
        ]),
    );

    let reply =
        parse(&api_darkroom_validate(recipe, "{}".to_string()).expect("validation must run"));

    assert_eq!(reply["ok"], json!(false));
    assert_eq!(reply["steps"][0]["registered"], json!(false));
    assert_eq!(reply["steps"][1]["registered"], json!(true));
    assert_eq!(reply["steps"][1]["valid"], json!(false));
    assert!(
        reply["steps"][1]["error"]
            .as_str()
            .is_some_and(|text| text.contains("strength")),
        "reply: {reply}"
    );
}

#[test]
fn validate_rejects_a_linear_step_after_a_stretch() {
    let recipe = recipe_json(
        "r-order",
        "master:order",
        json!([
            stretch_step(),
            {"opId": "denoise", "opVersion": 1, "params": {}, "enabled": true},
        ]),
    );

    let reply =
        parse(&api_darkroom_validate(recipe, "{}".to_string()).expect("validation must run"));

    assert_eq!(reply["ok"], json!(false));
    assert!(
        reply["error"]
            .as_str()
            .is_some_and(|text| text.contains("linear-stage")),
        "reply: {reply}"
    );
}

#[test]
fn a_disabled_step_this_build_cannot_run_is_flagged_yet_still_renders() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "disabled-unknown.fits", 64, 64, 1);
    let recipe = recipe_json(
        "r-disabled-unknown",
        "master:disabled-unknown",
        json!([
            stretch_step(),
            {"opId": "no_such_op", "opVersion": 7, "params": {}, "enabled": false},
        ]),
    );

    let reply = parse(
        &api_darkroom_validate(recipe.clone(), "{}".to_string()).expect("validation must run"),
    );
    assert_eq!(
        reply["ok"],
        json!(true),
        "a step that will not run blocks no render: {reply}"
    );
    assert!(reply["error"].is_null(), "reply: {reply}");
    assert_eq!(reply["steps"][0]["registered"], json!(true));
    assert_eq!(
        reply["steps"][1]["registered"],
        json!(false),
        "the step is still named as one this build cannot run: {reply}"
    );
    assert_eq!(reply["steps"][1]["enabled"], json!(false));

    let preview = api_darkroom_render_preview(
        recipe,
        json!({"masterPath": master.to_string_lossy()}).to_string(),
    )
    .expect("the enabled prefix renders over the disabled step");

    let report = parse(&preview.report_json);
    assert_eq!(report["report"]["steps"][0]["outcome"], json!("applied"));
    assert_eq!(report["report"]["steps"][1]["outcome"], json!("disabled"));
    assert_eq!(report["report"]["hasSkips"], json!(false));
}

#[test]
fn validate_refuses_a_payload_that_is_not_a_recipe() {
    let error = api_darkroom_validate("{\"nope\": 1}".to_string(), "{}".to_string())
        .expect_err("a payload with no schema version is not a recipe");
    assert!(error.contains("schemaVersion"), "error: {error}");
}

// ---------------------------------------------------------------------------
// preview
// ---------------------------------------------------------------------------

#[test]
fn preview_returns_the_rgba_buffer_the_viewer_takes() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "preview.fits", 64, 64, 1);
    let recipe = recipe_json("r-preview", "master:preview", json!([stretch_step()]));

    let preview = api_darkroom_render_preview(
        recipe,
        json!({"masterPath": master.to_string_lossy()}).to_string(),
    )
    .expect("the preview must render");

    assert_eq!(preview.width, 64);
    assert_eq!(preview.height, 64);
    assert!(!preview.is_color);
    assert_eq!(preview.rgba.len(), 64 * 64 * 4);
    assert!(
        preview
            .rgba
            .as_chunks::<4>()
            .0
            .iter()
            .all(|pixel| pixel[3] == 255),
        "every pixel is opaque"
    );
    assert!(
        preview
            .rgba
            .as_chunks::<4>()
            .0
            .iter()
            .any(|pixel| pixel[0] > 0),
        "a stretched star field is not black"
    );

    let report = parse(&preview.report_json);
    assert_eq!(report["report"]["steps"][0]["outcome"], json!("applied"));
    assert_eq!(report["encoding"]["applied"], json!("unit"));
    assert_eq!(report["encoding"]["sourceDomain"], json!("stretched"));
    assert_eq!(report["level"]["level"], json!(0));
}

#[test]
fn preview_renders_the_pyramid_level_a_viewport_needs() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "level.fits", 256, 192, 1);
    let recipe = recipe_json("r-level", "master:level", json!([stretch_step()]));

    let preview = api_darkroom_render_preview(
        recipe,
        json!({"masterPath": master.to_string_lossy(), "maxDimension": 128}).to_string(),
    )
    .expect("the preview must render");

    let report = parse(&preview.report_json);
    assert_eq!(report["level"]["level"], json!(1));
    assert_eq!(preview.width, 128);
    assert_eq!(preview.height, 96);
    assert_eq!(report["level"]["scaleFromMaster"], json!(0.5));
}

#[test]
fn preview_stopping_after_a_step_renders_only_that_prefix() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "stop.fits", 64, 64, 1);
    let recipe = recipe_json(
        "r-stop",
        "master:stop",
        json!([
            {"opId": "denoise", "opVersion": 1, "params": {}, "enabled": true},
            stretch_step(),
        ]),
    );

    let preview = api_darkroom_render_preview(
        recipe,
        json!({
            "masterPath": master.to_string_lossy(),
            "stopAfter": 0,
            "encoding": "screen",
        })
        .to_string(),
    )
    .expect("the preview must render");

    let report = parse(&preview.report_json);
    assert_eq!(report["report"]["steps"].as_array().map(Vec::len), Some(1));
    assert_eq!(report["report"]["steps"][0]["opId"], json!("denoise"));
    assert_eq!(report["stopAfter"], json!(0));
    assert_eq!(report["encoding"]["sourceDomain"], json!("linear"));
}

#[test]
fn preview_of_a_linear_stack_names_the_screen_transfer_it_applied() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "linear.fits", 64, 64, 1);
    let recipe = recipe_json("r-linear", "master:linear", json!([]));

    let preview = api_darkroom_render_preview(
        recipe,
        json!({"masterPath": master.to_string_lossy()}).to_string(),
    )
    .expect("the preview must render");

    let report = parse(&preview.report_json);
    assert_eq!(report["encoding"]["applied"], json!("screen"));
    assert_eq!(report["encoding"]["sourceDomain"], json!("linear"));
    assert_eq!(
        report["encoding"]["screenTransferAffectsRecipe"],
        json!(false)
    );
    assert!(
        report["encoding"]["screenTransfer"]["blackPoint"].is_number(),
        "the transfer names its own parameters: {report}"
    );
}

#[test]
fn preview_records_a_skipped_step_with_the_reason_it_could_not_run() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "skip.fits", 64, 64, 3);
    let recipe = recipe_json(
        "r-skip",
        "master:skip",
        json!([{"opId": "color_calibrate", "opVersion": 1, "params": {}, "enabled": true}]),
    );

    let preview = api_darkroom_render_preview(
        recipe,
        json!({"masterPath": master.to_string_lossy()}).to_string(),
    )
    .expect("a skipped step is not a failed render");

    assert!(preview.is_color);
    let report = parse(&preview.report_json);
    assert_eq!(report["report"]["steps"][0]["outcome"], json!("skipped"));
    assert_eq!(report["report"]["hasSkips"], json!(true));
    assert_eq!(report["catalogStars"], json!(0));
    assert!(
        report["report"]["steps"][0]["reason"]
            .as_str()
            .is_some_and(|reason| !reason.is_empty()),
        "a skip states its reason: {report}"
    );
}

#[test]
fn preview_reports_the_channel_scales_a_colour_step_applied() {
    // The read-back the draft pins from. A pinned step reads no catalogue and no
    // plate solve, so this exercises the whole path — entry point, engine, step
    // report — with nothing to fit and nothing to be flaky about.
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "pinned.fits", 64, 64, 3);
    let recipe = recipe_json(
        "r-pinned",
        "master:pinned",
        json!([
            {"opId": "denoise", "opVersion": 1, "params": {}, "enabled": true},
            {
                "opId": "color_calibrate",
                "opVersion": 1,
                "params": {"channelScale": [1.5, 1.0, 0.8]},
                "enabled": true,
            },
        ]),
    );

    let preview = api_darkroom_render_preview(
        recipe,
        json!({"masterPath": master.to_string_lossy()}).to_string(),
    )
    .expect("a pinned balance renders with no photometry");

    let report = parse(&preview.report_json);
    let colour = &report["report"]["steps"][1];
    assert_eq!(colour["opId"], json!("color_calibrate"));
    assert_eq!(colour["outcome"], json!("applied"));
    assert_eq!(colour["measured"]["source"], json!("pinned"));
    assert_eq!(colour["measured"]["channelScale"], json!([1.5, 1.0, 0.8]));
    assert!(
        report["report"]["steps"][0].get("measured").is_none(),
        "an operation whose parameters describe its result reports no measurement: {report}"
    );
}

#[test]
fn preview_refuses_an_encoding_it_does_not_know() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "encoding.fits", 64, 64, 1);
    let recipe = recipe_json("r-encoding", "master:encoding", json!([]));

    let error = api_darkroom_render_preview(
        recipe,
        json!({"masterPath": master.to_string_lossy(), "encoding": "eyeball"}).to_string(),
    )
    .expect_err("an unknown encoding is refused, never defaulted");
    assert!(error.contains("eyeball"), "error: {error}");
}

// ---------------------------------------------------------------------------
// cancellation
// ---------------------------------------------------------------------------

#[test]
fn a_cancelled_preview_returns_the_typed_cancelled_shape() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "cancel.fits", 64, 64, 1);
    let render_id = "darkroom-test-cancel-preview";

    let armed = parse(
        &api_darkroom_cancel(json!({"renderId": render_id}).to_string())
            .expect("pre-arming must succeed"),
    );
    assert_eq!(armed["cancelRequested"], json!(true));
    assert_eq!(armed["running"], json!(false));

    let recipe = recipe_json("r-cancel", "master:cancel", json!([stretch_step()]));
    let error = api_darkroom_render_preview(
        recipe,
        json!({"masterPath": master.to_string_lossy(), "renderId": render_id}).to_string(),
    )
    .expect_err("a pre-armed render stops at its first check");

    let outcome = parse(&error);
    assert_eq!(outcome["kind"], json!("cancelled"));
    assert_eq!(outcome["renderId"], json!(render_id));
    assert!(outcome["phase"].is_string(), "outcome: {outcome}");
}

#[test]
fn a_cancelled_export_writes_nothing_and_says_it_was_cancelled() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "cancel-export.fits", 64, 64, 1);
    let out = dir.path().join("cancelled.fits");
    let render_id = "darkroom-test-cancel-export";
    api_darkroom_cancel(json!({"renderId": render_id}).to_string()).expect("pre-arm");

    let recipe = recipe_json("r-cancel-x", "master:cancel-x", json!([stretch_step()]));
    let error = api_darkroom_render_export(
        recipe,
        json!({
            "masterPath": master.to_string_lossy(),
            "renderId": render_id,
            "stage": {"kind": "final"},
            "outputs": [{"format": "fits", "path": out.to_string_lossy()}],
        })
        .to_string(),
    )
    .expect_err("a pre-armed export stops before it writes");

    let outcome = parse(&error);
    assert_eq!(outcome["kind"], json!("cancelled"));
    assert!(!out.exists(), "a cancelled export leaves no file behind");
}

#[test]
fn late_cancels_for_renders_that_never_start_do_not_block_a_new_render() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "cancel-flood.fits", 32, 32, 1);

    // The two shapes that arrive in the field: the dawn autopilot cancels a
    // queued job that will never render, and the editor cancels an id that
    // raced its own completion. Neither is ever claimed by a render, so each
    // one is a pre-arm nothing removes.
    let flood: Vec<String> = (0..MAX_TRACKED_RENDERS + 8)
        .map(|i| format!("darkroom-flood-{i}"))
        .collect();
    for id in flood.iter().take(MAX_TRACKED_RENDERS) {
        api_darkroom_cancel(json!({"renderId": id}).to_string())
            .expect("a cancel for a render that never started is always accepted");
    }

    // A brand-new render must still run: a registry full of stale pre-arms is
    // never a reason to refuse work the operator just asked for.
    let fresh = "darkroom-flood-fresh";
    let recipe = recipe_json("r-flood", "master:flood", json!([stretch_step()]));
    let preview = api_darkroom_render_preview(
        recipe,
        json!({"masterPath": master.to_string_lossy(), "renderId": fresh}).to_string(),
    )
    .expect("a new render is not refused by the cancel registry");
    assert!(preview.width > 0 && preview.height > 0);

    // And the cancels themselves keep being accepted past the cap.
    for id in flood.iter().skip(MAX_TRACKED_RENDERS) {
        api_darkroom_cancel(json!({"renderId": id}).to_string())
            .expect("a late cancel is still accepted once the registry is full");
    }

    for id in &flood {
        let _ = api_darkroom_cancel(json!({"op": "clear", "renderId": id}).to_string());
    }
}

#[test]
fn cancel_status_and_clear_round_trip() {
    let render_id = "darkroom-test-status";
    api_darkroom_cancel(json!({"renderId": render_id}).to_string()).expect("cancel");

    let status = parse(
        &api_darkroom_cancel(json!({"op": "status", "renderId": render_id}).to_string())
            .expect("status"),
    );
    assert_eq!(status["cancelRequested"], json!(true));

    let cleared = parse(
        &api_darkroom_cancel(json!({"op": "clear", "renderId": render_id}).to_string())
            .expect("clear"),
    );
    assert_eq!(cleared["cancelRequested"], json!(false));

    let after = parse(
        &api_darkroom_cancel(json!({"op": "status", "renderId": render_id}).to_string())
            .expect("status"),
    );
    assert_eq!(after["cancelRequested"], json!(false));

    let error = api_darkroom_cancel(json!({"op": "levitate", "renderId": render_id}).to_string())
        .expect_err("an unknown op is refused");
    assert!(error.contains("levitate"), "error: {error}");
}

// ---------------------------------------------------------------------------
// export
// ---------------------------------------------------------------------------

#[test]
fn export_writes_the_recipe_into_the_fits_and_beside_it() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "export.fits", 64, 64, 1);
    let out = dir.path().join("final.fits");
    let recipe = recipe_json("r-export", "master:export", json!([stretch_step()]));

    let reply = parse(
        &api_darkroom_render_export(
            recipe.clone(),
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": "final"},
                "outputs": [{"format": "fits", "path": out.to_string_lossy()}],
            })
            .to_string(),
        )
        .expect("the export must run"),
    );

    assert_eq!(reply["stage"]["kind"], json!("final"));
    assert_eq!(reply["outputs"][0]["format"], json!("fits"));
    assert_eq!(reply["outputs"][0]["pixelType"], json!("f32"));
    assert!(out.exists());

    let (_, header) = read_fits(&out).expect("the exported master must read back");
    assert_eq!(header.get_string("NSSTAGE"), Some("final"));
    assert_eq!(
        header.get_string("NSRECIPE"),
        reply["recipeFingerprint"].as_str()
    );
    assert_eq!(header.get_int("NSRECSTP"), Some(1));
    assert_eq!(
        header.get_int("NSRECVER"),
        Some(i64::from(RECIPE_SCHEMA_VERSION))
    );
    assert_eq!(header.get_string("OBJECT"), Some("NGC 7000"));
    assert_eq!(header.get_float("CRVAL1"), Some(314.75));

    let recovered = recipe_from_history(&header.history)
        .expect("the recipe reads back out of the HISTORY cards");
    let expected = canonical_json(&parse(&recipe));
    assert_eq!(recovered, expected);
    assert_eq!(
        fingerprint_hex(recovered.as_bytes()),
        reply["recipeFingerprint"]
            .as_str()
            .expect("the reply names the recipe fingerprint")
    );
    assert!(
        header
            .history
            .iter()
            .any(|line| line.contains("stretch@1 applied")),
        "the readable lines name each step: {:?}",
        header.history
    );

    let sidecar_path = reply["sidecarPath"]
        .as_str()
        .expect("a sidecar is written beside the FITS");
    assert!(sidecar_path.ends_with("final.fits.nsrecipe"));
    let sidecar = parse(&std::fs::read_to_string(sidecar_path).expect("sidecar reads"));
    assert_eq!(sidecar["kind"], json!("nsrecipe"));
    assert_eq!(
        sidecar["fingerprint"].as_str(),
        reply["recipeFingerprint"].as_str()
    );
    assert_eq!(sidecar["canonicalRecipe"], json!(expected));
}

#[test]
fn the_exported_history_states_a_crop_the_render_had_to_shrink() {
    // The exported file is the copy that outlives the session, and "applied"
    // alone was the same word a faithfully applied crop earned. The recipe
    // itself still records the rectangle that was asked for — the sidecar and
    // the payload cards are the determinism contract and do not move.
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "clamped.fits", 64, 64, 1);
    let out = dir.path().join("clamped_final.fits");
    let recipe = recipe_json(
        "r-clamped",
        "master:clamped",
        json!([crop_step(0, 0, 1920, 1080, true)]),
    );

    let reply = parse(
        &api_darkroom_render_export(
            recipe,
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": "final"},
                "outputs": [{"format": "fits", "path": out.to_string_lossy()}],
            })
            .to_string(),
        )
        .expect("the export must run"),
    );

    assert_eq!(reply["outputs"][0]["width"], json!(64));
    assert_eq!(reply["outputs"][0]["height"], json!(64));
    let step = &reply["report"]["steps"][0];
    assert_eq!(step["outcome"], json!("applied"));
    assert_eq!(step["measured"]["clampedToImage"]["imageWidth"], json!(64));
    assert_eq!(
        step["measured"]["clampedToImage"]["requested"],
        json!({"x": 0, "y": 0, "width": 1920, "height": 1080})
    );

    let (_, header) = read_fits(&out).expect("the exported master must read back");
    let line = header
        .history
        .iter()
        .find(|line| line.contains("crop@1 applied"))
        .unwrap_or_else(|| panic!("no crop step line: {:?}", header.history));
    assert!(
        line.contains("clampedToImage"),
        "the exported HISTORY must state the adjustment, not only 'applied': {line}"
    );
}

#[test]
fn the_exported_summary_line_carries_the_whole_fingerprint() {
    // The summary line runs past column 80 — a digest halved at the card
    // boundary cannot be matched against `NSRECIPE` or against the sidecar, and
    // that is what a reader has to do to know which recipe made these pixels.
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "fingerprint.fits", 64, 64, 1);
    let out = dir.path().join("fingerprint-export.fits");
    let recipe = recipe_json(
        "r-fingerprint-summary",
        "master:fingerprint",
        json!([stretch_step()]),
    );

    let reply = parse(
        &api_darkroom_render_export(
            recipe,
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": "final"},
                "outputs": [{"format": "fits", "path": out.to_string_lossy()}],
            })
            .to_string(),
        )
        .expect("the export must run"),
    );
    let fingerprint = reply["recipeFingerprint"]
        .as_str()
        .expect("the reply names the recipe fingerprint");

    let (_, header) = read_fits(&out).expect("the exported master must read back");
    let summary = header
        .history
        .iter()
        .find(|line| line.starts_with("Skotiq Darkroom:"))
        .unwrap_or_else(|| panic!("no Darkroom summary line: {:?}", header.history));
    assert!(
        summary.len() > 72,
        "this test only proves anything on a line that overruns a card: {summary:?}"
    );
    assert!(
        summary.ends_with(&format!("fingerprint={fingerprint}")),
        "the summary line lost part of the fingerprint: {summary:?}"
    );
    assert_eq!(header.get_string("NSRECIPE"), Some(fingerprint));

    let sidecar = parse(
        &std::fs::read_to_string(
            reply["sidecarPath"]
                .as_str()
                .expect("a sidecar is written beside the FITS"),
        )
        .expect("sidecar reads"),
    );
    assert_eq!(sidecar["fingerprint"].as_str(), Some(fingerprint));
}

#[test]
fn export_of_the_linear_stage_writes_the_masters_own_pixels() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "linear-source.fits", 64, 64, 1);
    let out = dir.path().join("linear-master.fits");
    let recipe = recipe_json("r-linear-x", "master:linear-x", json!([stretch_step()]));

    let reply = parse(
        &api_darkroom_render_export(
            recipe,
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": "linear"},
                "outputs": [{"format": "fits", "path": out.to_string_lossy()}],
            })
            .to_string(),
        )
        .expect("the export must run"),
    );

    assert_eq!(reply["stage"]["kind"], json!("linear"));
    assert_eq!(reply["report"]["steps"], json!([]));

    let (source, _) = read_fits(&master).expect("master reads");
    let (written, header) = read_fits(&out).expect("export reads");
    assert_eq!(written.data, source.data, "linear export is a passthrough");
    assert_eq!(header.get_string("NSSTAGE"), Some("linear"));
    assert!(
        header
            .history
            .iter()
            .any(|line| line.contains("Linear master passthrough")),
        "the export says no step ran: {:?}",
        header.history
    );
}

#[test]
fn the_linear_stage_exports_a_master_whose_recipe_the_engine_refuses() {
    // Measured against the release bundle: a `whitePoint` below the step's own
    // `blackPoint` refused a LINEAR export — the stage that replays nothing and
    // records the recipe as not applied. A step this stage does not apply
    // cannot refuse the master's own pixels. The recipe still travels with the
    // file, faults and all, because that is what provenance is.
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "refused-source.fits", 64, 64, 1);
    let out = dir.path().join("refused-linear.fits");
    let recipe = recipe_json(
        "r-refused",
        "master:refused",
        json!([{
            "opId": "stretch",
            "opVersion": 1,
            "params": {"blackPoint": 800.0, "whitePoint": 100.0, "d": 1.5},
            "enabled": true,
        }]),
    );

    // The stack really is refused — the stages that replay it say so, in the
    // engine's own sentence. Without this the test would pass just as happily
    // over a recipe nothing objected to.
    let refusal = api_darkroom_render_export(
        recipe.clone(),
        json!({
            "masterPath": master.to_string_lossy(),
            "stage": {"kind": "final"},
            "outputs": [{"format": "fits", "path": dir.path().join("refused-final.fits").to_string_lossy()}],
        })
        .to_string(),
    )
    .expect_err("the final stage replays the step, so the step refuses it");
    assert!(
        refusal.contains("whitePoint"),
        "the replaying stage must be refused by the step itself: {refusal}"
    );
    assert!(
        !dir.path().join("refused-final.fits").exists(),
        "a refused export writes nothing"
    );

    let reply = parse(
        &api_darkroom_render_export(
            recipe.clone(),
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": "linear"},
                "outputs": [{"format": "fits", "path": out.to_string_lossy()}],
            })
            .to_string(),
        )
        .expect("the linear stage writes the master's own pixels"),
    );

    assert_eq!(reply["stage"]["kind"], json!("linear"));
    assert_eq!(reply["report"]["steps"], json!([]));

    let (source, _) = read_fits(&master).expect("master reads");
    let (written, header) = read_fits(&out).expect("export reads");
    assert_eq!(written.data, source.data, "linear export is a passthrough");
    assert!(
        header
            .history
            .iter()
            .any(|line| line.contains("Linear master passthrough")),
        "the export says no step ran: {:?}",
        header.history
    );
    // The refused recipe rides along as provenance, in the file and beside it.
    let expected = canonical_json(&parse(&recipe));
    assert_eq!(
        recipe_from_history(&header.history)
            .expect("the refused recipe is carried in the HISTORY payload"),
        expected,
        "the recipe travels as it stands, not as the engine wishes it were"
    );
    let sidecar = parse(
        &std::fs::read_to_string(
            reply["sidecarPath"]
                .as_str()
                .expect("a sidecar is written beside the FITS"),
        )
        .expect("sidecar reads"),
    );
    assert_eq!(
        sidecar["canonicalRecipe"].as_str(),
        Some(expected.as_str()),
        "the sidecar carries the same recipe the file does"
    );
}

#[test]
fn export_after_a_step_stops_the_stack_there() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "stage-source.fits", 64, 64, 1);
    let out = dir.path().join("stage.fits");
    let recipe = recipe_json(
        "r-stage",
        "master:stage",
        json!([
            {"opId": "denoise", "opVersion": 1, "params": {}, "enabled": true},
            stretch_step(),
        ]),
    );

    let reply = parse(
        &api_darkroom_render_export(
            recipe,
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": "afterStep", "index": 0},
                "outputs": [{"format": "fits", "path": out.to_string_lossy()}],
            })
            .to_string(),
        )
        .expect("the export must run"),
    );

    assert_eq!(reply["stage"], json!({"kind": "afterStep", "index": 0}));
    assert_eq!(reply["report"]["steps"].as_array().map(Vec::len), Some(1));
    assert_eq!(reply["sourceDomain"], json!("linear"));

    let (_, header) = read_fits(&out).expect("export reads");
    assert_eq!(header.get_string("NSSTAGE"), Some("afterStep:0"));
}

#[test]
fn the_exported_history_numbers_steps_from_one() {
    // Every other surface counts this recipe's steps from 1 — the editor's step
    // list, the export sheet's own suggested filename, and the validation
    // sentences in `RecipeError` — so a HISTORY line naming "step 0" is naming
    // a step the operator cannot find anywhere else.
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "numbering-source.fits", 64, 64, 1);
    let out = dir.path().join("numbering.fits");
    let recipe = recipe_json(
        "r-numbering",
        "master:numbering",
        json!([
            crop_step(0, 0, 32, 32, true),
            {"opId": "denoise", "opVersion": 1, "params": {}, "enabled": true},
            stretch_step(),
        ]),
    );

    api_darkroom_render_export(
        recipe,
        json!({
            "masterPath": master.to_string_lossy(),
            "stage": {"kind": "final"},
            "outputs": [{"format": "fits", "path": out.to_string_lossy()}],
        })
        .to_string(),
    )
    .expect("the export must run");

    let (_, header) = read_fits(&out).expect("export reads");
    let steps: Vec<&String> = header
        .history
        .iter()
        .filter(|line| line.trim_start().starts_with("step "))
        .collect();
    assert_eq!(
        steps.len(),
        3,
        "one readable line per step: {:?}",
        header.history
    );
    assert!(
        steps[0].contains("step 1: crop@1 applied"),
        "the first step is step 1: {steps:?}"
    );
    assert!(
        steps[1].contains("step 2: denoise@1 applied"),
        "the second step is step 2: {steps:?}"
    );
    assert!(
        steps[2].contains("step 3: stretch@1 applied"),
        "the third step is step 3: {steps:?}"
    );
    assert!(
        !header
            .history
            .iter()
            .any(|line| line.trim_start().starts_with("step 0:")),
        "no line counts from 0: {:?}",
        header.history
    );
}

#[test]
fn the_stage_card_keeps_the_request_index_and_translates_it_for_a_reader() {
    // `NSSTAGE` is the machine token: the same index the caller sent in
    // `stage.index`, the same index the reply and the sidecar echo. It stays
    // 0-based so a file written by any build means one thing, and the human
    // summary line beside it carries the 1-based number the operator sees
    // everywhere else.
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "stage-wire-source.fits", 64, 64, 1);
    let out = dir.path().join("stage-wire.fits");
    let recipe = recipe_json(
        "r-stage-wire",
        "master:stage-wire",
        json!([
            crop_step(0, 0, 32, 32, true),
            {"opId": "denoise", "opVersion": 1, "params": {}, "enabled": true},
            stretch_step(),
        ]),
    );

    let reply = parse(
        &api_darkroom_render_export(
            recipe.clone(),
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": "afterStep", "index": 0},
                "outputs": [{"format": "fits", "path": out.to_string_lossy()}],
            })
            .to_string(),
        )
        .expect("the export must run"),
    );

    assert_eq!(reply["stage"], json!({"kind": "afterStep", "index": 0}));
    let (_, header) = read_fits(&out).expect("export reads");
    assert_eq!(header.get_string("NSSTAGE"), Some("afterStep:0"));
    let sidecar = parse(
        &std::fs::read_to_string(
            reply["sidecarPath"]
                .as_str()
                .expect("a sidecar is written beside the FITS"),
        )
        .expect("sidecar reads"),
    );
    assert_eq!(sidecar["stage"], json!({"kind": "afterStep", "index": 0}));

    let summary = header
        .history
        .iter()
        .find(|line| line.starts_with("Skotiq Darkroom:"))
        .unwrap_or_else(|| panic!("no Darkroom summary line: {:?}", header.history));
    assert!(
        summary.contains("stage=afterStep:0 (through step 1 of 3)"),
        "the summary line carries the token and its human reading: {summary:?}"
    );
    assert!(
        header
            .history
            .iter()
            .any(|line| line.contains("step 1: crop@1 applied")),
        "the step line counts from 1: {:?}",
        header.history
    );

    // Both ways: a reader that splits the token off an existing file recovers
    // the exact request the export ran, and re-running it writes the same card.
    let token = header.get_string("NSSTAGE").expect("the card is present");
    let (kind, index) = token.split_once(':').expect("afterStep carries an index");
    let recovered: usize = index.parse().expect("the token's index is a number");
    let replay = dir.path().join("stage-wire-replay.fits");
    let replayed = parse(
        &api_darkroom_render_export(
            recipe,
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": kind, "index": recovered},
                "outputs": [{"format": "fits", "path": replay.to_string_lossy()}],
            })
            .to_string(),
        )
        .expect("the replayed export must run"),
    );
    assert_eq!(replayed["stage"], reply["stage"]);
    let (replayed_pixels, replayed_header) = read_fits(&replay).expect("replay reads");
    let (original_pixels, _) = read_fits(&out).expect("original reads");
    assert_eq!(replayed_header.get_string("NSSTAGE"), Some("afterStep:0"));
    assert_eq!(
        replayed_pixels.data, original_pixels.data,
        "the token names the same stage of the same stack"
    );
}

#[test]
fn export_refuses_an_eight_bit_file_of_linear_pixels() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "refuse-source.fits", 64, 64, 1);
    let out = dir.path().join("refused.png");
    let recipe = recipe_json("r-refuse", "master:refuse", json!([]));

    let error = api_darkroom_render_export(
        recipe,
        json!({
            "masterPath": master.to_string_lossy(),
            "stage": {"kind": "final"},
            "outputs": [{"format": "png", "path": out.to_string_lossy()}],
        })
        .to_string(),
    )
    .expect_err("linear pixels have no display mapping");

    assert!(error.contains("screenTransfer"), "error: {error}");
    assert!(!out.exists());
}

#[test]
fn export_writes_every_raster_format_from_the_engines_own_pixels() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "raster-source.fits", 64, 64, 1);
    let png = dir.path().join("out.png");
    let jpeg = dir.path().join("out.jpg");
    let tiff = dir.path().join("out.tif");
    let recipe = recipe_json("r-raster", "master:raster", json!([stretch_step()]));

    let reply = parse(
        &api_darkroom_render_export(
            recipe,
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": "final"},
                "outputs": [
                    {"format": "png", "path": png.to_string_lossy()},
                    {"format": "jpeg", "path": jpeg.to_string_lossy(), "quality": 85},
                    {"format": "tiff", "path": tiff.to_string_lossy()},
                ],
            })
            .to_string(),
        )
        .expect("the export must run"),
    );

    for path in [&png, &jpeg, &tiff] {
        assert!(path.exists(), "{} must exist", path.display());
        let size = std::fs::metadata(path).expect("stat").len();
        assert!(size > 0, "{} must carry bytes", path.display());
    }
    assert_eq!(reply["outputs"][0]["bitsPerSample"], json!(16));
    assert_eq!(reply["outputs"][1]["quality"], json!(85));
    assert_eq!(reply["sourceDomain"], json!("stretched"));
    assert!(reply["screenTransfer"].is_null());
    assert_eq!(
        reply["sidecarSkippedReason"],
        json!("no FITS output to place the sidecar beside and no sidecarPath given")
    );
}

#[test]
fn export_with_a_screen_transfer_names_the_transfer_it_used() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "screen-source.fits", 64, 64, 1);
    let png = dir.path().join("screen.png");
    let sidecar = dir.path().join("screen.nsrecipe");
    let recipe = recipe_json("r-screen", "master:screen", json!([]));

    let reply = parse(
        &api_darkroom_render_export(
            recipe,
            json!({
                "masterPath": master.to_string_lossy(),
                "stage": {"kind": "final"},
                "screenTransfer": true,
                "sidecarPath": sidecar.to_string_lossy(),
                "outputs": [{"format": "png", "path": png.to_string_lossy()}],
            })
            .to_string(),
        )
        .expect("the export must run"),
    );

    assert!(png.exists());
    assert!(sidecar.exists());
    assert_eq!(reply["sourceDomain"], json!("linear"));
    assert!(
        reply["screenTransfer"]["whitePoint"].is_number(),
        "reply: {reply}"
    );
    assert_eq!(reply["screenTransferAffectsRecipe"], json!(false));
}

#[test]
fn export_refuses_a_request_that_writes_nothing() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "empty-out.fits", 64, 64, 1);
    let recipe = recipe_json("r-empty", "master:empty", json!([]));

    let error = api_darkroom_render_export(
        recipe,
        json!({"masterPath": master.to_string_lossy(), "outputs": []}).to_string(),
    )
    .expect_err("an export with no output is refused");
    assert!(error.contains("outputs"), "error: {error}");
}

// ---------------------------------------------------------------------------
// registry
// ---------------------------------------------------------------------------

#[test]
fn registry_publishes_every_registered_operation() {
    let reply = parse(&api_darkroom_registry("{}".to_string()).expect("the catalogue must build"));
    let registry = OpRegistry::builtin().expect("the builtin registry must build");

    let ops = reply["ops"].as_array().expect("ops is a list");
    assert_eq!(ops.len(), registry.len());
    for op in ops {
        let id = op["id"].as_str().expect("id");
        let version = op["version"].as_u64().expect("version") as u32;
        let registered = registry
            .get(id, version)
            .unwrap_or_else(|| panic!("{id}@{version} is documented and must be registered"));
        assert_eq!(op["stage"], json!(registered.stage().as_wire()));
        assert!(op["params"].is_array());
        assert!(op["defaults"].is_object());
    }
    assert_eq!(
        reply["cacheBudget"]["renderBytes"],
        json!(super::state::RENDER_CACHE_CAPACITY_BYTES)
    );
}

#[test]
fn every_registered_operation_is_documented() {
    let registry = OpRegistry::builtin().expect("the builtin registry must build");
    for (id, version) in registry.keys() {
        assert!(
            OP_DOCS
                .iter()
                .any(|doc| doc.id == id && doc.version == version),
            "{id}@{version} is registered and must carry a schema row"
        );
    }
}

#[test]
fn the_published_schema_matches_each_operations_own_validation() {
    let registry = OpRegistry::builtin().expect("the builtin registry must build");
    for doc in OP_DOCS {
        let op = registry
            .get(doc.id, doc.version)
            .unwrap_or_else(|| panic!("{}@{} must be registered", doc.id, doc.version));
        let example = example_params(doc).expect("the example payload must parse");
        op.validate_params(&example).unwrap_or_else(|error| {
            panic!(
                "{}@{} rejects its own example: {error}",
                doc.id, doc.version
            )
        });

        let mut unknown = example.clone();
        unknown["notAParameterOfThisOperation"] = json!(1);
        assert!(
            op.validate_params(&unknown).is_err(),
            "{}@{} must reject an undeclared key",
            doc.id,
            doc.version
        );

        for param in doc.params {
            let mut without = example.clone();
            let object = without.as_object_mut().expect("example is an object");
            object.remove(param.name);
            let verdict = op.validate_params(&without);
            if param.required {
                assert!(
                    verdict.is_err(),
                    "{}@{}: '{}' is documented as required and must be rejected when absent",
                    doc.id,
                    doc.version,
                    param.name
                );
            } else {
                verdict.unwrap_or_else(|error| {
                    panic!(
                        "{}@{}: '{}' is documented as optional and must be accepted when absent: {error}",
                        doc.id, doc.version, param.name
                    )
                });
            }

            if !param.independent {
                continue;
            }
            if let (Some(min), Some(max)) = (param.min, param.max) {
                for (value, accepted) in [
                    (bounded(param, min), true),
                    (bounded(param, max), true),
                    (bounded(param, min - 1.0), false),
                    (bounded(param, max + 1.0), false),
                ] {
                    let mut probe = example.clone();
                    probe[param.name] = value.clone();
                    let verdict = op.validate_params(&probe);
                    assert_eq!(
                        verdict.is_ok(),
                        accepted,
                        "{}@{}: '{}' at {value} must be {}",
                        doc.id,
                        doc.version,
                        param.name,
                        if accepted { "accepted" } else { "rejected" }
                    );
                }
            }
            if param.kind == ParamKind::Enumerated {
                for token in param.allowed {
                    let mut probe = example.clone();
                    probe[param.name] = json!(token);
                    op.validate_params(&probe).unwrap_or_else(|error| {
                        panic!(
                            "{}@{}: '{token}' is documented as allowed: {error}",
                            doc.id, doc.version
                        )
                    });
                }
                let mut probe = example.clone();
                probe[param.name] = json!("notAnAllowedToken");
                assert!(
                    op.validate_params(&probe).is_err(),
                    "{}@{}: an undocumented token must be rejected",
                    doc.id,
                    doc.version
                );
            }
        }
    }
}

#[test]
fn every_parameter_publishes_a_human_display_name() {
    let reply = parse(&api_darkroom_registry("{}".to_string()).expect("the catalogue must build"));
    let ops = reply["ops"].as_array().expect("the catalogue is an array");
    let mut checked = 0usize;
    for op in ops {
        for param in op["params"].as_array().expect("params is an array") {
            let wire = param["name"].as_str().expect("a parameter names its key");
            let shown = param["displayName"]
                .as_str()
                .unwrap_or_else(|| panic!("{wire} publishes no displayName"));
            assert!(
                !shown.is_empty(),
                "{wire} publishes an empty displayName, which labels no control"
            );
            // The point of the field: a control labelled with the wire key asks
            // the operator to know the engine's own vocabulary. A row that just
            // repeats the key has not been written.
            assert_ne!(
                shown, wire,
                "{wire} repeats its wire key as its display name"
            );
            checked += 1;
        }
    }
    assert!(checked >= 20, "only {checked} parameters were checked");
}

#[test]
fn the_stretch_states_the_unit_its_points_are_measured_in() {
    let reply = parse(&api_darkroom_registry("{}".to_string()).expect("the catalogue must build"));
    let ops = reply["ops"].as_array().expect("the catalogue is an array");
    let stretch = ops
        .iter()
        .find(|op| op["id"] == json!("stretch"))
        .expect("stretch is registered");
    for key in ["blackPoint", "whitePoint"] {
        let param = stretch["params"]
            .as_array()
            .expect("params is an array")
            .iter()
            .find(|p| p["name"] == json!(key))
            .unwrap_or_else(|| panic!("stretch documents {key}"));
        // The bounds are +/-1e12, which is the engine's accepted range and not
        // an ADU range any master occupies. The unit is what tells the operator
        // that 529.74 is a plausible value and 0.5 is not.
        assert!(
            param["displayName"]
                .as_str()
                .expect("a display name")
                .contains("ADU"),
            "{key} states no unit, so its +/-1e12 bounds read as an ADU range"
        );
    }
}

/// One probe value in the shape the parameter's kind takes.
fn bounded(param: &super::schema::ParamDoc, value: f64) -> Value {
    match param.kind {
        ParamKind::Integer => {
            if value < 0.0 {
                json!(value)
            } else {
                json!(value as u64)
            }
        }
        ParamKind::NumberArray => {
            let length = param
                .length
                .expect("a numberArray parameter documents its element count");
            json!(vec![value; length])
        }
        _ => json!(value),
    }
}

#[test]
fn registry_drafts_a_recipe_that_validates_against_this_build() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "draft.fits", 512, 512, 1);

    let reply = parse(
        &api_darkroom_registry(
            json!({
                "masterPath": master.to_string_lossy(),
                "recipeId": "draft-1",
                "baseMasterRef": "master:draft",
            })
            .to_string(),
        )
        .expect("the draft must build"),
    );

    let draft = &reply["draft"]["recipe"];
    assert_eq!(draft["createdBy"], json!("autopilot"));
    assert_eq!(draft["id"], json!("draft-1"));
    let steps = draft["steps"].as_array().expect("steps");
    assert!(!steps.is_empty(), "reply: {reply}");
    assert_eq!(
        steps.last().map(|step| step["opId"].clone()),
        Some(json!("stretch")),
        "the draft ends in the stretch it measured: {reply}"
    );
    assert!(reply["draft"]["autoParams"]["cropRect"]["width"].is_number());
    assert!(reply["draft"]["autoParams"]["stretch"]["blackPoint"].is_number());
    assert!(reply["draft"]["autoParams"]["defaults"]["denoise"]["strength"].is_number());
    assert!(
        reply["draft"]["notes"].as_array().is_some_and(|notes| notes
            .iter()
            .any(|note| note["opId"] == json!("color_calibrate"))),
        "a mono master records why the colour fit is left out: {reply}"
    );

    let verdict = parse(
        &api_darkroom_validate(draft.to_string(), "{}".to_string()).expect("validation must run"),
    );
    assert_eq!(verdict["ok"], json!(true), "verdict: {verdict}");
}

#[test]
fn a_drafted_recipe_renders_over_its_own_master() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_master(dir.path(), "draft-render.fits", 512, 512, 1);
    let reply = parse(
        &api_darkroom_registry(
            json!({"masterPath": master.to_string_lossy(), "recipeId": "draft-2"}).to_string(),
        )
        .expect("the draft must build"),
    );

    let preview = api_darkroom_render_preview(
        reply["draft"]["recipe"].to_string(),
        json!({"masterPath": master.to_string_lossy(), "maxDimension": 256}).to_string(),
    )
    .expect("the drafted recipe must render");

    let report = parse(&preview.report_json);
    let steps = report["report"]["steps"].as_array().expect("steps");
    assert!(
        steps
            .iter()
            .all(|step| step["outcome"] != json!("skipped") || step["reason"].is_string()),
        "every skip carries its reason: {report}"
    );
    assert_eq!(report["encoding"]["sourceDomain"], json!("stretched"));
}

// ---------------------------------------------------------------------------
// A failure an operator can read, and a cache that cannot confuse two masters
// ---------------------------------------------------------------------------

/// Write a file of the given length holding nothing but NUL bytes — what a torn
/// write or a lost extent leaves where a master used to be.
fn write_nul_file(dir: &Path, name: &str, len: usize) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, vec![0u8; len]).expect("the corrupt master must write");
    path
}

/// Every Darkroom entry point states why a corrupt master failed.
///
/// A blank reason is the failure mode this guards: the night report tells the
/// operator no draft came out and that the report says why, and then says
/// nothing. The reason travels out of here as a Rust `String` that becomes a C
/// string, so a single NUL byte in it costs the whole sentence.
#[test]
fn a_corrupt_master_fails_with_a_reason_an_operator_can_read() {
    let dir = tempfile::tempdir().expect("temp dir");
    let master = write_nul_file(dir.path(), "all-nul.fits", 2880 * 4);
    let path = master.to_string_lossy().to_string();
    let recipe = recipe_json("nul-master", &path, json!([stretch_step()]));
    let context = json!({"masterPath": path, "maxDimension": 256}).to_string();

    let failures = vec![
        (
            "validate",
            api_darkroom_validate(recipe.clone(), context.clone()).err(),
        ),
        (
            "renderPreview",
            api_darkroom_render_preview(recipe, context)
                .err()
                .map(|e| e.to_string()),
        ),
        (
            "registry",
            api_darkroom_registry(json!({"masterPath": path}).to_string()).err(),
        ),
    ];

    for (entry_point, failure) in failures {
        let reason = failure.unwrap_or_else(|| panic!("{entry_point} must fail on a NUL master"));
        assert!(
            !reason.trim().is_empty(),
            "{entry_point} states a cause rather than failing blank"
        );
        assert!(
            !reason.contains('\0'),
            "{entry_point} carries no NUL into the reason: {reason:?}"
        );
        assert!(
            reason.contains(&path),
            "{entry_point} names the master it could not read: {reason}"
        );
        assert!(
            reason.contains("NUL") && reason.contains("not a FITS header"),
            "{entry_point} names what it found: {reason}"
        );
    }
}

/// One recipe replayed over two masters returns each master's own pixels.
///
/// The step-boundary cache is process-global and keyed per render. Keyed on the
/// recipe's `baseMasterRef` alone, the second request — same recipe id, same
/// ref, a different `masterPath` of the same geometry — hits the first master's
/// boundary and is served the first master's pixels while the reply names the
/// second master's path.
#[test]
fn one_recipe_over_two_masters_renders_each_masters_pixels() {
    let dir = tempfile::tempdir().expect("temp dir");
    let first = write_master(dir.path(), "shared-a.fits", 256, 256, 1);
    let second = write_master_seeded(
        dir.path(),
        "shared-b.fits",
        256,
        256,
        1,
        0x0BAD_F00D_1234_5678,
    );
    let first_path = first.to_string_lossy().to_string();
    let second_path = second.to_string_lossy().to_string();

    // Ground truth: two distinct recipe ids, so no cache entry can be shared.
    let truth_a = api_darkroom_render_preview(
        recipe_json("truth-a", &first_path, json!([stretch_step()])),
        json!({"masterPath": first_path, "maxDimension": 128}).to_string(),
    )
    .expect("the first master must render");
    let truth_b = api_darkroom_render_preview(
        recipe_json("truth-b", &second_path, json!([stretch_step()])),
        json!({"masterPath": second_path, "maxDimension": 128}).to_string(),
    )
    .expect("the second master must render");
    assert_ne!(
        truth_a.rgba, truth_b.rgba,
        "the two masters must genuinely differ for this test to mean anything"
    );

    // One recipe, whose ref names the first master, rendered over both.
    let shared = recipe_json("shared-id", &first_path, json!([stretch_step()]));
    let over_first = api_darkroom_render_preview(
        shared.clone(),
        json!({"masterPath": first_path, "maxDimension": 128}).to_string(),
    )
    .expect("the shared recipe must render over the first master");
    let over_second = api_darkroom_render_preview(
        shared,
        json!({"masterPath": second_path, "maxDimension": 128}).to_string(),
    )
    .expect("the shared recipe must render over the second master");

    assert_eq!(
        over_first.rgba, truth_a.rgba,
        "the first request renders the master it named"
    );
    assert_eq!(
        over_second.rgba, truth_b.rgba,
        "the second request renders the master it named, not the cached first one"
    );
}

/// The reason guard itself: nothing blank, and nothing unprintable, ever leaves
/// here.
#[test]
fn a_cause_is_never_blank_and_never_carries_control_bytes() {
    use super::state::readable_cause;

    assert_eq!(
        readable_cause(""),
        "the underlying error carried no message",
        "an error with no text is named as having none rather than passed on blank"
    );
    assert_eq!(
        readable_cause("   "),
        "the underlying error carried no message"
    );
    assert_eq!(
        readable_cause("Invalid FITS keyword: \0\0\0"),
        "Invalid FITS keyword: \\x00\\x00\\x00"
    );
    assert_eq!(readable_cause("no such file"), "no such file");
}
