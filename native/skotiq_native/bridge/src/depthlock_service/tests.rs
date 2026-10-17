//! The DepthLock service against a synthetic night on disk.
//!
//! Frames are rendered as FITS files the way the sequencer would save them
//! (unprocessed U16 lights with the acquisition cards, dithered star field,
//! sensor-fixed vignetting) with Skotiq-format master frames beside
//! them, then pushed through the real ingestion pipeline: read, vet,
//! calibrate, mask, register, sample, store, evaluate, commit. The
//! assertions are the acceptance scenarios that need files rather than
//! aperture vectors: pooled evidence reaching an achieved verdict and
//! surviving a restart, a blank region never achieving, incompatible and
//! re-calibrated frames refused with reasons, duplicate events ignored,
//! the queue shedding under load, and the verdict source's policy.

use super::engine::{DepthLockService, EventSink, IngestOutcome, QUEUE_CAPACITY};
use super::store::{tests::spec, GoalDefinition, GoalStore};
use crate::event::{DepthLockEvent, EventPayload, SkotiqEvent};
use skotiq_imaging::depthlock::input::{
    AcquisitionSettings, CompatibilityPolicy, ReferenceGeometry,
};
use skotiq_imaging::depthlock::DepthState;
use skotiq_imaging::{write_fits, FitsHeader, ImageData};
use skotiq_sequencer::depth_goal::{DepthGoalBinding, DepthGoalOps, DepthGoalVerdict};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

/// Frame size for the scenario tests. Small enough to render a whole night
/// in seconds; the ignored benchmark below uses a full-size sensor.
const WIDTH: u32 = 512;
const HEIGHT: u32 = 384;

/// Sensor geometry a synthetic night is rendered at.
#[derive(Clone, Copy)]
struct Sensor {
    width: u32,
    height: u32,
}

impl Sensor {
    const SMALL: Sensor = Sensor {
        width: WIDTH,
        height: HEIGHT,
    };
}
const PIXEL_SCALE_ARCSEC: f64 = 2.0;
const SKY_ADU: f64 = 300.0;
const DARK_ADU: f64 = 500.0;
const NOISE_ADU: f64 = 20.0;
/// Exposure start of frame 0; frames are 130 s apart.
const T0_MS: i64 = 1_789_000_000_000;
const FRAME_SPACING_MS: i64 = 130_000;

/// Frame 0's exposure start. `SKOTIQ_SYNTHETIC_NIGHT_T0_MS` moves the
/// whole night in time so a kept fixture can post-date a goal created
/// through the live API (only exposures after a goal's selection count).
fn t0_ms() -> i64 {
    std::env::var("SKOTIQ_SYNTHETIC_NIGHT_T0_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(T0_MS)
}

/// Deterministic LCG so every run renders the same night.
struct Rng(u64);

impl Rng {
    fn next_f64(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6364136223846793005)
            .wrapping_add(1442695040888963407);
        ((self.0 >> 11) as f64) / ((1u64 << 53) as f64)
    }
    fn gaussian(&mut self) -> f64 {
        let u = self.next_f64().max(1e-12);
        let v = self.next_f64();
        (-2.0 * u.ln()).sqrt() * (2.0 * std::f64::consts::PI * v).cos()
    }
}

/// The star field, fixed on the sky: positions in reference-frame pixels.
fn star_field(sensor: Sensor) -> Vec<(f64, f64, f64)> {
    let mut rng = Rng(7);
    let mut stars = Vec::new();
    // Roughly constant star density whatever the sensor size.
    let wanted = 90 * (sensor.width * sensor.height) as usize / (WIDTH * HEIGHT) as usize;
    while stars.len() < wanted.max(90) {
        let x = 20.0 + rng.next_f64() * (sensor.width as f64 - 40.0);
        let y = 20.0 + rng.next_f64() * (sensor.height as f64 - 40.0);
        // Keep the measurement regions and their surroundings star-free.
        if (150.0..=250.0).contains(&x) && (100.0..=200.0).contains(&y) {
            continue;
        }
        if (250.0..=350.0).contains(&x) && (100.0..=200.0).contains(&y) {
            continue;
        }
        let peak = 3_000.0 + rng.next_f64() * 22_000.0;
        stars.push((x, y, peak));
    }
    stars
}

fn vignette(sensor: Sensor, x: usize, y: usize) -> f64 {
    let dx = x as f64 - sensor.width as f64 / 2.0;
    let dy = y as f64 - sensor.height as f64 / 2.0;
    1.0 - 0.03 * (dx * dx + dy * dy)
        / ((sensor.width * sensor.width + sensor.height * sensor.height) as f64 / 4.0)
}

