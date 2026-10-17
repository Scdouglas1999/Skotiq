//! DepthLock API: goal CRUD, reference inspection, selection geometry, and
//! evidence replay, for local and headless clients alike.
//!
//! Every mutation carries the caller's expected revision and is refused when
//! the goal has moved on, so two clients editing the same goal cannot
//! silently overwrite each other. Analysis never runs on the caller's
//! thread: ingestion and replay go through the service's bounded queue.

use crate::depthlock_service::engine::{state_label, DepthLockService, IngestOutcome};
use crate::depthlock_service::store::{GoalDefinition, GoalRecord};
use crate::error::SkotiqError;
use skotiq_imaging::depthlock::input::{
    AcquisitionSettings, CompatibilityPolicy, ReferenceGeometry,
};
use skotiq_imaging::depthlock::{MeasurementSpec, SkyRectangle, ESTIMATOR_VERSION};
use skotiq_imaging::{read_fits, PixelType};
use serde::{Deserialize, Serialize};
use std::path::Path;
use std::sync::Arc;

fn service() -> Result<&'static Arc<DepthLockService>, SkotiqError> {
    crate::depthlock_service::service().ok_or_else(|| {
        SkotiqError::OperationFailed(
            "DepthLock storage is not initialized; settings storage must be initialized first"
                .to_string(),
        )
    })
}

fn failed(e: String) -> SkotiqError {
    SkotiqError::OperationFailed(e)
}

/// A tangent-plane rectangle on the sky. Center in ICRS degrees, sides in
/// arcseconds, rotation in degrees (position angle of the rectangle's
/// height axis, east of north).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiSkyRectangle {
    pub ra_deg: f64,
    pub dec_deg: f64,
    pub width_arcsec: f64,
    pub height_arcsec: f64,
    pub rotation_deg: f64,
}

/// The fixed measurement definition of a goal revision. `scale_arcsec` is
/// the aperture side; `threshold` the required lower-quartile depth score
/// (dimensionless, 3–100); `min_coverage` the fraction of apertures that must
/// be measurable (0.9–1.0); the systematic floor is the documented
/// calibration error in ADU that is never averaged down.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthMeasurement {
    pub region: ApiSkyRectangle,
    pub background: ApiSkyRectangle,
    pub scale_arcsec: f64,
    pub threshold: f64,
    pub min_coverage: f64,
    pub systematic_floor_adu: f64,
    pub systematic_floor_source: String,
}

/// A reference frame's frozen TAN geometry (FITS 1-based CRPIX, CD in
/// degrees per pixel).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiReferenceGeometry {
    pub width: u32,
    pub height: u32,
    pub crval1: f64,
    pub crval2: f64,
    pub crpix1: f64,
    pub crpix2: f64,
    pub cd1_1: f64,
    pub cd1_2: f64,
    pub cd2_1: f64,
    pub cd2_2: f64,
}

/// The acquisition every contributing light must match.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiAcquisitionSettings {
    pub instrument: String,
    pub filter: String,
    pub exposure_secs: f64,
    pub gain: Option<i32>,
    pub offset: Option<i32>,
    pub bin_x: i32,
    pub bin_y: i32,
    pub ccd_temp_c: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthGoalDefinition {
    pub label: String,
    pub project_id: String,
    pub target_id: String,
    pub profile_id: String,
    pub filter_name: String,
    /// 0-based filter wheel slot when known.
    pub filter_index: Option<i32>,
    pub reference_path: String,
    pub reference: ApiReferenceGeometry,
    pub acquisition: ApiAcquisitionSettings,
    /// Accepted `CCD-TEMP` difference in °C when both sides carry it.
    pub temperature_tolerance_c: f64,
    pub dark_path: String,
    pub flat_path: String,
    pub measurement: ApiDepthMeasurement,
    pub enabled: bool,
    pub automatic_completion: bool,
}

