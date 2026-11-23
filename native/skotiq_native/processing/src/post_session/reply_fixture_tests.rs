//! The post-session replies, as samples the app's decoders are held to
//! (`test_fixtures/ffi_replies/`; see [`crate::reply_fixtures`]).

use super::args::{IntegrateSessionResult, PerFrameRecord};
use super::calibration_master::{BuildCalibrationMasterResult, FrameLevelJson};
use super::calibration_report::{
    AppliedMaster, CalibrationMismatch, CalibrationReport, CalibrationStaleness, MatchQuality,
};
use super::cancel::{CancelledOutcome, PostSessionCancelResult};
use super::masters::{
    BuildMasterFlatResult, ExcludedFlat, MasterAccumulateResult, SaveFitsMasterResult,
};
use super::multi_night::{
    FoldedSub, GroupSummary, MasterBuildResult, ReferenceFallback, SkippedSub,
};
use super::registration_preview::{FrameFootprint, LimitingFrame, RegistrationPreviewResult};
use crate::reply_fixtures::check_or_write;

fn calibration_report() -> CalibrationReport {
    CalibrationReport {
        masters: vec![
            AppliedMaster {
                kind: "dark".to_string(),
                path: Some("/masters/dark_300s_g100.fits".to_string()),
                applied: true,
                quality: MatchQuality::Acceptable,
                mismatches: vec![CalibrationMismatch {
                    dimension: "temperature".to_string(),
                    light: "-10.0".to_string(),
                    master: "-9.2".to_string(),
                    delta: Some(0.8),
                    tolerance: Some(2.0),
                    within_tolerance: true,
                }],
                unverified: vec!["offset".to_string()],
                staleness: CalibrationStaleness {
                    age_days: Some(41.5),
                    max_age_days: 90.0,
                    temperature_delta_c: Some(0.8),
                    max_temperature_delta_c: Some(2.0),
                    stale: false,
                },
                stale: false,
            },
            AppliedMaster {
                kind: "flat".to_string(),
                path: Some("/masters/flat_L.fits".to_string()),
                applied: true,
                quality: MatchQuality::Exact,
                mismatches: Vec::new(),
                unverified: Vec::new(),
                staleness: CalibrationStaleness {
                    age_days: Some(3.25),
                    max_age_days: 30.0,
                    temperature_delta_c: None,
                    max_temperature_delta_c: None,
                    stale: false,
                },
                stale: false,
            },
            AppliedMaster {
                kind: "bias".to_string(),
                path: None,
                applied: false,
                quality: MatchQuality::NotRequired,
                mismatches: Vec::new(),
                unverified: Vec::new(),
                staleness: CalibrationStaleness {
                    age_days: None,
                    max_age_days: 180.0,
                    temperature_delta_c: None,
                    max_temperature_delta_c: None,
                    stale: false,
                },
                stale: false,
            },
        ],
        cosmetic_correction: true,
        anchor_light: Some("/subs/M31_L_0001.fits".to_string()),
        anchor_unreadable: false,
    }
}

#[test]
fn integrate_session_reply_fixture() {
    check_or_write(
        "integrate_session",
        &IntegrateSessionResult {
            master_fits_path: "/out/M31_L_master.fits".to_string(),
            preview_path: Some("/out/M31_L_master.png".to_string()),
            rejection_map_path: Some("/out/M31_L_rejection.fits".to_string()),
            rejection_map_preview_path: Some("/out/M31_L_rejection.png".to_string()),
            frames_integrated: 37,
            frames_rejected: 3,
            total_integration_sec: 11100.0,
            rms_residual: 0.42,
            width: 6248,
            height: 4176,
            channels: 3,
            per_frame_stats: vec![
                PerFrameRecord {
                    path: "/subs/M31_L_0001.fits".to_string(),
                    weight: 0.87,
                    rms_residual_px: Some(0.31),
                    accepted: true,
                    reason: Some("kept".to_string()),
                    snr: Some(41.2),
                    noise: Some(12.5),
                    background: Some(812.0),
                    star_count: Some(1432),
                    fwhm: Some(2.61),
                    eccentricity: Some(0.38),
                    transform: Some(vec![1.0, 0.002, 3.5, -0.002, 1.0, -1.25, 0.0, 0.0, 1.0]),
                    transform_kind: Some("similarity".to_string()),
                },
                PerFrameRecord {
                    path: "/subs/M31_L_0002.fits".to_string(),
                    weight: 0.0,
                    rms_residual_px: None,
                    accepted: false,
                    reason: Some("registration failed".to_string()),
                    snr: None,
                    noise: None,
                    background: None,
                    star_count: None,
                    fwhm: None,
                    eccentricity: None,
                    transform: None,
                    transform_kind: None,
                },
            ],
            calibration: calibration_report(),
        },
    );
}

