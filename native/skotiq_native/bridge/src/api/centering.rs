//! Centering on a target outside a run: the Center step itself (frames at
//! the camera's stated defaults, solves near the target, the guider stopped
//! for the move, sync and correction slews) run for the app's Center
//! buttons, so manual centering and the run's centering follow one rule.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};

use crate::error::SkotiqError;
use crate::frb_generated::StreamSink;
use crate::state::get_state;
use crate::unified_device_ops::create_unified_device_ops;
use skotiq_sequencer::instructions::{
    execute_center, CenterProgress, InstructionContext, RunShared,
};
use skotiq_sequencer::{CenterConfig, NodeStatus};

/// What to center on, and with which devices.
#[derive(Debug, Clone)]
pub struct ApiCenteringRequest {
    pub mount_id: String,
    pub camera_id: String,
    pub filter_wheel_id: Option<String>,
    /// J2000.
    pub ra_hours: f64,
    pub dec_degrees: f64,
    pub accuracy_arcsec: f64,
    pub max_attempts: u32,
    pub exposure_secs: f64,
    /// The filter the frames are taken through; `None` keeps the wheel where
    /// it is (except a dark slot).
    pub filter: Option<String>,
    /// Sync the mount to each solve; off, correct by offset slews.
    pub sync_mount: bool,
}

/// One step of a centering run, the last always [`Self::Finished`].
#[derive(Debug, Clone)]
pub enum ApiCenteringStep {
    Capturing {
        attempt: u32,
    },
    Solved {
        attempt: u32,
        ra_hours: f64,
        dec_degrees: f64,
        separation_arcsec: f64,
    },
    Correcting {
        attempt: u32,
    },
    Finished {
        centered: bool,
        cancelled: bool,
        /// What happened, in operator words.
        message: String,
    },
}

static CENTERING_CANCEL: OnceLock<Arc<AtomicBool>> = OnceLock::new();
static CENTERING_ACTIVE: AtomicBool = AtomicBool::new(false);

fn cancel_token() -> &'static Arc<AtomicBool> {
    CENTERING_CANCEL.get_or_init(|| Arc::new(AtomicBool::new(false)))
}

/// Admission of one centering run at a time; released on drop.
struct CenteringAdmission;

impl CenteringAdmission {
    fn try_admit() -> Option<Self> {
        CENTERING_ACTIVE
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_ok()
            .then_some(Self)
    }
}

impl Drop for CenteringAdmission {
    fn drop(&mut self) {
        CENTERING_ACTIVE.store(false, Ordering::Release);
    }
}

/// Center the mount on a target, reporting each step to `sink`.
pub async fn api_center_on_target(
    request: ApiCenteringRequest,
    sink: StreamSink<ApiCenteringStep>,
) -> Result<(), SkotiqError> {
    let config = validated_config(&request)?;
    let Some(_admission) = CenteringAdmission::try_admit() else {
        return Err(SkotiqError::DeviceBusy {
            device_id: request.mount_id,
            current_operation: "centering".to_string(),
        });
    };
    let cancel = cancel_token().clone();
    cancel.store(false, Ordering::Relaxed);

    let mut run = RunShared::new(create_unified_device_ops());
    run.rig.mount_id = Some(request.mount_id);
    run.rig.camera_id = Some(request.camera_id);
    run.rig.filterwheel_id = request.filter_wheel_id;
    run.event_tx = Some(
        crate::util::executor_event_bridge::spawn_executor_event_bridge(get_state().clone()),
    );
    let ctx = InstructionContext::new(run, cancel.clone());

    let report = |_: f64, step: &CenterProgress| {
        let step = match *step {
            CenterProgress::Capturing { attempt } => ApiCenteringStep::Capturing { attempt },
            CenterProgress::Solved {
                attempt,
                ra_hours,
                dec_degrees,
                separation_arcsec,
            } => ApiCenteringStep::Solved {
                attempt,
                ra_hours,
                dec_degrees,
                separation_arcsec,
            },
            CenterProgress::Correcting { attempt } => ApiCenteringStep::Correcting { attempt },
            CenterProgress::Starting { .. }
            | CenterProgress::Centered { .. }
            | CenterProgress::Rotating { .. } => return,
        };
        if let Err(error) = sink.add(step) {
            tracing::debug!("Centering: the app stopped listening ({error})");
        }
    };
    let result = execute_center(&config, &ctx, Some(&report)).await;

    let cancelled = result.status == NodeStatus::Cancelled || cancel.load(Ordering::Relaxed);
    let message = result.message.unwrap_or_else(|| {
        if cancelled {
            "Centering stopped".to_string()
        } else {
            "Centering ended".to_string()
        }
    });
    sink.add(ApiCenteringStep::Finished {
        centered: result.status == NodeStatus::Success,
        cancelled,
        message,
    })
    .map_err(|e| SkotiqError::OperationFailed(format!("Centering result not delivered: {e}")))
}