/// One committed evaluation. `state` is one of `insufficientEvidence`,
/// `collecting`, `confirmationPending`, `achieved`, `unreliable`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthReport {
    pub state: String,
    pub score: Option<f64>,
    pub conservative_score: Option<f64>,
    pub uncertainty_adu: Option<f64>,
    pub coverage: f64,
    pub evidence_frames: u32,
    pub confirmation_frames: u32,
    pub reason: String,
    pub forecast: Option<ApiDepthForecast>,
}

/// What the goal is expected to cost, projected from the noise model (see
/// `depthlock::DepthForecast`). Frames, not hours: the host knows the
/// exposure length.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthForecast {
    pub frames_to_threshold: u32,
    pub frames_to_confirm: u32,
    pub reachable: bool,
    pub ceiling_score: f64,
    pub per_frame_noise_adu: f64,
    pub recent_frame_noise_adu: f64,
    pub best_frame_noise_adu: f64,
}

/// One point of a goal's score history or projection.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthCurvePoint {
    pub frames: u32,
    pub score: f64,
    pub conservative_score: f64,
    pub projected: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthGoal {
    pub id: String,
    pub revision: u64,
    pub definition: ApiDepthGoalDefinition,
    /// When this revision was selected (Unix ms); only later exposures count.
    pub selected_at_ms: i64,
    pub evidence_frames: u32,
    pub evidence_revision: u64,
    /// True when `report` was computed over exactly the current evidence.
    pub analysis_current: bool,
    pub report: Option<ApiDepthReport>,
    /// Exposures frozen in a provisional candidate awaiting confirmation.
    pub candidate_frames: u32,
    pub last_issue: Option<String>,
    pub archived_revisions: u32,
    /// The estimator version this goal's measurement is defined against.
    pub estimator_version: u32,
}

/// What a candidate reference file offers. Geometry and acquisition are
/// reported separately with their own refusal reasons so the UI can say
/// exactly what is missing.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthReferenceInfo {
    pub width: u32,
    pub height: u32,
    pub pixel_type: String,
    pub monochrome: bool,
    pub geometry: Option<ApiReferenceGeometry>,
    pub geometry_issue: Option<String>,
    pub pixel_scale_arcsec: Option<f64>,
    pub acquisition: Option<ApiAcquisitionSettings>,
    pub acquisition_issue: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthLockStatus {
    pub available: bool,
    pub goals: u32,
    pub queue_capacity: u32,
    pub queued: u64,
    pub processed: u64,
    pub dropped: u64,
    pub evidence_added: u64,
    pub evidence_rejected: u64,
    pub last_frame_ms: u64,
    pub max_frame_ms: u64,
}

/// `outcome` is one of `added`, `duplicate`, `alreadyAchieved`,
/// `preSelection`, `rejected`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthIngestOutcome {
    pub outcome: String,
    pub state: Option<String>,
    pub reason: Option<String>,
}

// Conversions

impl From<&SkyRectangle> for ApiSkyRectangle {
    fn from(r: &SkyRectangle) -> Self {
        Self {
            ra_deg: r.ra_deg,
            dec_deg: r.dec_deg,
            width_arcsec: r.width_arcsec,
            height_arcsec: r.height_arcsec,
            rotation_deg: r.rotation_deg,
        }
    }
}

impl From<&ApiSkyRectangle> for SkyRectangle {
    fn from(r: &ApiSkyRectangle) -> Self {
        Self {
            ra_deg: r.ra_deg,
            dec_deg: r.dec_deg,
            width_arcsec: r.width_arcsec,
            height_arcsec: r.height_arcsec,
            rotation_deg: r.rotation_deg,
        }
    }
}

impl From<&ReferenceGeometry> for ApiReferenceGeometry {
    fn from(g: &ReferenceGeometry) -> Self {
        Self {
            width: g.width,
            height: g.height,
            crval1: g.crval1,
            crval2: g.crval2,
            crpix1: g.crpix1,
            crpix2: g.crpix2,
            cd1_1: g.cd1_1,
            cd1_2: g.cd1_2,
            cd2_1: g.cd2_1,
            cd2_2: g.cd2_2,
        }
    }
}

