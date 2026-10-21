//! An opt-in driver that drafts and renders real masters through the Darkroom's
//! production entry points.
//!
//! It calls [`api_darkroom_registry`] and [`api_darkroom_render_export`], the
//! entry points the dawn autopilot calls through the bridge, so the run
//! exercises the same draft composition and the same operations. Each master's
//! draft is exported after every step as a JPEG, so a defect can be pinned to
//! the step that introduced it.
//!
//! `#[ignore]`d by default: the masters are not in the repo and the run takes
//! minutes.
//!
//! ```text
//! DARKROOM_MASTERS=/path/to/masters DARKROOM_OUT=/path/to/out \
//!   cargo test -p skotiq_bridge --release -- --ignored --nocapture darkroom_real
//! ```

use super::*;

fn real_masters() -> (Vec<String>, String) {
    let dir = std::env::var("DARKROOM_MASTERS")
        .expect("set DARKROOM_MASTERS to the directory holding the masters");
    let out = std::env::var("DARKROOM_OUT").expect("set DARKROOM_OUT to a writable directory");
    std::fs::create_dir_all(&out).expect("create output directory");
    let mut masters: Vec<String> = std::fs::read_dir(&dir)
        .expect("read masters directory")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("fits"))
        .map(|p| p.to_string_lossy().into_owned())
        .collect();
    masters.sort();
    assert!(!masters.is_empty(), "no FITS masters under {dir}");
    (masters, out)
}

fn export_steps(recipe: &serde_json::Value, master: &str, out: &str, stem: &str) {
    let steps = recipe["steps"].as_array().map(Vec::len).unwrap_or(0);
    for index in 0..steps {
        let op = recipe["steps"][index]["opId"].as_str().unwrap_or("step");
        let path = format!("{out}/{stem}_step{}_{op}.jpg", index + 1);
        let args = serde_json::json!({
            "masterPath": master,
            "stage": {"kind": "afterStep", "index": index},
            "outputs": [{"format": "jpeg", "path": path, "quality": 90}],
            "writeSidecar": false,
            "screenTransfer": true,
        });
        let started = std::time::Instant::now();
        match api_darkroom_render_export(recipe.to_string(), args.to_string()) {
            Ok(_) => eprintln!(
                "[darkroom_real] {stem} step {} ({op}) in {:.1}s",
                index + 1,
                started.elapsed().as_secs_f64()
            ),
            Err(e) => panic!(
                "[darkroom_real] {stem} step {} ({op}) failed: {e}",
                index + 1
            ),
        }
    }
}

/// Draft every master on its own and export each step.
#[test]
#[ignore = "needs real masters; set DARKROOM_MASTERS and DARKROOM_OUT"]
fn darkroom_real_single_master_drafts() {
    let (masters, out) = real_masters();
    for master in &masters {
        let stem = std::path::Path::new(master)
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("master")
            .to_string();
        let reply = api_darkroom_registry(
            serde_json::json!({"masterPath": master, "recipeId": stem}).to_string(),
        )
        .expect("draft a master");
        let reply: serde_json::Value = serde_json::from_str(&reply).expect("registry reply");
        let recipe = &reply["draft"]["recipe"];
        eprintln!(
            "[darkroom_real] {stem}: draft {}\n  notes {}",
            recipe["steps"], reply["draft"]["notes"]
        );
        export_steps(recipe, master, &out, &stem);
    }
}

/// Render one recipe over one master and write the requested outputs.
///
/// `DARKROOM_RECIPE` is a recipe JSON file, `DARKROOM_EXPORT` an export args
/// JSON file (as `api_darkroom_render_export` takes it).
#[test]
#[ignore = "needs a real master; set DARKROOM_RECIPE and DARKROOM_EXPORT"]
fn darkroom_real_export_recipe() {
    let recipe =
        std::fs::read_to_string(std::env::var("DARKROOM_RECIPE").expect("DARKROOM_RECIPE"))
            .expect("read recipe");
    let args = std::fs::read_to_string(std::env::var("DARKROOM_EXPORT").expect("DARKROOM_EXPORT"))
        .expect("read export args");
    let started = std::time::Instant::now();
    let reply = api_darkroom_render_export(recipe, args).expect("export");
    eprintln!(
        "[darkroom_real] exported in {:.1}s: {reply}",
        started.elapsed().as_secs_f64()
    );
}

