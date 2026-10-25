//! Image grading on the owner's real frames from 2026-09-14, through the same
//! three `DeviceOps` measurements `instructions::expose` grades with and the
//! thresholds the rig ran under:
//!
//! ```text
//! default_quality_check: enabled=true, hfr=Some(3.5), hfr_baseline=Some(50.0),
//!   ecc=Some(0.7), stars=Some(10), max_rejects=3
//! ```
//!
//! That night the grader rejected all five 180 s lights at HFR 15.6–16.0 px and
//! accepted none. Three of them really were trailed (eccentricity 0.82–0.98 by
//! an independent PSF fit), but the grader was not seeing that: it graded the
//! mean HFR of every detection, which reads 13.22 px on an in-focus frame whose
//! stars fit at 1.9 px, so it would have rejected the good frames too.
//!
//! Fixtures are 1024×1024 center crops copied pixel-for-pixel (see
//! `test-fixtures/rig-2026-09-14/manifest.json`); the full frames are graded
//! as well when `~/.cache/sk-rig-data/2026-09-14` is present.

use super::UnifiedDeviceOps;
use skotiq_sequencer::quality::{grade_frame, FrameGrade, FrameMetrics, ImageQualityCheck};
use skotiq_sequencer::{DeviceOps, ImageData};
use std::path::{Path, PathBuf};

fn rig_check() -> ImageQualityCheck {
    ImageQualityCheck {
        hfr_threshold: Some(3.5),
        hfr_baseline_percent: Some(50.0),
        eccentricity_threshold: Some(0.7),
        star_count_min: Some(10),
        star_count_drop_percent: None,
        max_consecutive_rejects: 3,
    }
}

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../test-fixtures/rig-2026-09-14")
}

fn rig_data() -> Option<PathBuf> {
    let root = std::env::var_os("SKOTIQ_RIG_DATA")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|h| {
                // Machines that downloaded the corpus before the rebrand keep it
                // under the old cache directory name.
                let cache = Path::new(&h).join(".cache");
                let fresh = cache.join("sk-rig-data");
                if fresh.is_dir() {
                    fresh
                } else {
                    cache.join("ns-rig-data")
                }
            })
        })?
        .join("2026-09-14");
    root.is_dir().then_some(root)
}