impl From<&ApiReferenceGeometry> for ReferenceGeometry {
    fn from(g: &ApiReferenceGeometry) -> Self {
        Self {
            width: g.width,
            height: g.height,
            crval1: g.crval1,
            crval2: g.crval2,
            crpix1: g.crpix1,
            crpix2: g.crpix2,
            cd1_1: g.cd1_1,
            cd1_2: g.cd1_2,
            cd2_1: g.cd2_1,
            cd2_2: g.cd2_2,
        }
    }
}

impl From<&AcquisitionSettings> for ApiAcquisitionSettings {
    fn from(a: &AcquisitionSettings) -> Self {
        Self {
            instrument: a.instrument.clone(),
            filter: a.filter.clone(),
            exposure_secs: a.exposure_secs,
            gain: a.gain,
            offset: a.offset,
            bin_x: a.bin_x,
            bin_y: a.bin_y,
            ccd_temp_c: a.ccd_temp_c,
        }
    }
}

impl From<&ApiAcquisitionSettings> for AcquisitionSettings {
    fn from(a: &ApiAcquisitionSettings) -> Self {
        Self {
            instrument: a.instrument.clone(),
            filter: a.filter.clone(),
            exposure_secs: a.exposure_secs,
            gain: a.gain,
            offset: a.offset,
            bin_x: a.bin_x,
            bin_y: a.bin_y,
            ccd_temp_c: a.ccd_temp_c,
        }
    }
}

impl From<&GoalDefinition> for ApiDepthGoalDefinition {
    fn from(d: &GoalDefinition) -> Self {
        Self {
            label: d.label.clone(),
            project_id: d.project_id.clone(),
            target_id: d.target_id.clone(),
            profile_id: d.profile_id.clone(),
            filter_name: d.filter_name.clone(),
            filter_index: d.filter_index,
            reference_path: d.reference_path.clone(),
            reference: (&d.reference).into(),
            acquisition: (&d.acquisition).into(),
            temperature_tolerance_c: d.compatibility.temperature_tolerance_c,
            dark_path: d.dark_path.clone(),
            flat_path: d.flat_path.clone(),
            measurement: ApiDepthMeasurement {
                region: (&d.measurement.region).into(),
                background: (&d.measurement.background).into(),
                scale_arcsec: d.measurement.scale_arcsec,
                threshold: d.measurement.threshold,
                min_coverage: d.measurement.min_coverage,
                systematic_floor_adu: d.measurement.systematic_floor_adu,
                systematic_floor_source: d.measurement.systematic_floor_source.clone(),
            },
            enabled: d.enabled,
            automatic_completion: d.automatic_completion,
        }
    }
}

impl From<&ApiDepthGoalDefinition> for GoalDefinition {
    fn from(d: &ApiDepthGoalDefinition) -> Self {
        Self {
            label: d.label.clone(),
            project_id: d.project_id.clone(),
            target_id: d.target_id.clone(),
            profile_id: d.profile_id.clone(),
            filter_name: d.filter_name.clone(),
            filter_index: d.filter_index,
            reference_path: d.reference_path.clone(),
            reference: (&d.reference).into(),
            acquisition: (&d.acquisition).into(),
            compatibility: CompatibilityPolicy {
                temperature_tolerance_c: d.temperature_tolerance_c,
            },
            dark_path: d.dark_path.clone(),
            flat_path: d.flat_path.clone(),
            measurement: MeasurementSpec {
                version: ESTIMATOR_VERSION,
                region: (&d.measurement.region).into(),
                background: (&d.measurement.background).into(),
                scale_arcsec: d.measurement.scale_arcsec,
                threshold: d.measurement.threshold,
                min_coverage: d.measurement.min_coverage,
                systematic_floor_adu: d.measurement.systematic_floor_adu,
                systematic_floor_source: d.measurement.systematic_floor_source.clone(),
            },
            enabled: d.enabled,
            automatic_completion: d.automatic_completion,
        }
    }
}