/// Stop the centering run in progress: the exposure or slew under way is
/// aborted and the run ends cancelled. Nothing happens when none runs.
#[flutter_rust_bridge::frb(sync)]
pub fn api_cancel_centering() {
    if CENTERING_ACTIVE.load(Ordering::Acquire) {
        cancel_token().store(true, Ordering::Relaxed);
    }
}

fn validated_config(request: &ApiCenteringRequest) -> Result<CenterConfig, SkotiqError> {
    let invalid = |what: &str| Err(SkotiqError::InvalidParameter(what.to_string()));
    if !request.ra_hours.is_finite() || !(0.0..=24.0).contains(&request.ra_hours) {
        return invalid("Target RA must be between 0 and 24 hours");
    }
    if !request.dec_degrees.is_finite() || !(-90.0..=90.0).contains(&request.dec_degrees) {
        return invalid("Target declination must be between -90° and +90°");
    }
    if request.max_attempts < 1 {
        return invalid("Centering needs at least one attempt");
    }
    if !request.accuracy_arcsec.is_finite() || request.accuracy_arcsec <= 0.0 {
        return invalid("Centering accuracy must be greater than zero");
    }
    if !request.exposure_secs.is_finite() || request.exposure_secs <= 0.0 {
        return invalid("Centering exposure time must be greater than zero");
    }
    Ok(CenterConfig {
        use_target_coords: false,
        custom_ra: Some(request.ra_hours),
        custom_dec: Some(request.dec_degrees),
        accuracy_arcsec: request.accuracy_arcsec,
        max_attempts: request.max_attempts,
        exposure_duration: request.exposure_secs,
        filter: request.filter.clone(),
        sync_mount: request.sync_mount,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request() -> ApiCenteringRequest {
        ApiCenteringRequest {
            mount_id: "mount".into(),
            camera_id: "camera".into(),
            filter_wheel_id: None,
            ra_hours: 5.5,
            dec_degrees: -5.4,
            accuracy_arcsec: 10.0,
            max_attempts: 3,
            exposure_secs: 2.0,
            filter: None,
            sync_mount: true,
        }
    }

    #[test]
    fn a_request_centers_on_its_own_coordinates() {
        let config = validated_config(&request()).unwrap();
        assert!(!config.use_target_coords);
        assert_eq!((config.custom_ra, config.custom_dec), (Some(5.5), Some(-5.4)));
        assert_eq!(config.max_attempts, 3);
    }

    #[test]
    fn an_impossible_request_is_refused_before_any_frame() {
        for broken in [
            ApiCenteringRequest {
                ra_hours: 25.0,
                ..request()
            },
            ApiCenteringRequest {
                dec_degrees: f64::NAN,
                ..request()
            },
            ApiCenteringRequest {
                max_attempts: 0,
                ..request()
            },
            ApiCenteringRequest {
                exposure_secs: 0.0,
                ..request()
            },
        ] {
            assert!(validated_config(&broken).is_err(), "{broken:?}");
        }
    }

    #[test]
    fn one_centering_run_is_admitted_at_a_time() {
        let first = CenteringAdmission::try_admit().expect("idle");
        assert!(CenteringAdmission::try_admit().is_none());
        drop(first);
        assert!(CenteringAdmission::try_admit().is_some());
    }
}