struct Night {
    dir: PathBuf,
    frames: Vec<PathBuf>,
    reference: PathBuf,
    dark: PathBuf,
    flat: PathBuf,
    geometry: ReferenceGeometry,
}

fn geometry(sensor: Sensor) -> ReferenceGeometry {
    let s = PIXEL_SCALE_ARCSEC / 3600.0;
    ReferenceGeometry {
        width: sensor.width,
        height: sensor.height,
        crval1: 90.0,
        crval2: 30.0,
        crpix1: sensor.width as f64 / 2.0 + 0.5,
        crpix2: sensor.height as f64 / 2.0 + 0.5,
        cd1_1: -s,
        cd1_2: 0.0,
        cd2_1: 0.0,
        cd2_2: s,
    }
}

fn light_header(index: usize, filter: &str, exposure: f64) -> FitsHeader {
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", "Light");
    h.set_string("INSTRUME", "Synthetic Mono Camera");
    h.set_string("FILTER", filter);
    h.set_float("EXPTIME", exposure);
    h.set_int("GAIN", 100);
    h.set_int("OFFSET", 50);
    h.set_int("XBINNING", 1);
    h.set_int("YBINNING", 1);
    h.set_float("CCD-TEMP", -10.0);
    let when =
        chrono::DateTime::from_timestamp_millis(t0_ms() + index as i64 * FRAME_SPACING_MS).unwrap();
    h.set_string(
        "DATE-OBS",
        &when.format("%Y-%m-%dT%H:%M:%S%.3f").to_string(),
    );
    h.set_string("NS-SESID", "synthetic-night");
    h.set_int("NS-FIDX", index as i64 + 1);
    h
}

/// Render frame `index`: the sky (structure + stars) dithered by a
/// per-frame offset, vignetted on the sensor, plus dark pedestal and noise.
fn render_light(
    sensor: Sensor,
    index: usize,
    structure_adu: f64,
    stars: &[(f64, f64, f64)],
) -> ImageData {
    let mut rng = Rng(1_000 + index as u64);
    let (dx, dy) = if index == 0 {
        (0.0, 0.0)
    } else {
        (rng.next_f64() * 12.0 - 6.0, rng.next_f64() * 12.0 - 6.0)
    };
    let width = sensor.width as usize;
    let height = sensor.height as usize;
    let mut pixels = vec![0f64; width * height];
    // Sky: flat background plus a flat-topped patch around reference pixel
    // (200, 150) — the structure the user marked.
    for y in 0..height {
        for x in 0..width {
            let rx = x as f64 - dx;
            let ry = y as f64 - dy;
            let inside = (185.0..=215.0).contains(&rx) && (135.0..=165.0).contains(&ry);
            let sky = SKY_ADU + if inside { structure_adu } else { 0.0 };
            pixels[y * width + x] = sky;
        }
    }
    let sigma: f64 = 1.3;
    for &(sx, sy, peak) in stars {
        let cx = sx + dx;
        let cy = sy + dy;
        let x0 = (cx - 5.0).floor().max(0.0) as usize;
        let x1 = ((cx + 5.0).ceil() as usize).min(width - 1);
        let y0 = (cy - 5.0).floor().max(0.0) as usize;
        let y1 = ((cy + 5.0).ceil() as usize).min(height - 1);
        for y in y0..=y1 {
            for x in x0..=x1 {
                let r2 = (x as f64 - cx).powi(2) + (y as f64 - cy).powi(2);
                pixels[y * width + x] += peak * (-r2 / (2.0 * sigma * sigma)).exp();
            }
        }
    }
    let data: Vec<u16> = pixels
        .iter()
        .enumerate()
        .map(|(i, sky)| {
            let (x, y) = (i % width, i / width);
            let value = sky * vignette(sensor, x, y) + DARK_ADU + rng.gaussian() * NOISE_ADU;
            value.round().clamp(0.0, 65_535.0) as u16
        })
        .collect();
    ImageData::from_u16(sensor.width, sensor.height, 1, &data)
}

fn master_header(kind: &str) -> FitsHeader {
    let mut h = FitsHeader::new();
    h.set_string("IMAGETYP", kind);
    h.set_string("FRAMETYP", "MASTER");
    h.set_string("CALSTAT", &format!("Skotiq master {kind}"));
    h.set_int("NFRAMES", 20);
    h.set_string("COMBMETH", "SIGMA_CLIP");
    h.set_string("MASTRTYP", "F32");
    h
}

