//! What an integration pass reports while it runs, for the Darkroom pass view.
//!
//! Every report is one [`ImagingEvent::IntegrationTelemetry`]: the caller's run
//! id, a `kind`, and a JSON object of details, so a new field never needs a
//! bridge regeneration. Reports are emitted from values the pipeline already
//! holds, at most once per sub per stage, plus a running-mean preview that is
//! binned to 1/[`PREVIEW_BIN`] scale and written to disk at most once every
//! [`PREVIEW_INTERVAL`].
//!
//! Kinds the integration emits, in order: `run_started`, `calibrated` (per
//! sub), `reference_choosing`, `reference_chosen`, `registered` (per sub),
//! `weighted`, `normalized` (per accepted sub), `running_preview` (per accepted
//! sub; `path` only when a PNG was written), `integrating`, `integrated`,
//! `written`, and `run_ended` from the entry point. Stages that run after the
//! lanes (channel alignment, color combination) report through
//! [`emit_pass_telemetry`] with the kinds `channel_aligned`, `combine_started`
//! and `combine_done`; the Dart pass view reads all of them.

use super::*;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// Bin factor of the running preview (each preview pixel is the mean of a
/// `PREVIEW_BIN`×`PREVIEW_BIN` block of the reference grid).
pub(crate) const PREVIEW_BIN: usize = 8;

/// The shortest time between two running-preview PNGs.
pub(crate) const PREVIEW_INTERVAL: Duration = Duration::from_secs(2);

/// The telemetry part of an integrate request.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default, rename_all = "camelCase")]
#[flutter_rust_bridge::frb(ignore)]
pub(crate) struct TelemetryArgs {
    /// The lane this run integrates (the filter bucket), echoed in
    /// `run_started`.
    pub(crate) lane: Option<String>,
    /// Directory for preview PNGs. Without it no preview is computed or
    /// written; every other report is still emitted.
    pub(crate) preview_dir: Option<String>,
}

/// Publish one pass report for `run_id`.
pub(crate) fn emit_pass_telemetry(run_id: &str, kind: &str, detail: serde_json::Value) {
    get_state().publish_imaging_event(
        ImagingEvent::IntegrationTelemetry {
            run_id: run_id.to_string(),
            kind: kind.to_string(),
            detail_json: detail.to_string(),
        },
        EventSeverity::Info,
    );
}

/// Milliseconds since `since`, for the `ms` field of a report.
pub(crate) fn elapsed_ms(since: Instant) -> u64 {
    since.elapsed().as_millis() as u64
}

/// The file name of `path`, for reports that name a sub.
pub(crate) fn file_name(path: &str) -> String {
    Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or(path)
        .to_string()
}

/// The luminance of channel-interleaved `pixels` binned by `factor`, with the
/// binned width and height. Zero pixels (outside a registered frame's
/// coverage) are left out of their bin's mean.
pub(crate) fn binned_luma(
    pixels: &[f64],
    width: usize,
    height: usize,
    channels: usize,
    factor: usize,
) -> (Vec<f64>, usize, usize) {
    let bw = (width / factor).max(1);
    let bh = (height / factor).max(1);
    let mut sum = vec![0.0f64; bw * bh];
    let mut count = vec![0u32; bw * bh];
    for y in 0..(bh * factor).min(height) {
        let by = y / factor;
        let row = y * width;
        for x in 0..(bw * factor).min(width) {
            let base = (row + x) * channels;
            let mut v = 0.0;
            for c in 0..channels {
                v += pixels[base + c];
            }
            if v == 0.0 {
                continue;
            }
            let bin = by * bw + x / factor;
            sum[bin] += v / channels as f64;
            count[bin] += 1;
        }
    }
    for (s, &n) in sum.iter_mut().zip(count.iter()) {
        if n > 0 {
            *s /= n as f64;
        }
    }
    (sum, bw, bh)
}