/// Draft every master in `DARKROOM_MASTERS` as one color composite, prove and
/// pin the color step the way the dawn draft builder does, and export each
/// step, the linear composite and the final draft.
#[test]
#[ignore = "needs real masters; set DARKROOM_MASTERS and DARKROOM_OUT"]
fn darkroom_real_composite() {
    let (masters, out) = real_masters();
    let inputs: Vec<serde_json::Value> = masters
        .iter()
        .map(|path| serde_json::json!({"path": path}))
        .collect();
    let started = std::time::Instant::now();
    let reply = api_darkroom_registry(
        serde_json::json!({"recipeId": "composite", "composite": {"inputs": inputs}}).to_string(),
    )
    .expect("draft the composite");
    eprintln!(
        "[darkroom_real] composite drafted in {:.1}s",
        started.elapsed().as_secs_f64()
    );
    let reply: serde_json::Value = serde_json::from_str(&reply).expect("registry reply");
    std::fs::write(
        format!("{out}/composite_registry_reply.json"),
        serde_json::to_string_pretty(&serde_json::json!({
            "composite": reply["composite"],
            "draft": reply["draft"],
            "masterPath": reply["masterPath"],
        }))
        .unwrap(),
    )
    .expect("write reply");
    assert_eq!(
        reply["composite"]["combined"], true,
        "{}",
        reply["composite"]
    );
    let worst = reply["composite"]["worstMedianOffsetPx"]
        .as_f64()
        .expect("a registration check");
    assert!(
        worst < 0.3,
        "star centroids differ by {worst} px between channels"
    );
    let master = reply["masterPath"]
        .as_str()
        .expect("a reference master")
        .to_string();
    let mut recipe = reply["draft"]["recipe"].clone();

    // The color proof the dawn draft builder runs when no catalogue star is
    // available: balance on the field's stars at full resolution, then pin.
    let steps = recipe["steps"].as_array().cloned().unwrap_or_default();
    if let Some(index) = steps.iter().position(|s| s["opId"] == "color_calibrate") {
        recipe["steps"][index]["params"]["whiteReference"] = serde_json::json!("averageStar");
        let preview = api_darkroom_render_preview(
            recipe.to_string(),
            serde_json::json!({"masterPath": master, "level": 0, "stopAfter": index, "encoding": "unit"})
                .to_string(),
        )
        .expect("prove the color step");
        let report: serde_json::Value = serde_json::from_str(&preview.report_json).unwrap();
        let measured = &report["report"]["steps"][index]["measured"];
        eprintln!("[darkroom_real] color proof: {measured}");
        recipe["steps"][index]["params"]["channelScale"] = measured["channelScale"].clone();
        recipe["steps"][index]["params"]["channelOffset"] = measured["channelOffset"].clone();
        let stretch = steps
            .iter()
            .position(|s| s["opId"] == "stretch")
            .expect("a stretch");
        let preview = api_darkroom_render_preview(
            recipe.to_string(),
            serde_json::json!({"masterPath": master, "maxDimension": 1024, "stopAfter": stretch - 1, "encoding": "screen"})
                .to_string(),
        )
        .expect("remeasure the stretch");
        let report: serde_json::Value = serde_json::from_str(&preview.report_json).unwrap();
        let transfer = &report["encoding"]["screenTransfer"];
        for key in ["blackPoint", "whitePoint", "d", "b", "symmetryPoint"] {
            recipe["steps"][stretch]["params"][key] = transfer[key].clone();
        }
    }
    std::fs::write(
        format!("{out}/composite_recipe.json"),
        serde_json::to_string_pretty(&recipe).unwrap(),
    )
    .expect("write recipe");
    export_steps(&recipe, &master, &out, "composite");

    let linear = format!("{out}/composite_linear.fits");
    let args = serde_json::json!({
        "masterPath": master,
        "stage": {"kind": "afterStep", "index": 0},
        "outputs": [{"format": "fits", "path": linear}],
        "writeSidecar": false,
    });
    api_darkroom_render_export(recipe.to_string(), args.to_string()).expect("export linear");
    if let Some(index) = recipe["steps"]
        .as_array()
        .and_then(|s| s.iter().position(|s| s["opId"] == "color_calibrate"))
    {
        let args = serde_json::json!({
            "masterPath": master,
            "stage": {"kind": "afterStep", "index": index},
            "outputs": [{"format": "fits", "path": format!("{out}/composite_calibrated.fits")}],
            "writeSidecar": false,
        });
        api_darkroom_render_export(recipe.to_string(), args.to_string())
            .expect("export calibrated");
    }
    let final_fits = format!("{out}/composite_final.fits");
    let args = serde_json::json!({
        "masterPath": master,
        "stage": {"kind": "final"},
        "outputs": [{"format": "fits", "path": final_fits}, {"format": "jpeg", "path": format!("{out}/composite_final.jpg"), "quality": 92}],
        "writeSidecar": true,
        "sidecarPath": format!("{out}/composite_final.skrecipe"),
    });
    let reply =
        api_darkroom_render_export(recipe.to_string(), args.to_string()).expect("export final");
    eprintln!("[darkroom_real] final export: {reply}");
    let (image, _) =
        skotiq_imaging::read_fits(std::path::Path::new(&final_fits)).expect("read final");
    assert_eq!(image.channels, 3);
    let pixels = image.as_f32().expect("float pixels");
    let n = pixels.len() / 3;
    let clipped = pixels.iter().filter(|v| **v >= 1.0).count() as f64 / pixels.len() as f64;
    assert!(clipped < 0.01, "{:.3}% of samples clipped", clipped * 100.0);
    // The darker half of the frame is sky; its channels agree within 10%.
    let mut means: Vec<(f32, usize)> = (0..n)
        .map(|i| {
            (
                (pixels[i * 3] + pixels[i * 3 + 1] + pixels[i * 3 + 2]) / 3.0,
                i,
            )
        })
        .collect();
    means.sort_by(|a, b| a.0.total_cmp(&b.0));
    let sky = &means[..n / 2];
    let level = |c: usize| {
        let mut v: Vec<f32> = sky.iter().map(|(_, i)| pixels[i * 3 + c]).collect();
        v.sort_by(f32::total_cmp);
        v[v.len() / 2]
    };
    let (r, g, b) = (level(0), level(1), level(2));
    eprintln!("[darkroom_real] sky median r {r:.4} g {g:.4} b {b:.4}, clipped {clipped:.5}");
    for (name, v) in [("red", r), ("blue", b)] {
        assert!((v / g - 1.0).abs() < 0.1, "sky {name}/green = {}", v / g);
    }
}