fn write(path: &Path, image: &ImageData, header: &FitsHeader) {
    write_fits(path, image, header).unwrap_or_else(|e| panic!("{}: {e:?}", path.display()));
}

/// Render and save `count` lights (frame 0 doubles as the reference) plus
/// the two masters.
fn synthetic_night(label: &str, count: usize, structure_adu: f64) -> Night {
    synthetic_night_on(Sensor::SMALL, label, count, structure_adu)
}

fn synthetic_night_on(sensor: Sensor, label: &str, count: usize, structure_adu: f64) -> Night {
    let dir = std::env::temp_dir().join(format!(
        "sk-depthlock-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let stars = star_field(sensor);
    let geometry = geometry(sensor);
    let mut frames = Vec::new();
    for index in 0..count {
        let path = dir.join(format!("light_{index:03}.fits"));
        let mut header = light_header(index, "L", 120.0);
        if index == 0 {
            header.set_string("CTYPE1", "RA---TAN");
            header.set_string("CTYPE2", "DEC--TAN");
            header.set_string("RADESYS", "ICRS");
            header.set_float("CRVAL1", geometry.crval1);
            header.set_float("CRVAL2", geometry.crval2);
            header.set_float("CRPIX1", geometry.crpix1);
            header.set_float("CRPIX2", geometry.crpix2);
            header.set_float("CD1_1", geometry.cd1_1);
            header.set_float("CD1_2", geometry.cd1_2);
            header.set_float("CD2_1", geometry.cd2_1);
            header.set_float("CD2_2", geometry.cd2_2);
        }
        write(
            &path,
            &render_light(sensor, index, structure_adu, &stars),
            &header,
        );
        frames.push(path);
    }
    let dark = dir.join("master_dark.fits");
    write(
        &dark,
        &ImageData::from_f32(
            sensor.width,
            sensor.height,
            1,
            &vec![DARK_ADU as f32; (sensor.width * sensor.height) as usize],
        ),
        &master_header("DARK"),
    );
    let flat = dir.join("master_flat.fits");
    let flat_pixels: Vec<f32> = (0..(sensor.width * sensor.height) as usize)
        .map(|i| vignette(sensor, i % sensor.width as usize, i / sensor.width as usize) as f32)
        .collect();
    let mean = flat_pixels.iter().map(|v| *v as f64).sum::<f64>() / flat_pixels.len() as f64;
    let flat_pixels: Vec<f32> = flat_pixels
        .iter()
        .map(|v| (*v as f64 / mean) as f32)
        .collect();
    write(
        &flat,
        &ImageData::from_f32(sensor.width, sensor.height, 1, &flat_pixels),
        &master_header("FLAT"),
    );
    Night {
        reference: frames[0].clone(),
        dir,
        frames,
        dark,
        flat,
        geometry,
    }
}

impl Drop for Night {
    fn drop(&mut self) {
        // `SKOTIQ_KEEP_TEST_FIXTURES=1` leaves the rendered night under
        // `TMPDIR` so it can be fed to a running app through the API — the
        // only synthetic FITS generator this repository has.
        if std::env::var_os("SKOTIQ_KEEP_TEST_FIXTURES").is_some() {
            eprintln!("keeping synthetic night at {}", self.dir.display());
            return;
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn definition(night: &Night) -> GoalDefinition {
    // The measurement grid from the store tests is 40"x40" at 10" cells
    // (16 apertures of 5x5 px) centred on RA 90 / Dec 30 = the reference
    // centre; here the structure sits at reference pixel (200, 150), so the
    // region is re-centred there and the background 100 px east.
    let wcs = night.geometry.wcs();
    let mut measurement = spec();
    let (ra, dec) = wcs.pixel_to_world(200.0, 150.0);
    measurement.region.ra_deg = ra;
    measurement.region.dec_deg = dec;
    let (ra, dec) = wcs.pixel_to_world(300.0, 150.0);
    measurement.background.ra_deg = ra;
    measurement.background.dec_deg = dec;
    GoalDefinition {
        label: "faint patch".into(),
        project_id: "project-1".into(),
        target_id: "target-1".into(),
        profile_id: "profile-1".into(),
        filter_name: "L".into(),
        filter_index: Some(0),
        reference_path: night.reference.to_string_lossy().into_owned(),
        reference: night.geometry.clone(),
        acquisition: AcquisitionSettings {
            instrument: "Synthetic Mono Camera".into(),
            filter: "L".into(),
            exposure_secs: 120.0,
            gain: Some(100),
            offset: Some(50),
            bin_x: 1,
            bin_y: 1,
            ccd_temp_c: Some(-10.0),
        },
        compatibility: CompatibilityPolicy::default(),
        dark_path: night.dark.to_string_lossy().into_owned(),
        flat_path: night.flat.to_string_lossy().into_owned(),
        measurement,
        enabled: true,
        automatic_completion: false,
    }
}

type Collected = Arc<Mutex<Vec<SkotiqEvent>>>;

fn collecting_sink() -> (EventSink, Collected) {
    let events: Collected = Arc::new(Mutex::new(Vec::new()));
    let sink_events = Arc::clone(&events);
    let sink: EventSink = Arc::new(move |event| sink_events.lock().unwrap().push(event));
    (sink, events)
}

fn open(root: &Path) -> (Arc<DepthLockService>, Collected) {
    let (sink, events) = collecting_sink();
    let service = DepthLockService::open(root, sink, &tokio::runtime::Handle::current()).unwrap();
    (service, events)
}

fn goal_updates(events: &Collected) -> Vec<(String, u32)> {
    events
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match &e.payload {
            EventPayload::DepthLock(DepthLockEvent::GoalUpdated {
                state,
                evidence_frames,
                ..
            }) => Some((state.clone(), *evidence_frames)),
            _ => None,
        })
        .collect()
}

fn rejections(events: &Collected) -> Vec<String> {
    events
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match &e.payload {
            EventPayload::DepthLock(DepthLockEvent::EvidenceRejected { reason, .. }) => {
                Some(reason.clone())
            }
            _ => None,
        })
        .collect()
}

fn path(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}

/// Selected one second after frame 0 started, so frame 0 is discovery data
/// and every later frame counts.
fn selected_at_ms() -> i64 {
    t0_ms() + 1_000
}

/// Scenarios 2, 3, 5 and 8 on files: a real faint structure reaches an
/// achieved verdict only after the confirmation window, the verdict source
/// stays advisory until automation is switched on, duplicates add nothing,
/// and everything survives a restart without re-reading a frame.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_synthetic_night_reaches_achieved_and_survives_restart() {
    let night = synthetic_night("achieve", 81, 12.0);
    let store_dir = night.dir.join("store");
    let (service, events) = open(&store_dir);
    let goal = service
        .store()
        .create("faint", definition(&night), selected_at_ms())
        .unwrap();
    let binding = DepthGoalBinding {
        goal_id: "faint".into(),
        revision: goal.revision,
    };

    assert_eq!(
        service
            .ingest_now("faint", &path(&night.frames[0]))
            .unwrap(),
        IngestOutcome::PreSelection,
        "the image the region was drawn on is not evidence"
    );

    let mut states = Vec::new();
    let mut closed_after_achieved = 0;
    for frame in &night.frames[1..] {
        let outcome = service.ingest_now("faint", &path(frame)).unwrap();
        if outcome == IngestOutcome::AlreadyAchieved {
            assert_eq!(states.last(), Some(&DepthState::Achieved));
            closed_after_achieved += 1;
            states.push(DepthState::Achieved);
            continue;
        }
        let IngestOutcome::Added { state } = outcome else {
            panic!("{}: {outcome:?}", frame.display());
        };
        if state == DepthState::Unreliable {
            let report = service.store().get("faint").unwrap().report.unwrap();
            panic!(
                "{}: unreliable: {} ({report:?})",
                frame.display(),
                report.reason
            );
        }
        states.push(state);
    }
    assert_eq!(states.len(), 80);
    assert!(
        states[..31]
            .iter()
            .all(|s| *s == DepthState::InsufficientEvidence),
        "no score before 32 exposures: {:?}",
        &states[..31]
    );
    assert!(
        !states.contains(&DepthState::Unreliable),
        "a clean synthetic night is never unreliable: {states:?}"
    );
    let provisional = states
        .iter()
        .position(|s| *s == DepthState::ConfirmationPending)
        .expect("a real 12 ADU patch crosses the threshold provisionally");
    let achieved = states
        .iter()
        .position(|s| *s == DepthState::Achieved)
        .expect("and is confirmed by later exposures");
    assert!(provisional >= 31, "{states:?}");
    assert!(
        achieved >= provisional + 16,
        "confirmation needs 16 later exposures: provisional at {provisional}, achieved at {achieved}"
    );
    assert!(
        states[achieved..]
            .iter()
            .all(|s| *s == DepthState::Achieved),
        "an achieved goal does not oscillate: {:?}",
        &states[achieved..]
    );
    eprintln!(
        "provisional after {} exposures, achieved after {}",
        provisional + 1,
        achieved + 1
    );

    let pooled = 80 - closed_after_achieved;
    assert_eq!(
        pooled,
        achieved + 1,
        "intake closes at the achieved verdict (closed {closed_after_achieved}, states {states:?})"
    );

    let record = service.store().get("faint").unwrap();
    assert_eq!(record.evidence.len(), pooled);
    let report = record.report.clone().unwrap();
    assert_eq!(report.state, DepthState::Achieved);
    // Every stored frame is either pooled or set aside; a dither can carry
    // a masked star wing into the background region, which costs that
    // frame and nothing else.
    assert_eq!(report.evidence_frames + report.excluded_frames, pooled);
    assert!(report.excluded_frames <= 2, "{report:?}");
    assert!(report.confirmation_frames >= 16);
    eprintln!(
        "pooled {} of {pooled} stored frames ({} set aside); score {:.2}, conservative {:.2}, uncertainty {:.3} ADU",
        report.evidence_frames,
        report.excluded_frames,
        report.score.unwrap(),
        report.conservative_score.unwrap(),
        report.uncertainty_adu.unwrap()
    );
    assert!(report.score.unwrap() > report.conservative_score.unwrap());
    assert!(report.conservative_score.unwrap() >= 5.0);
    assert!((report.coverage - 1.0).abs() < 1e-9);
    // The candidate froze the frames that were pooled when the threshold
    // was first crossed: everything stored up to then minus any set aside.
    let candidate_frames = record.candidate.as_ref().unwrap().frame_ids.len();
    assert!(
        candidate_frames <= provisional + 1 && candidate_frames + 2 > provisional + 1,
        "candidate {candidate_frames} vs provisional index {provisional}"
    );

    // Advisory by default: the executor is told to continue.
    assert!(matches!(
        service.verdict(&binding),
        DepthGoalVerdict::Continue { reason } if reason.contains("advisory")
    ));
    service
        .store()
        .set_preferences("faint", goal.revision, true, true)
        .unwrap();
    let DepthGoalVerdict::Achieved(completion) = service.verdict(&binding) else {
        panic!("automation on + achieved must authorize");
    };
    assert_eq!(completion.revision, goal.revision);
    assert_eq!(completion.evidence_frames, report.evidence_frames as u32);
    assert_eq!(completion.threshold, 5.0);
    assert!(matches!(
        service.verdict(&DepthGoalBinding {
            goal_id: "faint".into(),
            revision: goal.revision + 1
        }),
        DepthGoalVerdict::Unavailable { .. }
    ));

    // Reprocessing a frame is not new evidence.
    assert_eq!(
        service
            .ingest_now("faint", &path(&night.frames[10]))
            .unwrap(),
        IngestOutcome::Duplicate
    );
    assert_eq!(service.store().get("faint").unwrap().evidence.len(), pooled);

    let updates = goal_updates(&events);
    assert_eq!(
        updates.len(),
        pooled,
        "one committed analysis per admitted frame"
    );
    assert_eq!(
        updates.last().unwrap(),
        &("achieved".to_string(), report.evidence_frames as u32)
    );
    assert!(rejections(&events).is_empty());
    let stats = service.stats();
    assert_eq!(stats.evidence_added, pooled as u64);
    assert_eq!(stats.evidence_rejected, 0);
    assert!(stats.max_frame_ms > 0);
    eprintln!(
        "per-frame cost on {WIDTH}x{HEIGHT}: last {} ms, max {} ms",
        stats.last_frame_ms, stats.max_frame_ms
    );

    drop(service);
    let (reopened, _) = open(&store_dir);
    let record = reopened.store().get("faint").unwrap();
    assert_eq!(record.evidence.len(), pooled);
    assert_eq!(record.report.unwrap().state, DepthState::Achieved);
    assert!(record.definition.automatic_completion);
    assert!(matches!(
        reopened.verdict(&binding),
        DepthGoalVerdict::Achieved(_)
    ));
    let replayed = reopened.replay_now("faint").unwrap();
    assert_eq!(replayed.report.unwrap().state, DepthState::Achieved);
    assert_eq!(replayed.evidence.len(), pooled, "replay adds nothing");
}

/// Scenario 2 on files: a blank region with the same noise never achieves,
/// however long the night.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_blank_region_never_achieves() {
    let night = synthetic_night("blank", 65, 0.0);
    let (service, _) = open(&night.dir.join("store"));
    service
        .store()
        .create("blank", definition(&night), selected_at_ms())
        .unwrap();
    for frame in &night.frames[1..] {
        let outcome = service.ingest_now("blank", &path(frame)).unwrap();
        assert!(
            matches!(outcome, IngestOutcome::Added { ref state } if *state != DepthState::Achieved),
            "{}: {outcome:?}",
            frame.display()
        );
    }
    let record = service.store().get("blank").unwrap();
    let report = record.report.unwrap();
    assert_ne!(report.state, DepthState::Achieved);
    assert!(record.candidate.is_none());
    assert!(
        report.conservative_score.is_none_or(|s| s < 5.0),
        "{report:?}"
    );
}

/// Scenario 4/6 on files: frames from another filter, exposure or camera
/// are refused with the reason named; a frame that cannot be registered
/// contributes nothing; a rebuilt master refuses new frames but keeps the
/// evidence already pooled.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn incompatible_and_recalibrated_frames_are_refused_with_reasons() {
    let night = synthetic_night("refuse", 4, 12.0);
    let (service, events) = open(&night.dir.join("store"));
    let goal = service
        .store()
        .create("faint", definition(&night), selected_at_ms())
        .unwrap();
    assert!(matches!(
        service
            .ingest_now("faint", &path(&night.frames[1]))
            .unwrap(),
        IngestOutcome::Added { .. }
    ));

    let stars = star_field(Sensor::SMALL);
    let other_filter = night.dir.join("ha.fits");
    write(
        &other_filter,
        &render_light(Sensor::SMALL, 2, 12.0, &stars),
        &light_header(2, "Ha", 120.0),
    );
    let IngestOutcome::Rejected(reason) =
        service.ingest_now("faint", &path(&other_filter)).unwrap()
    else {
        panic!("Ha frame must be refused");
    };
    assert!(reason.contains("Filter differs"), "{reason}");

    let other_exposure = night.dir.join("short.fits");
    write(
        &other_exposure,
        &render_light(Sensor::SMALL, 3, 12.0, &stars),
        &light_header(3, "L", 60.0),
    );
    let IngestOutcome::Rejected(reason) =
        service.ingest_now("faint", &path(&other_exposure)).unwrap()
    else {
        panic!("60 s frame must be refused");
    };
    assert!(reason.contains("Exposure differs"), "{reason}");

    let starless = night.dir.join("starless.fits");
    write(
        &starless,
        &render_light(Sensor::SMALL, 2, 12.0, &[]),
        &light_header(4, "L", 120.0),
    );
    let IngestOutcome::Rejected(reason) = service.ingest_now("faint", &path(&starless)).unwrap()
    else {
        panic!("a frame with no stars cannot be registered");
    };
    assert!(reason.contains("register"), "{reason}");

    let calibrated = night.dir.join("calibrated.fits");
    let mut header = light_header(5, "L", 120.0);
    header.set_string("CALSTAT", "calibrated by Skotiq");
    write(
        &calibrated,
        &render_light(Sensor::SMALL, 2, 12.0, &stars),
        &header,
    );
    let IngestOutcome::Rejected(reason) = service.ingest_now("faint", &path(&calibrated)).unwrap()
    else {
        panic!("a calibrated frame must be refused");
    };
    assert!(reason.contains("unprocessed"), "{reason}");

    // A rebuilt master changes the calibration context.
    write(
        &night.dark,
        &ImageData::from_f32(WIDTH, HEIGHT, 1, &vec![510.0; (WIDTH * HEIGHT) as usize]),
        &master_header("DARK"),
    );
    let IngestOutcome::Rejected(reason) = service
        .ingest_now("faint", &path(&night.frames[2]))
        .unwrap()
    else {
        panic!("a rebuilt master must not pool with old evidence");
    };
    assert!(reason.contains("Calibration context changed"), "{reason}");

    let record = service.store().get("faint").unwrap();
    assert_eq!(record.evidence.len(), 1, "earlier evidence is kept");
    assert_eq!(record.revision, goal.revision);
    assert!(record
        .last_issue
        .unwrap()
        .contains("Calibration context changed"));
    assert_eq!(rejections(&events).len(), 5);
    assert_eq!(service.stats().evidence_rejected, 5);
}