/// Per-pixel background noise estimated from a `factor`-binned image: the
/// median absolute difference of horizontal neighbors, scaled to one pixel's
/// sigma. Binning first keeps the estimate honest on resampled frames, whose
/// neighboring pixels the interpolation correlates. A margin of one sixteenth
/// of each side is left out, where registration leaves partial coverage.
pub(crate) fn binned_noise(binned: &[f64], bw: usize, bh: usize, factor: usize) -> Option<f64> {
    let mx = bw / 16;
    let my = bh / 16;
    let mut diffs = Vec::with_capacity(bw * bh / 2);
    for y in (my..bh.saturating_sub(my)).step_by(2) {
        for x in mx..bw.saturating_sub(mx + 1) {
            let a = binned[y * bw + x];
            let b = binned[y * bw + x + 1];
            if a != 0.0 && b != 0.0 {
                diffs.push((a - b).abs());
            }
        }
    }
    if diffs.is_empty() {
        return None;
    }
    let mid = diffs.len() / 2;
    let (_, median, _) = diffs.select_nth_unstable_by(mid, |a, b| a.total_cmp(b));
    Some(*median / (0.6745 * std::f64::consts::SQRT_2) * factor as f64)
}

/// Write a binned plane as an auto-stretched grayscale PNG.
pub(crate) fn write_binned_png(
    binned: &[f64],
    bw: usize,
    bh: usize,
    path: &Path,
) -> Result<(), String> {
    let data: Vec<f32> = binned.iter().map(|&v| v as f32).collect();
    let image = ImageData::from_f32(bw as u32, bh as u32, 1, &data);
    write_preview_png(&image, path)
}

/// The running mean of the subs normalized so far, on the binned grid.
pub(crate) struct RunningPreview {
    dir: Option<PathBuf>,
    lane: String,
    sum: Vec<f64>,
    bw: usize,
    bh: usize,
    subs: u32,
    written: u32,
    last_write: Option<Instant>,
}

impl RunningPreview {
    pub(crate) fn new(args: &TelemetryArgs, width: usize, height: usize) -> Self {
        let dir = args
            .preview_dir
            .as_ref()
            .filter(|d| !d.trim().is_empty())
            .map(PathBuf::from);
        let bw = (width / PREVIEW_BIN).max(1);
        let bh = (height / PREVIEW_BIN).max(1);
        Self {
            sum: if dir.is_some() {
                vec![0.0; bw * bh]
            } else {
                Vec::new()
            },
            dir,
            lane: sanitize(args.lane.as_deref().unwrap_or("lane")),
            bw,
            bh,
            subs: 0,
            written: 0,
            last_write: None,
        }
    }

    pub(crate) fn enabled(&self) -> bool {
        self.dir.is_some()
    }

    /// Fold one normalized sub in and report the running mean: its noise
    /// always, a PNG when [`PREVIEW_INTERVAL`] has passed or `last` is set.
    pub(crate) fn add(
        &mut self,
        run_id: &str,
        pixels: &[f64],
        width: usize,
        height: usize,
        channels: usize,
        last: bool,
    ) {
        let Some(dir) = self.dir.clone() else {
            return;
        };
        let (binned, bw, bh) = binned_luma(pixels, width, height, channels, PREVIEW_BIN);
        if bw != self.bw || bh != self.bh {
            return;
        }
        for (s, v) in self.sum.iter_mut().zip(binned.iter()) {
            *s += v;
        }
        self.subs += 1;
        let mean: Vec<f64> = self.sum.iter().map(|s| s / self.subs as f64).collect();
        let noise = binned_noise(&mean, bw, bh, PREVIEW_BIN);
        let due = self
            .last_write
            .map_or(true, |t| t.elapsed() >= PREVIEW_INTERVAL);
        let mut path = None;
        if due || last {
            self.written += 1;
            let p = dir.join(format!("{}_running_{:03}.png", self.lane, self.written));
            match ensure_parent_dir(&p).and_then(|_| write_binned_png(&mean, bw, bh, &p)) {
                Ok(()) => {
                    path = Some(p.to_string_lossy().into_owned());
                    self.last_write = Some(Instant::now());
                }
                Err(e) => tracing::warn!(error = %e, "running preview PNG write failed"),
            }
        }
        emit_pass_telemetry(
            run_id,
            "running_preview",
            serde_json::json!({ "subs": self.subs, "noise": noise, "path": path }),
        );
    }

    /// Write the reference sub's binned preview; the path, or None.
    pub(crate) fn write_reference(&self, image: &ImageData) -> Option<String> {
        let dir = self.dir.as_ref()?;
        let pixels = image_to_f64(image);
        let (binned, bw, bh) = binned_luma(
            &pixels,
            image.width as usize,
            image.height as usize,
            image.channels as usize,
            PREVIEW_BIN,
        );
        let p = dir.join(format!("{}_reference.png", self.lane));
        match ensure_parent_dir(&p).and_then(|_| write_binned_png(&binned, bw, bh, &p)) {
            Ok(()) => Some(p.to_string_lossy().into_owned()),
            Err(e) => {
                tracing::warn!(error = %e, "reference preview PNG write failed");
                None
            }
        }
    }
}

