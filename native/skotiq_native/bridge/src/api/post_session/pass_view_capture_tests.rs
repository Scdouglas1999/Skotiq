//! An opt-in capture of what one real integration pass measures and when.
//!
//! It runs the production entry point over a night's real subs, one filter at
//! a time, and writes three things per filter into `PASSVIZ_OUT`: the decoded
//! result (`<F>_result.json`, the per-frame records the pass already returns),
//! every `IntegrationProgress` event with the bus timestamp it was published at
//! (`<F>_events.json`), and the master plus its preview and rejection-map PNGs.
//! For the first filter it also integrates the first 2, 4 and 8 subs on their
//! own, so the image can be shown at those depths, and it fits each later
//! filter's master onto the first one's (`channel_alignment.json`).
//!
//! The Darkroom pass-view prototypes are drawn from these files. `#[ignore]`d:
//! it needs frames that are not in the repo and minutes of CPU.
//!
//! ```text
//! PASSVIZ_CAPTURES=/path/to/subs PASSVIZ_OUT=/path/to/out \
//! PASSVIZ_FILTERS=L,R,G,B PASSVIZ_FROM=2026-10-21T02:46 \
//!   cargo test -p skotiq_bridge --release -- --ignored --nocapture passviz
//! ```

use super::*;
use crate::event::EventPayload;
use skotiq_imaging::registration::solve_registration;

fn session_subs(captures: &str, filter: &str, from: &str) -> Vec<(String, f64, String)> {
    let mut subs: Vec<(String, f64, String)> = std::fs::read_dir(captures)
        .expect("read captures directory")
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| {
            let name = p.file_name().and_then(|n| n.to_str()).unwrap_or("");
            p.extension().and_then(|e| e.to_str()) == Some("fits")
                && name.contains(&format!("_{filter}_"))
        })
        .filter_map(|p| {
            let header = read_fits_header(&p).ok()?;
            let date = header.get_string("DATE-OBS")?.trim().to_string();
            let exposure = header.get_float("EXPTIME")?;
            (date.as_str() >= from).then(|| (p.to_string_lossy().into_owned(), exposure, date))
        })
        .collect();
    subs.sort_by(|a, b| a.2.cmp(&b.2));
    subs
}

fn run(
    out_dir: &str,
    tag: &str,
    subs: &[(String, f64, String)],
) -> (serde_json::Value, serde_json::Value) {
    let mut events = get_state().event_bus.subscribe();
    let request = serde_json::json!({
        "runId": format!("passviz-{tag}"),
        "lightPaths": subs.iter().map(|s| s.0.clone()).collect::<Vec<_>>(),
        "reference": "auto",
        "exposuresSec": subs.iter().map(|s| s.1).collect::<Vec<_>>(),
        "calibration": { "cosmeticCorrection": true },
        "output": {
            "masterFitsPath": format!("{out_dir}/{tag}_master.fits"),
            "previewPngPath": format!("{out_dir}/{tag}_preview.png"),
            "rejectionMapPath": format!("{out_dir}/{tag}_rejmap.fits"),
            "rejectionMapPreviewPath": format!("{out_dir}/{tag}_rejmap.png"),
        }
    });
    let started = chrono::Utc::now().timestamp_millis();
    let result = api_integrate_session(request.to_string())
        .unwrap_or_else(|e| panic!("[passviz] {tag}: integrate_session failed: {e}"));
    let mut log = vec![serde_json::json!({ "phase": "start", "t": started })];
    while let Ok(event) = events.try_recv() {
        if let EventPayload::Imaging(ImagingEvent::IntegrationProgress {
            phase,
            fraction,
            frames_done,
            frames_total,
        }) = event.payload
        {
            log.push(serde_json::json!({
                "phase": phase,
                "fraction": fraction,
                "done": frames_done,
                "total": frames_total,
                "t": event.timestamp,
            }));
        }
    }
    let mut result: serde_json::Value = serde_json::from_str(&result).expect("result json");
    result["dateObs"] = subs.iter().map(|s| s.2.clone()).collect::<Vec<_>>().into();
    (result, serde_json::Value::Array(log))
}