/// Scenario 6: the queue is bounded and sheds with an explanation instead
/// of blocking the capture path; the worker itself is never starved by the
/// producer. A current-thread runtime never polls the worker until the
/// test yields, so the queue fills deterministically.
#[tokio::test(flavor = "current_thread")]
async fn a_full_queue_sheds_frames_with_an_event() {
    let night = synthetic_night("shed", 2, 0.0);
    let (service, events) = open(&night.dir.join("store"));
    service
        .store()
        .create("faint", definition(&night), selected_at_ms())
        .unwrap();
    for _ in 0..QUEUE_CAPACITY + 3 {
        service.notify_frame_saved(&path(&night.frames[1]));
    }
    let stats = service.stats();
    assert_eq!(stats.queued as usize, QUEUE_CAPACITY);
    assert_eq!(stats.dropped, 3);
    let dropped: Vec<String> = events
        .lock()
        .unwrap()
        .iter()
        .filter_map(|e| match &e.payload {
            EventPayload::DepthLock(DepthLockEvent::AnalysisDropped { reason, .. }) => {
                Some(reason.clone())
            }
            _ => None,
        })
        .collect();
    assert_eq!(dropped.len(), 3);
    assert!(dropped[0].contains("still saved"));
}

/// The capture-path hook offers a light only to goals for its filter and
/// camera, and ignores calibration frames outright.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn saved_frames_reach_only_the_goals_for_their_filter() {
    let night = synthetic_night("route", 2, 12.0);
    let (service, _) = open(&night.dir.join("store"));
    service
        .store()
        .create("lum", definition(&night), selected_at_ms())
        .unwrap();
    let mut ha = definition(&night);
    ha.filter_name = "Ha".into();
    ha.acquisition.filter = "Ha".into();
    service.store().create("ha", ha, selected_at_ms()).unwrap();
    let mut disabled = definition(&night);
    disabled.enabled = false;
    service
        .store()
        .create("off", disabled, selected_at_ms())
        .unwrap();

    service.notify_frame_saved(&path(&night.frames[1]));
    // A calibration frame saved by the sequencer never becomes a job.
    super::notify_frame_saved(&path(&night.dark), "Dark");
    for _ in 0..200 {
        if service.stats().processed >= 1 {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
    }
    assert_eq!(service.stats().processed, 1);
    assert_eq!(service.store().get("lum").unwrap().evidence.len(), 1);
    assert_eq!(service.store().get("ha").unwrap().evidence.len(), 0);
    assert_eq!(service.store().get("off").unwrap().evidence.len(), 0);
    assert_eq!(service.stats().evidence_rejected, 0);
}