/// Report one sub normalized and fold it into the running preview.
#[allow(clippy::too_many_arguments)]
pub(crate) fn report_normalized(
    run_id: &str,
    preview: &mut RunningPreview,
    index: usize,
    pixels: &[f64],
    width: u32,
    height: u32,
    channels: usize,
    last: bool,
) {
    emit_pass_telemetry(
        run_id,
        "normalized",
        serde_json::json!({ "index": index + 1 }),
    );
    preview.add(
        run_id,
        pixels,
        width as usize,
        height as usize,
        channels,
        last,
    );
}

/// The master's binned noise, measured the same way as the running preview's.
pub(crate) fn master_noise(master: &ImageData) -> Option<f64> {
    let pixels = image_to_f64(master);
    let (binned, bw, bh) = binned_luma(
        &pixels,
        master.width as usize,
        master.height as usize,
        master.channels as usize,
        PREVIEW_BIN,
    );
    binned_noise(&binned, bw, bh, PREVIEW_BIN)
}

fn sanitize(lane: &str) -> String {
    let s: String = lane
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    if s.is_empty() {
        "lane".to_string()
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// What the preview costs per sub at this sensor's size, against the
    /// normalization it runs beside. Opt-in: it times work, not behavior.
    ///
    /// `cargo test -p skotiq_bridge --release -- --ignored --nocapture passviz_preview_cost`
    #[test]
    #[ignore = "timing measurement; run by hand in release"]
    fn passviz_preview_cost() {
        let (w, h) = (4656usize, 3520usize);
        let px: Vec<f64> = (0..w * h).map(|i| 1000.0 + (i % 97) as f64).collect();
        let dir = std::env::temp_dir().join("passviz_preview_cost");
        let args = TelemetryArgs {
            lane: Some("L".into()),
            preview_dir: Some(dir.to_string_lossy().into_owned()),
        };
        let mut preview = RunningPreview::new(&args, w, h);
        let n = 16;
        let started = Instant::now();
        for _ in 0..n {
            // Every add writes a PNG here (`last`), the worst case.
            preview.add("bench", &px, w, h, 1, true);
        }
        let per_sub = started.elapsed().as_secs_f64() * 1000.0 / n as f64;
        let started = Instant::now();
        let image = ImageData::from_f32(
            w as u32,
            h as u32,
            1,
            &px.iter().map(|&v| v as f32).collect::<Vec<_>>(),
        );
        let _ = master_noise(&image);
        let master_ms = started.elapsed().as_secs_f64() * 1000.0;
        eprintln!("[passviz] preview per sub {per_sub:.1} ms (PNG every sub); master noise {master_ms:.1} ms");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn binned_luma_averages_blocks_and_skips_uncovered_pixels() {
        // 4×2, one channel, factor 2: blocks [1,2,5,6] and [3,0,7,8].
        let px = [1.0, 2.0, 3.0, 0.0, 5.0, 6.0, 7.0, 8.0];
        let (b, bw, bh) = binned_luma(&px, 4, 2, 1, 2);
        assert_eq!((bw, bh), (2, 1));
        assert_eq!(b[0], 3.5);
        assert_eq!(b[1], 6.0);
    }

    #[test]
    fn binned_noise_recovers_white_noise_sigma() {
        // Deterministic pseudo-normal noise of sigma 10 on a 512×512 grid,
        // binned by 4: the estimate scales back to about 10.
        let (w, h) = (512usize, 512usize);
        let mut state = 12345u64;
        let mut next = || {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            (state >> 11) as f64 / (1u64 << 53) as f64
        };
        let px: Vec<f64> = (0..w * h)
            .map(|_| {
                let (u1, u2) = (next().max(1e-12), next());
                1000.0 + 10.0 * (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
            })
            .collect();
        let (b, bw, bh) = binned_luma(&px, w, h, 1, 4);
        let sigma = binned_noise(&b, bw, bh, 4).expect("noise");
        assert!((sigma - 10.0).abs() < 0.8, "sigma {sigma}");
    }
}