#[test]
fn master_accumulate_reply_fixture() {
    check_or_write(
        "master_accumulate",
        &MasterAccumulateResult {
            sidecar_path: "/masters/M31_L.skmaster".to_string(),
            master_path: Some("/masters/M31_L.fits".to_string()),
            preview_path: Some("/masters/M31_L.png".to_string()),
            frame_count: 112,
            total_integration_sec: 33600.0,
            width: 6248,
            height: 4176,
            channels: 3,
            frames_added: 4,
            rejected: 9021,
            frame_weights: vec![0.91, 0.84, 0.77, 0.69],
            calibration: Some(calibration_report()),
            calibration_log_warning: Some("calibration log not writable".to_string()),
        },
    );
}

#[test]
fn build_master_flat_reply_fixture() {
    check_or_write(
        "build_master_flat",
        &BuildMasterFlatResult {
            output_path: "/masters/flat_L.fits".to_string(),
            frame_count: 25,
            input_mean: 21873.5,
            output_mean: 1.0002,
            width: 6248,
            height: 4176,
            channels: 3,
            output_bit_depth: "u16".to_string(),
            excluded: vec![ExcludedFlat {
                path: "/flats/flat_L_0007.fits".to_string(),
                reason: "banded".to_string(),
            }],
        },
    );
}

#[test]
fn save_fits_master_reply_fixture() {
    check_or_write(
        "save_fits_master",
        &SaveFitsMasterResult {
            output_path: "/masters/M31_L_export.fits".to_string(),
            width: 1024,
            height: 768,
            channels: 3,
            pixel_type: "u16".to_string(),
        },
    );
}

#[test]
fn build_calibration_master_reply_fixture() {
    check_or_write(
        "build_calibration_master",
        &BuildCalibrationMasterResult {
            output_path: "/masters/dark_300s_g100.fits".to_string(),
            kind: "dark".to_string(),
            width: 6248,
            height: 4176,
            frame_count: 30,
            leaking_frames: vec!["/darks/dark_0029.fits".to_string()],
            frame_levels: vec![FrameLevelJson {
                path: "/darks/dark_0001.fits".to_string(),
                level: 503.25,
                noise: 9.5,
            }],
            leak_baseline: 503.0,
            leak_threshold: 540.5,
            exposure_secs: Some(300.0),
            gain: Some(100),
            offset: Some(50),
            bin_x: Some(2),
            bin_y: Some(2),
            ccd_temp_mean: Some(-10.1),
            set_temp: Some(-10.0),
            master_mean: 501.75,
            rejection_fraction: 0.0125,
        },
    );
}

#[test]
fn post_session_cancel_reply_fixture() {
    check_or_write(
        "post_session_cancel",
        &PostSessionCancelResult {
            run_id: "run-7".to_string(),
            op: "status".to_string(),
            running: true,
            cancel_requested: true,
        },
    );
    check_or_write(
        "post_session_cancelled",
        &CancelledOutcome {
            kind: super::cancel::CANCELLED_KIND.to_string(),
            run_id: "run-7".to_string(),
            stage: "registration".to_string(),
            frames_done: Some(12),
            frames_total: Some(40),
        },
    );
}