/// Scenario 5: evidence committed without its analysis (a crash between the
/// two writes) is re-evaluated on the next open, so a restart neither loses
/// nor double-counts it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_interrupted_analysis_is_repaired_on_open() {
    let night = synthetic_night("repair", 3, 12.0);
    let store_dir = night.dir.join("store");
    let (service, _) = open(&store_dir);
    service
        .store()
        .create("faint", definition(&night), selected_at_ms())
        .unwrap();
    service
        .ingest_now("faint", &path(&night.frames[1]))
        .unwrap();
    let committed = service.store().get("faint").unwrap();
    assert!(committed.analyzed_evidence_revision == Some(committed.evidence_revision));
    drop(service);

    // Simulate the crash: evidence lands, the analysis never does.
    {
        let store = GoalStore::open(&store_dir).unwrap();
        let record = store.get("faint").unwrap();
        let mut orphan = record.evidence.values().next().unwrap().clone();
        orphan.frame_id = "ns:synthetic-night:99".into();
        orphan.acquired_at_ms += 1;
        assert_eq!(
            store
                .add_evidence("faint", record.revision, orphan)
                .unwrap(),
            super::store::Admission::Added
        );
        let record = store.get("faint").unwrap();
        assert!(record.report.is_none());
        assert_eq!(record.analyzed_evidence_revision, None);
    }

    let (reopened, events) = open(&store_dir);
    let record = reopened.store().get("faint").unwrap();
    assert_eq!(record.evidence.len(), 2);
    assert_eq!(
        record.analyzed_evidence_revision,
        Some(record.evidence_revision)
    );
    assert!(record.report.is_some());
    assert_eq!(goal_updates(&events).len(), 1);
}