/// An F32 master as U16 over its 0.1..99.99 percentile range. A plain
/// min-max rescale lets a few hot pixels flatten every star below the
/// detector's threshold.
fn clipped_u16(image: &ImageData) -> ImageData {
    let data = image.as_f32().unwrap_or_default();
    let mut sample: Vec<f32> = data
        .iter()
        .step_by(97)
        .copied()
        .filter(|v| v.is_finite())
        .collect();
    sample.sort_by(|a, b| a.total_cmp(b));
    let at = |q: f64| sample[((sample.len() - 1) as f64 * q) as usize] as f64;
    let (lo, hi) = (at(0.001), at(0.9999));
    let scaled: Vec<u16> = data
        .iter()
        .map(|&v| (((v as f64 - lo) / (hi - lo)).clamp(0.0, 1.0) * 65535.0).round() as u16)
        .collect();
    ImageData::from_u16(image.width, image.height, image.channels, &scaled)
}

fn write_json(path: &str, value: &serde_json::Value) {
    std::fs::write(path, serde_json::to_string_pretty(value).expect("encode")).expect("write json");
}

#[test]
#[ignore = "needs real frames; set PASSVIZ_CAPTURES and PASSVIZ_OUT"]
fn passviz_capture_real_pass() {
    let captures = std::env::var("PASSVIZ_CAPTURES").expect("set PASSVIZ_CAPTURES");
    let out_dir = std::env::var("PASSVIZ_OUT").expect("set PASSVIZ_OUT");
    let filters = std::env::var("PASSVIZ_FILTERS").unwrap_or_else(|_| "L".to_string());
    let from = std::env::var("PASSVIZ_FROM").unwrap_or_default();
    std::fs::create_dir_all(&out_dir).expect("create output directory");

    let filters: Vec<&str> = filters.split(',').map(str::trim).collect();
    // PASSVIZ_ALIGN_ONLY reuses masters an earlier run wrote.
    let align_only = std::env::var("PASSVIZ_ALIGN_ONLY").is_ok();
    for (index, filter) in filters.iter().enumerate().filter(|_| !align_only) {
        let subs = session_subs(&captures, filter, &from);
        assert!(!subs.is_empty(), "no '{filter}' subs under {captures}");
        eprintln!("[passviz] {filter}: {} subs", subs.len());
        let (result, log) = run(&out_dir, filter, &subs);
        write_json(&format!("{out_dir}/{filter}_result.json"), &result);
        write_json(&format!("{out_dir}/{filter}_events.json"), &log);

        if index == 0 {
            for depth in [2usize, 4, 8] {
                let tag = format!("{filter}_first{depth}");
                let (result, _) = run(&out_dir, &tag, &subs[..depth.min(subs.len())]);
                write_json(&format!("{out_dir}/{tag}_result.json"), &result);
            }
        }
    }

    // Each later filter's master fitted onto the first filter's master: the
    // geometry an align-channels stage would report.
    let anchor_path = format!("{out_dir}/{}_master.fits", filters[0]);
    // Registration reads U16 frames; the masters are F32 in ADU.
    let (anchor, _) = read_fits(Path::new(&anchor_path)).expect("read anchor master");
    let anchor = clipped_u16(&anchor);
    // More anchor stars than a sub-to-sub fit uses: two filters' brightest
    // stars overlap less than two subs of one filter.
    let config = build_registration_config(&AlignArgs {
        max_ref_stars: 60,
        ..AlignArgs::default()
    })
    .expect("config");
    let mut fits = Vec::new();
    for filter in filters.iter().skip(1) {
        let (master, _) =
            read_fits(Path::new(&format!("{out_dir}/{filter}_master.fits"))).expect("read master");
        let master = clipped_u16(&master);
        let started = std::time::Instant::now();
        let entry = match solve_registration(&anchor, &master, &config) {
            Ok((transform, stats)) => serde_json::json!({
                "filter": filter,
                "transform": transform_to_row_major(&transform),
                "referenceStars": stats.reference_star_count,
                "frameStars": stats.frame_star_count,
                "matched": stats.correspondence_count,
                "inliers": stats.inlier_count,
                "rmsPx": stats.rms_residual_px,
                "ms": started.elapsed().as_millis() as u64,
            }),
            Err(e) => serde_json::json!({ "filter": filter, "error": e.to_string() }),
        };
        eprintln!("[passviz] align {filter}: {entry}");
        fits.push(entry);
    }
    write_json(
        &format!("{out_dir}/channel_alignment.json"),
        &serde_json::Value::Array(fits),
    );
}
