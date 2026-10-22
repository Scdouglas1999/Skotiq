//! Dark and bias masters built from raw frames on disk, bounded in memory.

use serde::{Deserialize, Serialize};
use skotiq_imaging::calibration_master_stream::{
    build_streamed_master, LightLeakConfig, StreamedMasterConfig, StreamedMasterKind,
};
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BuildCalibrationMasterArgs {
    /// `dark` or `bias`.
    pub kind: String,
    pub frame_paths: Vec<String>,
    pub output_path: String,
    #[serde(default)]
    pub low_sigma: Option<f64>,
    #[serde(default)]
    pub high_sigma: Option<f64>,
    /// Rise over the group's opening frames, in ADU, that counts as a leak.
    #[serde(default)]
    pub leak_min_rise_adu: Option<f64>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FrameLevelJson {
    pub path: String,
    pub level: f64,
    pub noise: f64,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct BuildCalibrationMasterResult {
    pub output_path: String,
    pub kind: String,
    pub width: u32,
    pub height: u32,
    pub frame_count: usize,
    pub leaking_frames: Vec<String>,
    pub frame_levels: Vec<FrameLevelJson>,
    pub leak_baseline: f64,
    pub leak_threshold: f64,
    pub exposure_secs: Option<f64>,
    pub gain: Option<i64>,
    pub offset: Option<i64>,
    pub bin_x: Option<i64>,
    pub bin_y: Option<i64>,
    pub ccd_temp_mean: Option<f64>,
    pub set_temp: Option<f64>,
    pub master_mean: f64,
    pub rejection_fraction: f64,
}

pub(crate) fn build_calibration_master_impl(
    args: BuildCalibrationMasterArgs,
) -> Result<BuildCalibrationMasterResult, String> {
    let kind = match args.kind.trim().to_ascii_lowercase().as_str() {
        "dark" => StreamedMasterKind::Dark,
        "bias" => StreamedMasterKind::Bias,
        other => return Err(format!("kind must be dark or bias, got '{other}'")),
    };
    let mut config = StreamedMasterConfig::new(kind);
    if let Some(v) = args.low_sigma {
        config.low_sigma = v;
    }
    if let Some(v) = args.high_sigma {
        config.high_sigma = v;
    }
    if let Some(v) = args.leak_min_rise_adu {
        config.leak = LightLeakConfig {
            min_rise_adu: v,
            ..config.leak
        };
    }
    if !(config.low_sigma > 0.0 && config.high_sigma > 0.0) {
        return Err("lowSigma and highSigma must be positive".to_string());
    }
    let paths: Vec<PathBuf> = args.frame_paths.iter().map(PathBuf::from).collect();
    let result = build_streamed_master(&paths, &PathBuf::from(&args.output_path), &config)?;
    let text = |p: &PathBuf| p.to_string_lossy().into_owned();
    Ok(BuildCalibrationMasterResult {
        output_path: text(&result.output_path),
        kind: args.kind.trim().to_ascii_lowercase(),
        width: result.width,
        height: result.height,
        frame_count: result.frame_count,
        leaking_frames: result.leaking_frames.iter().map(text).collect(),
        frame_levels: result
            .frame_levels
            .iter()
            .map(|l| FrameLevelJson {
                path: text(&l.path),
                level: l.level,
                noise: l.noise,
            })
            .collect(),
        leak_baseline: result.leak.baseline,
        leak_threshold: result.leak.threshold,
        exposure_secs: result.exposure_secs,
        gain: result.gain,
        offset: result.offset,
        bin_x: result.bin_x,
        bin_y: result.bin_y,
        ccd_temp_mean: result.ccd_temp_mean,
        set_temp: result.set_temp,
        master_mean: result.master_mean,
        rejection_fraction: result.rejection_fraction,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_kind_is_refused() {
        let err = build_calibration_master_impl(BuildCalibrationMasterArgs {
            kind: "flat".into(),
            frame_paths: vec![],
            output_path: "/nonexistent/m.fits".into(),
            low_sigma: None,
            high_sigma: None,
            leak_min_rise_adu: None,
        })
        .unwrap_err();
        assert!(err.contains("dark or bias"), "{err}");
    }

    /// Builds a master from a folder of real frames:
    /// `SKOTIQ_REAL_CAL_DIR=<dir> SKOTIQ_REAL_CAL_KIND=dark cargo test -p skotiq_bridge
    /// real_calibration_master -- --ignored --nocapture`.
    #[test]
    #[ignore = "needs a folder of real calibration frames"]
    fn real_calibration_master() {
        let dir = std::env::var("SKOTIQ_REAL_CAL_DIR").expect("SKOTIQ_REAL_CAL_DIR");
        let kind = std::env::var("SKOTIQ_REAL_CAL_KIND").unwrap_or_else(|_| "dark".into());
        let mut frame_paths: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.path().to_string_lossy().into_owned())
            .filter(|p| p.ends_with(".fits"))
            .collect();
        frame_paths.sort();
        let output_path = std::env::temp_dir()
            .join(format!("real_{kind}_master.fits"))
            .to_string_lossy()
            .into_owned();
        let started = std::time::Instant::now();
        let result = build_calibration_master_impl(BuildCalibrationMasterArgs {
            kind,
            frame_paths,
            output_path,
            low_sigma: None,
            high_sigma: None,
            leak_min_rise_adu: None,
        })
        .unwrap();
        let levels: Vec<String> = result
            .frame_levels
            .iter()
            .map(|l| format!("{:.1}", l.level))
            .collect();
        println!(
            "{} frames in {:.1}s -> {} mean {:.2} rejected {:.3}% leak baseline {:.1} threshold {:.1} leaking {:?}\nlevels {}",
            result.frame_count,
            started.elapsed().as_secs_f64(),
            result.output_path,
            result.master_mean,
            result.rejection_fraction * 100.0,
            result.leak_baseline,
            result.leak_threshold,
            result.leaking_frames,
            levels.join(" ")
        );
    }
}
