//! `SlewToGapAndContinue`: point at the clear sky the cloud-motion analyzer
//! reports, or pause when there is none to point at.

use super::*;

pub(in super::super) async fn slew_to_gap(
    trigger_name: &str,
    cloud_motion: &RwLock<CloudMotionSnapshot>,
    rig: &Rig,
    run: &RunControl,
) -> ActionFlow {
    let snapshot = cloud_motion.read().await.clone();
    let Some((alt_deg, az_deg)) = snapshot.predicted_clear_sky_direction else {
        // The operator asked to move away from the clouds; doing nothing
        // silently is not an option.
        tracing::warn!(
            "[CLOUD] SlewToGapAndContinue fired but no clear-sky direction reported; falling back to PauseAndWaitForClear"
        );
        run.pause(None).await;
        run.error(format!(
            "Trigger '{}' requested SlewToGapAndContinue but the cloud-motion analyzer has not reported a clear sky direction. Sequence paused.",
            trigger_name,
        ));
        return ActionFlow::Finished;
    };

    let (lat, lon) = {
        let rc = rig.runtime_config.read();
        (rc.latitude, rc.longitude)
    };
    let (Some(lat), Some(lon)) = (lat.or(rig.context.latitude), lon.or(rig.context.longitude))
    else {
        tracing::error!("[CLOUD] SlewToGapAndContinue cannot proceed: observer location not set");
        run.error(
            "SlewToGapAndContinue requested but observer location is not configured. Sequence paused.".to_string(),
        );
        run.pause(None).await;
        return ActionFlow::Finished;
    };

    let (ra_hours, dec_deg) = alt_az_to_ra_dec(alt_deg, az_deg, lat, lon);
    tracing::info!(
        "[CLOUD] SlewToGapAndContinue: clear sky at alt={:.1}°, az={:.1}° -> RA={:.4}h, Dec={:.4}°",
        alt_deg,
        az_deg,
        ra_hours,
        dec_deg
    );
    let slew_ctx = rig.instruction_context(
        TargetSnapshot {
            name: Some("Cloud Gap".to_string()),
            ra_hours: Some(ra_hours),
            dec_degrees: Some(dec_deg),
            filter: None,
        },
        run,
    );
    let slew_config = crate::SlewConfig {
        use_target_coords: false,
        custom_ra: Some(ra_hours),
        custom_dec: Some(dec_deg),
    };
    let result = crate::instructions::execute_slew(&slew_config, &slew_ctx, None).await;
    if result.status != NodeStatus::Success {
        tracing::warn!(
            "[CLOUD] Slew to gap failed: {:?} - pausing sequence",
            result.message
        );
        run.pause(None).await;
        run.error(format!(
            "SlewToGapAndContinue failed: {}",
            result.message.unwrap_or_default()
        ));
    } else {
        tracing::info!("[CLOUD] Slew to gap completed; sequence continues");
    }
    ActionFlow::Finished
}