impl From<&GoalRecord> for ApiDepthGoal {
    fn from(r: &GoalRecord) -> Self {
        Self {
            id: r.id.clone(),
            revision: r.revision,
            definition: (&r.definition).into(),
            selected_at_ms: r.selected_at_ms,
            evidence_frames: r.evidence.len() as u32,
            evidence_revision: r.evidence_revision,
            // A goal with no evidence has nothing pending; only a goal whose
            // newest frame has not been evaluated yet is "not current".
            analysis_current: r.evidence.is_empty()
                || r.analyzed_evidence_revision == Some(r.evidence_revision),
            report: r.report.as_ref().map(|report| ApiDepthReport {
                state: state_label(&report.state).to_string(),
                score: report.score,
                conservative_score: report.conservative_score,
                uncertainty_adu: report.uncertainty_adu,
                coverage: report.coverage,
                evidence_frames: report.evidence_frames as u32,
                confirmation_frames: report.confirmation_frames as u32,
                reason: report.reason.clone(),
                forecast: report.forecast.as_ref().map(|f| ApiDepthForecast {
                    frames_to_threshold: f.frames_to_threshold as u32,
                    frames_to_confirm: f.frames_to_confirm as u32,
                    reachable: f.reachable,
                    ceiling_score: f.ceiling_score,
                    per_frame_noise_adu: f.per_frame_noise_adu,
                    recent_frame_noise_adu: f.recent_frame_noise_adu,
                    best_frame_noise_adu: f.best_frame_noise_adu,
                }),
            }),
            candidate_frames: r.candidate.as_ref().map_or(0, |c| c.frame_ids.len() as u32),
            last_issue: r.last_issue.clone(),
            archived_revisions: r.history.len() as u32,
            estimator_version: r.definition.measurement.version,
        }
    }
}

// API