/// Representative cost on a full-size mono sensor (IMX571-class, 4144x2822):
/// one goal, one frame, the whole pipeline. Ignored by default because the
/// render alone takes a while; run with
/// `cargo test --release -p skotiq_bridge --lib depthlock_service::tests::full_sensor_frame_cost -- --ignored --nocapture`.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
#[ignore = "benchmark; run explicitly"]
async fn full_sensor_frame_cost() {
    let sensor = Sensor {
        width: 4144,
        height: 2822,
    };
    let night = synthetic_night_on(sensor, "bench", 4, 12.0);
    let (service, _) = open(&night.dir.join("store"));
    let mut def = definition(&night);
    def.reference = night.geometry.clone();
    service
        .store()
        .create("bench", def, selected_at_ms())
        .unwrap();
    let mut timings = Vec::new();
    for frame in &night.frames[1..] {
        let started = std::time::Instant::now();
        let outcome = service.ingest_now("bench", &path(frame)).unwrap();
        timings.push(started.elapsed().as_millis());
        assert!(
            matches!(outcome, IngestOutcome::Added { .. }),
            "{outcome:?}"
        );
    }
    eprintln!(
        "full-sensor per-frame cost {}x{}: {:?} ms (read + vet + calibrate + mask + register + sample + store + evaluate)",
        sensor.width, sensor.height, timings
    );
}