#[test]
fn master_build_reply_fixture() {
    check_or_write(
        "master_build",
        &MasterBuildResult {
            master_path: "/build/M31_Ha_master.fits".to_string(),
            preview_path: Some("/build/M31_Ha_master.png".to_string()),
            filter: Some("Ha".to_string()),
            frame_count: 58,
            total_integration_sec: 17400.0,
            width: 6248,
            height: 4176,
            rejected: 12044,
            coverage_path: Some("/build/M31_Ha_coverage.fits".to_string()),
            median_rms_px: Some(0.27),
            groups: vec![GroupSummary {
                label: "2026-11-20".to_string(),
                offered: 60,
                folded: 58,
                skipped: 2,
                integration_sec: 17400.0,
                calibration: calibration_report(),
                dark_scale: Some(0.98),
            }],
            folded: vec![FoldedSub {
                path: "/subs/M31_Ha_0001.fits".to_string(),
                group: "2026-11-20".to_string(),
                weight: 0.93,
                transparency: Some(0.88),
                noise_ratio: Some(1.04),
                normalization_warning: Some("few stars matched".to_string()),
                stars_matched: 214,
                rms_px: 0.22,
                rotation_deg: 0.015,
                shift_px: [3.5, -1.25],
            }],
            skipped: vec![SkippedSub {
                path: "/subs/M31_Ha_0044.fits".to_string(),
                group: "2026-11-20".to_string(),
                stage: "registration".to_string(),
                reason: "too few stars".to_string(),
            }],
            rejection: "winsorizedSigma".to_string(),
            normalization_reference: "/subs/M31_Ha_0001.fits".to_string(),
            normalization_fallback: Some(ReferenceFallback {
                requested: "/subs/M31_Ha_0003.fits".to_string(),
                used: "/subs/M31_Ha_0001.fits".to_string(),
                reason: "unreadable".to_string(),
            }),
            wcs_source: Some("reference".to_string()),
            drizzle_scale: 2,
            normalization_mode: "starSignal".to_string(),
        },
    );
}

#[test]
fn registration_preview_reply_fixture() {
    check_or_write(
        "registration_preview",
        &RegistrationPreviewResult {
            width: 6248,
            height: 4176,
            frames: vec![FrameFootprint {
                path: "/subs/M31_Ha_0001.fits".to_string(),
                group: "2026-11-20".to_string(),
                side: Some("east".to_string()),
                corners: Some([[1.5, 2.5], [6246.0, 3.0], [6245.5, 4174.0], [2.0, 4173.5]]),
                overlap: Some(0.97),
                rotation_deg: Some(0.12),
                shift_px: Some([3.5, -1.25]),
                stars_matched: Some(214),
                rms_px: Some(0.22),
                failure: Some("none".to_string()),
                included: true,
                reason: Some("within the overlap limit".to_string()),
            }],
            crop: Some([12, 8, 6230, 4160]),
            retained_area: 0.93,
            min_retained_area: 0.8,
            meets_minimum: true,
            limiting: vec![LimitingFrame {
                path: "/subs/M31_Ha_0044.fits".to_string(),
                group: "2026-11-21".to_string(),
                retained_without: 0.96,
            }],
        },
    );
}

#[test]
fn deliver_uniform_reply_fixture() {
    use super::uniform_delivery::{UniformComposites, UniformDelivery, UniformMaster};
    check_or_write(
        "deliver_uniform",
        &UniformDelivery {
            composites: Some(UniformComposites {
                lrgb_path: Some("/out/LRGB_linear.fits".to_string()),
                lrgb_preview_path: Some("/out/LRGB_linear.png".to_string()),
                lrgb_xisf_path: Some("/out/LRGB_linear.xisf".to_string()),
                rgb_path: "/out/RGB_linear.fits".to_string(),
                rgb_preview_path: "/out/RGB_linear.png".to_string(),
                rgb_xisf_path: "/out/RGB_linear.xisf".to_string(),
            }),
            crop: [12, 8, 6230, 4160],
            height: 4152,
            masters: vec![UniformMaster {
                channels: 1,
                filter: "Ha".to_string(),
                path: "/out/Ha_master_linear.fits".into(),
                preview_path: "/out/Ha_master_linear.png".into(),
            }],
            retained_area: 0.93,
            scale: "perFilter",
            width: 6218,
        },
    );
}