fn load(path: &Path) -> ImageData {
    let (image, _) =
        skotiq_imaging::read_fits(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    ImageData {
        width: image.width,
        height: image.height,
        data: image.as_u16().expect("16-bit frame"),
        bits_per_pixel: 16,
        exposure_secs: 0.0,
        gain: None,
        offset: None,
        temperature: None,
        filter: None,
        timestamp: 0,
        sensor_type: Some("Monochrome".to_string()),
        bayer_offset: None,
    }
}

/// The metrics `instructions::expose` builds before grading a light.
async fn metrics(path: &Path) -> FrameMetrics {
    let ops = UnifiedDeviceOps::new(crate::api::get_state().clone());
    let image = load(path);
    FrameMetrics {
        hfr: ops.calculate_image_hfr(&image).await.expect("hfr"),
        eccentricity: ops.measure_frame_eccentricity(&image).await.expect("ecc"),
        star_count: Some(
            ops.detect_stars_in_image(&image)
                .await
                .expect("stars")
                .len() as u32,
        ),
    }
}

async fn graded(path: &Path) -> (FrameMetrics, FrameGrade) {
    let metrics = metrics(path).await;
    // No baseline: the run never accepted a frame to build one from.
    let grade = grade_frame(&rig_check(), &metrics, None);
    println!("{}: {metrics:?} -> {grade:?}", path.display());
    (metrics, grade)
}

#[tokio::test]
async fn the_in_focus_frame_is_accepted_and_the_trailed_ones_are_not() {
    let dir = fixtures();
    let (focused, grade) = graded(&dir.join("focused_L_0006.fits")).await;
    assert_eq!(
        grade,
        FrameGrade::Pass,
        "an in-focus frame (HFR 2.46 px, e 0.65 by an independent fit) must pass the rig's \
         own thresholds: {focused:?}"
    );
    for file in [
        "trailed_Ha_0001_001.fits",
        "trailed_SII_0001_001.fits",
        "trailed_OIII_0001.fits",
    ] {
        let (metrics, grade) = graded(&dir.join(file)).await;
        assert!(
            grade.is_reject(),
            "{file} is trailed and was accepted: {metrics:?}"
        );
    }
}

#[tokio::test]
async fn an_in_focus_frame_grades_near_its_real_hfr() {
    // The 13.22 px the grader reported for this frame's full version was the
    // mean over 2,427 detections, most of them sitting at 15-16 px.
    let (metrics, _) = graded(&fixtures().join("focused_L_0005.fits")).await;
    let hfr = metrics.hfr.expect("measured");
    assert!(
        (1.8..2.8).contains(&hfr),
        "independent fit 2.12 px, grader {hfr:.2} px"
    );
}

/// The eccentricity limit a profile gets when it never set one, alone, on the
/// owner's frames. Owner, 2026-10-06: "0.7 may be too strict" — his in-focus
/// frames on an f/4 Newtonian measure 0.68 full-frame, and the in-focus crop
/// `focused_L_0005` measures 0.77 (an independent PSF fit agrees: 0.76). The
/// trailed lights measure 0.82 and up, so the limit has to sit between.
#[tokio::test]
async fn the_shipped_eccentricity_limit_passes_focus_and_rejects_trails() {
    let shipped = ImageQualityCheck {
        hfr_threshold: None,
        hfr_baseline_percent: None,
        eccentricity_threshold: Some(skotiq_sequencer::quality::DEFAULT_ECCENTRICITY_THRESHOLD),
        star_count_min: None,
        star_count_drop_percent: None,
        max_consecutive_rejects: 3,
    };
    let dir = fixtures();
    let mut frames = vec![
        (dir.join("focused_L_0005.fits"), true),
        (dir.join("focused_L_0006.fits"), true),
        (dir.join("trailed_Ha_0001_001.fits"), false),
        (dir.join("trailed_SII_0001_001.fits"), false),
        (dir.join("trailed_OIII_0001.fits"), false),
    ];
    if let Some(full) = rig_data() {
        frames.extend([
            (full.join("good/Unknown_L_2026-09-15_0005.fits"), true),
            (full.join("good/Unknown_L_2026-09-15_0006.fits"), true),
            (full.join("solve/solve-verify.fits"), true),
            (full.join("reject/NGC7380_Ha_0001_001.fits"), false),
            (full.join("reject/NGC7380_SII_0001_001.fits"), false),
            (full.join("reject/NGC7380_OIII_0001.fits"), false),
        ]);
    }
    for (path, in_focus) in frames {
        let metrics = metrics(&path).await;
        let grade = grade_frame(&shipped, &metrics, None);
        assert_eq!(
            grade.is_pass(),
            in_focus,
            "{}: eccentricity {:?} against the shipped limit {} -> {grade:?}",
            path.display(),
            metrics.eccentricity,
            skotiq_sequencer::quality::DEFAULT_ECCENTRICITY_THRESHOLD
        );
    }
}

#[tokio::test]
async fn the_full_frames_of_the_night_grade_as_they_should() {
    let Some(dir) = rig_data() else {
        eprintln!("SKIPPED: ~/.cache/sk-rig-data/2026-09-14 is not on this machine");
        return;
    };
    for file in [
        "good/Unknown_L_2026-09-15_0005.fits",
        "good/Unknown_L_2026-09-15_0006.fits",
        "solve/solve-verify.fits",
    ] {
        let (metrics, grade) = graded(&dir.join(file)).await;
        assert_eq!(grade, FrameGrade::Pass, "{file}: {metrics:?}");
    }
    for file in [
        "reject/NGC7380_Ha_0001_001.fits",
        "reject/NGC7380_SII_0001_001.fits",
        "reject/NGC7380_OIII_0001.fits",
        // Taken landing from above at 6620: optically ~105 steps out.
        "good/Unknown_L_2026-09-14_0003.fits",
        "good/Unknown_L_2026-09-15_0004.fits",
    ] {
        let (metrics, grade) = graded(&dir.join(file)).await;
        assert!(grade.is_reject(), "{file}: {metrics:?}");
    }
}

/// The owner's subs of 2026-10-21 and 2026-01-02, when the dust-study corpus
/// is on this machine (`SKOTIQ_DUST_DATA`, else `~/.cache/ns-dust/data/laptop`).
fn dust_data() -> Option<PathBuf> {
    let root = std::env::var_os("SKOTIQ_DUST_DATA")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME").map(|h| Path::new(&h).join(".cache/ns-dust/data/laptop"))
        })?;
    root.is_dir().then_some(root)
}

/// What a profile left at the app's defaults grades with: the absolute HFR,
/// HFR baseline, eccentricity and star-count floor the settings ship, with
/// the star-count drop the floor arms.
fn shipped_check() -> ImageQualityCheck {
    ImageQualityCheck {
        hfr_threshold: Some(3.5),
        hfr_baseline_percent: Some(50.0),
        eccentricity_threshold: Some(skotiq_sequencer::quality::DEFAULT_ECCENTRICITY_THRESHOLD),
        star_count_min: Some(10),
        star_count_drop_percent: Some(skotiq_sequencer::quality::DEFAULT_STAR_COUNT_DROP_PERCENT),
        max_consecutive_rejects: 3,
    }
}