/// The floor suggestion reads the same files a goal points at and explains
/// itself; with the header's own scale or a caller-supplied one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn suggest_floor_reads_the_goal_files() {
    let night = synthetic_night("floor", 1, 0.0);
    let suggestion = crate::api::api_depthlock_suggest_floor(
        path(&night.reference),
        path(&night.dark),
        path(&night.flat),
        10.0,
        None,
    )
    .await
    .unwrap();
    assert!((suggestion.aperture_pixels - 5.0).abs() < 1e-6);
    assert!(
        suggestion.floor_adu > 0.0 && suggestion.floor_adu < 1.0,
        "{suggestion:?}"
    );
    assert!(suggestion.source.contains("Derived from the masters"));
    let explicit = crate::api::api_depthlock_suggest_floor(
        path(&night.reference),
        path(&night.dark),
        path(&night.flat),
        10.0,
        Some(4.0),
    )
    .await
    .unwrap();
    assert_eq!(explicit.aperture_pixels, 2.5);
    assert!(crate::api::api_depthlock_suggest_floor(
        path(&night.reference),
        path(&night.dir.join("missing.fits")),
        path(&night.flat),
        10.0,
        None,
    )
    .await
    .is_err());
}

/// The synthetic night's forecast is coherent with what then happens: the
/// projection made at 32 exposures lands within a factor of two of the real
/// crossing, and the curve endpoint returns history then projection.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn forecast_agrees_with_the_night_it_predicted() {
    let night = synthetic_night("forecast", 61, 12.0);
    let (service, _) = open(&night.dir.join("store"));
    service
        .store()
        .create("faint", definition(&night), selected_at_ms())
        .unwrap();
    let mut predicted_at_32: Option<usize> = None;
    let mut crossed_at: Option<usize> = None;
    for (i, frame) in night.frames[1..].iter().enumerate() {
        let outcome = service.ingest_now("faint", &path(frame)).unwrap();
        let record = service.store().get("faint").unwrap();
        let report = record.report.clone().unwrap();
        if i + 1 == 32 {
            let forecast = report.forecast.clone().expect("measurable at 32");
            assert!(forecast.reachable, "{forecast:?}");
            predicted_at_32 = Some(32 + forecast.frames_to_threshold);
        }
        if crossed_at.is_none() && report.state == DepthState::ConfirmationPending {
            crossed_at = Some(i + 1);
        }
        if matches!(outcome, IngestOutcome::AlreadyAchieved) {
            break;
        }
    }
    let predicted = predicted_at_32.unwrap();
    let actual = crossed_at.expect("the night crosses the threshold");
    assert!(
        predicted >= actual / 2 && predicted <= actual * 2,
        "predicted crossing at {predicted}, actual {actual}"
    );

    // The curve over the stored evidence: history first, then projection.
    let record = service.store().get("faint").unwrap();
    let evidence: Vec<_> = record.evidence.values().cloned().collect();
    let curve = skotiq_imaging::depthlock::progress_curve(
        &record.definition.measurement,
        &evidence,
        record.selected_at_ms,
        12,
    );
    assert!(curve.iter().any(|p| !p.projected));
    assert!(curve.windows(2).all(|w| w[0].frames < w[1].frames));
}