#[flutter_rust_bridge::frb(sync)]
pub fn api_depthlock_status() -> ApiDepthLockStatus {
    match crate::depthlock_service::service() {
        None => ApiDepthLockStatus {
            available: false,
            goals: 0,
            queue_capacity: crate::depthlock_service::engine::QUEUE_CAPACITY as u32,
            queued: 0,
            processed: 0,
            dropped: 0,
            evidence_added: 0,
            evidence_rejected: 0,
            last_frame_ms: 0,
            max_frame_ms: 0,
        },
        Some(service) => {
            let stats = service.stats();
            ApiDepthLockStatus {
                available: true,
                goals: service.store().list().map_or(0, |g| g.len() as u32),
                queue_capacity: crate::depthlock_service::engine::QUEUE_CAPACITY as u32,
                queued: stats.queued,
                processed: stats.processed,
                dropped: stats.dropped,
                evidence_added: stats.evidence_added,
                evidence_rejected: stats.evidence_rejected,
                last_frame_ms: stats.last_frame_ms,
                max_frame_ms: stats.max_frame_ms,
            }
        }
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn api_depthlock_list_goals() -> Result<Vec<ApiDepthGoal>, SkotiqError> {
    let goals = service()?.store().list().map_err(failed)?;
    Ok(goals.iter().map(ApiDepthGoal::from).collect())
}

#[flutter_rust_bridge::frb(sync)]
pub fn api_depthlock_get_goal(goal_id: String) -> Result<ApiDepthGoal, SkotiqError> {
    let record = service()?.store().get(&goal_id).map_err(failed)?;
    Ok((&record).into())
}

/// Create a goal. `goal_id` may be empty to have one generated. The
/// selection timestamp is now: only exposures started after this call are
/// evidence, so the image the region was drawn on stays discovery data.
#[flutter_rust_bridge::frb(sync)]
pub fn api_depthlock_create_goal(
    goal_id: String,
    definition: ApiDepthGoalDefinition,
) -> Result<ApiDepthGoal, SkotiqError> {
    let service = service()?;
    let id = if goal_id.trim().is_empty() {
        new_goal_id()
    } else {
        goal_id
    };
    let record = service
        .store()
        .create(&id, (&definition).into(), now_ms())
        .map_err(failed)?;
    service.publish_change(&record.id, record.revision, "created");
    Ok((&record).into())
}

/// Replace a goal's definition. This is a new revision: the earlier one is
/// archived with references to its evidence, and evidence starts over.
#[flutter_rust_bridge::frb(sync)]
pub fn api_depthlock_revise_goal(
    goal_id: String,
    expected_revision: u64,
    definition: ApiDepthGoalDefinition,
) -> Result<ApiDepthGoal, SkotiqError> {
    let service = service()?;
    let record = service
        .store()
        .revise(&goal_id, expected_revision, (&definition).into(), now_ms())
        .map_err(failed)?;
    service.publish_change(&record.id, record.revision, "revised");
    Ok((&record).into())
}

/// Turn ingestion and automatic completion on or off without disturbing the
/// revision or its evidence.
#[flutter_rust_bridge::frb(sync)]
pub fn api_depthlock_set_goal_preferences(
    goal_id: String,
    expected_revision: u64,
    enabled: bool,
    automatic_completion: bool,
) -> Result<ApiDepthGoal, SkotiqError> {
    let service = service()?;
    let record = service
        .store()
        .set_preferences(&goal_id, expected_revision, enabled, automatic_completion)
        .map_err(failed)?;
    service.publish_change(&record.id, record.revision, "preferences");
    Ok((&record).into())
}

#[flutter_rust_bridge::frb(sync)]
pub fn api_depthlock_remove_goal(
    goal_id: String,
    expected_revision: u64,
) -> Result<(), SkotiqError> {
    let service = service()?;
    service
        .store()
        .remove(&goal_id, expected_revision)
        .map_err(failed)?;
    service.publish_change(&goal_id, expected_revision + 1, "removed");
    Ok(())
}

/// Describe a candidate reference frame: its geometry from the header (when
/// it carries an undistorted TAN solution) and its acquisition settings.
pub async fn api_depthlock_inspect_reference(
    path: String,
) -> Result<ApiDepthReferenceInfo, SkotiqError> {
    tokio::task::spawn_blocking(move || inspect_reference(&path))
        .await
        .map_err(|e| failed(format!("inspect_reference join error: {e}")))?
        .map_err(failed)
}

fn inspect_reference(path: &str) -> Result<ApiDepthReferenceInfo, String> {
    let (image, header) =
        read_fits(Path::new(path)).map_err(|e| format!("Cannot read {path}: {e}"))?;
    let geometry = ReferenceGeometry::from_header(&header, image.width, image.height);
    let acquisition = skotiq_imaging::depthlock::input::light_settings(&header);
    Ok(ApiDepthReferenceInfo {
        width: image.width,
        height: image.height,
        pixel_type: format!("{:?}", image.pixel_type),
        monochrome: image.channels == 1 && image.pixel_type == PixelType::U16,
        pixel_scale_arcsec: geometry.as_ref().ok().map(|g| g.pixel_scale_arcsec()),
        geometry: geometry.as_ref().ok().map(ApiReferenceGeometry::from),
        geometry_issue: geometry.err(),
        acquisition: acquisition.as_ref().ok().map(ApiAcquisitionSettings::from),
        acquisition_issue: acquisition.err(),
    })
}

/// A calibration error floor derived from the goal's masters (see
/// `depthlock::input::suggest_floor`): the masters' own pixel noise,
/// averaged over the aperture. `source` is the derivation in words, ready
/// to be stored as the goal's `systematic_floor_source`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ApiDepthFloorSuggestion {
    pub floor_adu: f64,
    pub dark_noise_adu: f64,
    pub flat_relative_noise: f64,
    pub sky_adu: f64,
    pub aperture_pixels: f64,
    pub source: String,
}

/// Suggest the systematic error floor for a goal from its reference light
/// and master frames at the given aperture scale. `pixel_scale_arcsec` is
/// the reference's native scale when the caller resolved the geometry from
/// its own records; omitted, it is read from the file's TAN header.
pub async fn api_depthlock_suggest_floor(
    reference_path: String,
    dark_path: String,
    flat_path: String,
    scale_arcsec: f64,
    pixel_scale_arcsec: Option<f64>,
) -> Result<ApiDepthFloorSuggestion, SkotiqError> {
    tokio::task::spawn_blocking(move || {
        let (light, header) = read_fits(Path::new(&reference_path))
            .map_err(|e| format!("Cannot read {reference_path}: {e}"))?;
        let pixel_scale = match pixel_scale_arcsec {
            Some(scale) => scale,
            None => ReferenceGeometry::from_header(&header, light.width, light.height)?
                .pixel_scale_arcsec(),
        };
        if !(scale_arcsec.is_finite()
            && scale_arcsec > 0.0
            && pixel_scale.is_finite()
            && pixel_scale > 0.0)
        {
            return Err("Aperture scale and reference pixel scale must be positive".to_string());
        }
        let (dark, _) = read_fits(Path::new(&dark_path))
            .map_err(|e| format!("Cannot read master dark {dark_path}: {e}"))?;
        let (flat, _) = read_fits(Path::new(&flat_path))
            .map_err(|e| format!("Cannot read master flat {flat_path}: {e}"))?;
        let suggestion = skotiq_imaging::depthlock::input::suggest_floor(
            &dark,
            &flat,
            &light,
            scale_arcsec / pixel_scale,
        )?;
        Ok(ApiDepthFloorSuggestion {
            floor_adu: suggestion.floor_adu,
            dark_noise_adu: suggestion.dark_noise_adu,
            flat_relative_noise: suggestion.flat_relative_noise,
            sky_adu: suggestion.sky_adu,
            aperture_pixels: suggestion.aperture_pixels,
            source: suggestion.source,
        })
    })
    .await
    .map_err(|e| failed(format!("suggest_floor join error: {e}")))?
    .map_err(failed)
}

/// Convert a rectangle drawn on the reference image (0-based pixel corners,
/// any order) into the sky rectangle the goal stores. The rectangle keeps
/// the image's pixel axes: width along image x, height along image y,
/// rotation is the position angle of image +y.
#[flutter_rust_bridge::frb(sync)]
pub fn api_depthlock_sky_rectangle(
    reference: ApiReferenceGeometry,
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
) -> Result<ApiSkyRectangle, SkotiqError> {
    let geometry: ReferenceGeometry = (&reference).into();
    geometry.validate().map_err(failed)?;
    if ![x0, y0, x1, y1].iter().all(|v| v.is_finite()) {
        return Err(failed("Rectangle corners must be finite".into()));
    }
    let wcs = geometry.wcs();
    let (ra, dec) = wcs.pixel_to_world((x0 + x1) / 2.0, (y0 + y1) / 2.0);
    let scale_x = geometry.cd1_1.hypot(geometry.cd2_1) * 3600.0;
    let scale_y = geometry.cd1_2.hypot(geometry.cd2_2) * 3600.0;
    Ok(ApiSkyRectangle {
        ra_deg: ra,
        dec_deg: dec,
        width_arcsec: (x1 - x0).abs() * scale_x,
        height_arcsec: (y1 - y0).abs() * scale_y,
        rotation_deg: geometry.cd1_2.atan2(geometry.cd2_2).to_degrees(),
    })
}

/// Validate a measurement definition without creating anything, so the
/// editor can explain a bad region, scale or background placement as the
/// user adjusts it.
#[flutter_rust_bridge::frb(sync)]
pub fn api_depthlock_check_measurement(
    measurement: ApiDepthMeasurement,
) -> Result<u32, SkotiqError> {
    let spec = MeasurementSpec {
        version: ESTIMATOR_VERSION,
        region: (&measurement.region).into(),
        background: (&measurement.background).into(),
        scale_arcsec: measurement.scale_arcsec,
        threshold: measurement.threshold,
        min_coverage: measurement.min_coverage,
        systematic_floor_adu: measurement.systematic_floor_adu,
        systematic_floor_source: measurement.systematic_floor_source.clone(),
    };
    spec.validate().map_err(failed)?;
    let cells = spec.region.grid(spec.scale_arcsec).map_err(failed)?.len();
    Ok(cells as u32)
}

/// Offer one saved light to one goal and wait for the outcome. Archival
/// frames acquired before the goal's selection are reported as
/// `preSelection`, never counted.
pub async fn api_depthlock_ingest_frame(
    goal_id: String,
    path: String,
) -> Result<ApiDepthIngestOutcome, SkotiqError> {
    let outcome = service()?
        .ingest_frame(&goal_id, &path)
        .await
        .map_err(failed)?;
    Ok(match outcome {
        IngestOutcome::Added { state } => ApiDepthIngestOutcome {
            outcome: "added".into(),
            state: Some(state_label(&state).to_string()),
            reason: None,
        },
        IngestOutcome::Duplicate => ApiDepthIngestOutcome {
            outcome: "duplicate".into(),
            state: None,
            reason: None,
        },
        IngestOutcome::AlreadyAchieved => ApiDepthIngestOutcome {
            outcome: "alreadyAchieved".into(),
            state: Some("achieved".into()),
            reason: Some(
                "This goal revision is already achieved; edit the goal to measure again".into(),
            ),
        },
        IngestOutcome::PreSelection => ApiDepthIngestOutcome {
            outcome: "preSelection".into(),
            state: None,
            reason: Some("Acquired before this goal revision was selected".into()),
        },
        IngestOutcome::Rejected(reason) => ApiDepthIngestOutcome {
            outcome: "rejected".into(),
            state: None,
            reason: Some(reason),
        },
    })
}

/// The goal's score after each prefix of its evidence (thinned to about
/// `max_points`), followed by the noise model's projection to the forecast
/// crossing. Display only; nothing here changes a verdict.
pub async fn api_depthlock_goal_curve(
    goal_id: String,
    max_points: u32,
) -> Result<Vec<ApiDepthCurvePoint>, SkotiqError> {
    let record = service()?.store().get(&goal_id).map_err(failed)?;
    let points = tokio::task::spawn_blocking(move || {
        let evidence: Vec<_> = record.evidence.values().cloned().collect();
        skotiq_imaging::depthlock::progress_curve(
            &record.definition.measurement,
            &evidence,
            record.selected_at_ms,
            max_points.clamp(4, 200) as usize,
        )
    })
    .await
    .map_err(|e| failed(format!("goal_curve join error: {e}")))?;
    Ok(points
        .into_iter()
        .map(|p| ApiDepthCurvePoint {
            frames: p.frames as u32,
            score: p.score,
            conservative_score: p.conservative_score,
            projected: p.projected,
        })
        .collect())
}

/// Re-evaluate a goal over the evidence it already holds.
pub async fn api_depthlock_replay_goal(goal_id: String) -> Result<ApiDepthGoal, SkotiqError> {
    let record = service()?.replay(&goal_id).await.map_err(failed)?;
    Ok((&record).into())
}

fn now_ms() -> i64 {
    chrono::Utc::now().timestamp_millis()
}

/// Time-ordered and process-unique without a uuid dependency: nanoseconds
/// since the epoch plus a per-process counter, hex. Goal ids only need to be
/// unique within one store.
fn new_goal_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!(
        "goal-{:x}-{:x}",
        nanos,
        COUNTER.fetch_add(1, Ordering::Relaxed)
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn reference(rotation_deg: f64, flipped: bool, scale_arcsec: f64) -> ApiReferenceGeometry {
        let s = scale_arcsec / 3600.0;
        let t = rotation_deg.to_radians();
        // An improper rotation (east left, the usual sky parity) or a
        // proper one (mirrored optics); both are orthogonal.
        let (cd1_1, cd1_2) = if flipped {
            (s * t.cos(), -s * t.sin())
        } else {
            (-s * t.cos(), s * t.sin())
        };
        ApiReferenceGeometry {
            width: 1024,
            height: 768,
            crval1: 83.8,
            crval2: -5.4,
            crpix1: 512.5,
            crpix2: 384.5,
            cd1_1,
            cd1_2,
            cd2_1: s * t.sin(),
            cd2_2: s * t.cos(),
        }
    }

    /// The sky rectangle built from a drawn pixel rectangle must tile, on
    /// the reference image, exactly the drawn pixels: every aperture centre
    /// lands inside the rectangle and the count is what the sides imply —
    /// whatever the image's rotation and parity.
    #[test]
    fn sky_rectangle_tiles_the_drawn_pixels_for_any_orientation() {
        for rotation in [0.0, 17.0, 90.0, 123.4, 180.0, 270.0, -45.0] {
            for flipped in [false, true] {
                let geometry = reference(rotation, flipped, 1.5);
                let (x0, y0, x1, y1) = (300.0, 200.0, 360.0, 260.0); // 60x60 px = 90"x90"
                let rect = api_depthlock_sky_rectangle(geometry.clone(), x1, y1, x0, y0)
                    .unwrap_or_else(|e| panic!("{rotation}/{flipped}: {e:?}"));
                assert!((rect.width_arcsec - 90.0).abs() < 1e-9);
                assert!((rect.height_arcsec - 90.0).abs() < 1e-9);
                let sky: SkyRectangle = (&rect).into();
                let scale = 10.0;
                let grid = sky.grid(scale).unwrap();
                assert_eq!(grid.len(), 81, "9x9 apertures of 10\" in 90\"");
                let wcs: ReferenceGeometry = (&geometry).into();
                let wcs = wcs.wcs();
                for (ra, dec) in grid {
                    let (x, y) = wcs.world_to_pixel(ra, dec).expect("on the tangent plane");
                    // Centres of 10" cells sit at least half a cell (3.33 px)
                    // inside the drawn edges.
                    assert!(
                        x > x0 + 3.0 && x < x1 - 3.0 && y > y0 + 3.0 && y < y1 - 3.0,
                        "rotation {rotation} flipped {flipped}: aperture centre ({x:.2},{y:.2}) outside {x0}..{x1} x {y0}..{y1}"
                    );
                }
            }
        }
    }

    #[test]
    fn sky_rectangle_refuses_bad_geometry_and_corners() {
        let mut singular = reference(0.0, false, 1.5);
        singular.cd1_1 = 0.0;
        singular.cd2_1 = 0.0;
        assert!(api_depthlock_sky_rectangle(singular, 0.0, 0.0, 10.0, 10.0).is_err());
        assert!(
            api_depthlock_sky_rectangle(reference(0.0, false, 1.5), f64::NAN, 0.0, 10.0, 10.0)
                .is_err()
        );
    }

    #[test]
    fn check_measurement_reports_the_aperture_count_or_the_reason() {
        let geometry = reference(0.0, false, 1.5);
        let region =
            api_depthlock_sky_rectangle(geometry.clone(), 300.0, 200.0, 360.0, 260.0).unwrap();
        let background = api_depthlock_sky_rectangle(geometry, 500.0, 200.0, 560.0, 260.0).unwrap();
        let measurement = ApiDepthMeasurement {
            region: region.clone(),
            background: background.clone(),
            scale_arcsec: 10.0,
            threshold: 5.0,
            min_coverage: 0.9,
            systematic_floor_adu: 0.5,
            systematic_floor_source: "test".into(),
        };
        assert_eq!(
            api_depthlock_check_measurement(measurement.clone()).unwrap(),
            81
        );

        let overlapping = ApiDepthMeasurement {
            background: region.clone(),
            ..measurement.clone()
        };
        let err = api_depthlock_check_measurement(overlapping).unwrap_err();
        assert!(format!("{err:?}").contains("disjoint"), "{err:?}");

        let too_fine = ApiDepthMeasurement {
            scale_arcsec: 3.0,
            ..measurement
        };
        let err = api_depthlock_check_measurement(too_fine).unwrap_err();
        assert!(format!("{err:?}").contains("16 and 256"), "{err:?}");
    }
}