/// Grades frames in capture order the way `run_exposure_loop` does: the HFR
/// and star-count baselines per filter (the run's HFR baseline until a filter
/// has one), fed only by accepted frames.
struct Run {
    hfr_baseline: Option<f64>,
    hfr_samples: Vec<f64>,
    star_baselines: std::collections::HashMap<String, skotiq_sequencer::quality::FilterBaseline>,
}

impl Run {
    fn new() -> Self {
        Self {
            hfr_baseline: None,
            hfr_samples: Vec::new(),
            star_baselines: std::collections::HashMap::new(),
        }
    }

    async fn grade(&mut self, path: &Path, filter: &str) -> (FrameMetrics, FrameGrade) {
        let metrics = metrics(path).await;
        let baseline = self.star_baselines.entry(filter.to_string()).or_default();
        let grade = skotiq_sequencer::quality::grade_frame_with_baselines(
            &shipped_check(),
            &metrics,
            baseline.hfr().or(self.hfr_baseline),
            baseline.star_count_at(None),
        );
        if grade.is_pass() {
            skotiq_sequencer::quality::update_hfr_baseline(
                &mut self.hfr_baseline,
                &mut self.hfr_samples,
                metrics.hfr,
            );
            baseline.record(metrics.star_count, metrics.hfr, None);
        }
        println!("{}: {metrics:?} -> {grade:?}", path.display());
        (metrics, grade)
    }
}

/// The NGC 891 run of 2026-10-21 (L 90 s, RGB 120 s, interleaved one frame
/// per filter): the first six rounds of subs pass, and the three trailed subs
/// that ended the night are rejected, on eccentricity and on star count.
#[tokio::test]
async fn the_ngc891_run_keeps_its_subs_and_rejects_its_trailed_frames() {
    let Some(root) = dust_data() else {
        eprintln!("SKIPPED: the dust-study corpus is not on this machine");
        return;
    };
    let dir = root.join("NGC7380");
    let mut run = Run::new();
    for round in 1..=6 {
        for filter in ["L", "R", "G", "B"] {
            let (metrics, grade) = run
                .grade(
                    &dir.join(format!("NGC0891_{filter}_0001_{round:03}.fits")),
                    filter,
                )
                .await;
            assert!(
                grade.is_pass(),
                "{filter} {round}: {metrics:?} -> {grade:?}"
            );
        }
    }
    assert!(run
        .star_baselines
        .values()
        .all(|b| b.star_count_at(None).is_some()));
    for filter in ["R", "G", "B"] {
        let (metrics, grade) = run
            .grade(
                &dir.join(format!("Reject/NGC0891_{filter}_0001.fits")),
                filter,
            )
            .await;
        assert!(grade.is_reject(), "trailed {filter}: {metrics:?}");
        // Each would be rejected on its star count alone.
        let baseline = run.star_baselines[filter]
            .star_count_at(None)
            .expect("baseline");
        let count = f64::from(metrics.star_count.expect("counted"));
        assert!(
            count < 0.5 * baseline,
            "trailed {filter}: {count} stars against a baseline of {baseline}"
        );
    }
}

/// A night that clouded over (Caldwell 7, 2026-01-02, L 120 s): the frames
/// before the cloud pass, and the cloud frames are rejected, including one
/// that still shows 253 stars too saturated by the sky to measure.
#[tokio::test]
async fn a_night_that_clouds_over_rejects_the_cloud_frames() {
    let Some(root) = dust_data() else {
        eprintln!("SKIPPED: the dust-study corpus is not on this machine");
        return;
    };
    let dir = root.join("N.I.N.A/2026-01-02/LIGHT");
    let mut run = Run::new();
    for name in [
        "2026-01-02_19-44-37_L_-15.10_120.00s_0000",
        "2026-01-02_19-53-12_L_-14.80_120.00s_0001",
        "2026-01-02_20-01-42_L_-14.80_120.00s_0002",
        "2026-01-02_20-10-30_L_-15.00_120.00s_0003",
        "2026-01-02_20-19-03_L_-15.00_120.00s_0004",
    ] {
        let (metrics, grade) = run.grade(&dir.join(format!("{name}.fits")), "L").await;
        assert!(grade.is_pass(), "{name}: {metrics:?} -> {grade:?}");
    }
    for name in [
        "2026-01-03_00-39-56_L_-15.00_120.00s_0034",
        "2026-01-03_01-05-18_L_-15.00_120.00s_0036",
        "2026-01-03_01-14-25_L_-15.00_120.00s_0037",
    ] {
        let (metrics, grade) = run.grade(&dir.join(format!("{name}.fits")), "L").await;
        assert!(grade.is_reject(), "{name}: {metrics:?}");
    }
}
