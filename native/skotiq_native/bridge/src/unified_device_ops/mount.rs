use super::*;

#[async_trait]
impl MountOps for UnifiedDeviceOps {
    async fn mount_slew_to_coordinates(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()> {
        tracing::info!(
            "Slewing mount {} to RA={:.4}h Dec={:.4}°",
            mount_id,
            ra_hours,
            dec_degrees
        );

        // `DeviceManager::mount_slew` publishes the slew's start and arrival.
        get_device_manager()
            .mount_slew(mount_id, ra_hours, dec_degrees)
            .await
            .map_err(|e| format!("Slew failed: {}", e))
    }

    async fn mount_slew_state(&self, mount_id: &str) -> skotiq_sequencer::slew_arrival::SlewSample {
        match get_device_manager().mount_get_status(mount_id).await {
            Ok(status) => skotiq_sequencer::slew_arrival::SlewSample {
                slewing: Some(status.slewing),
                position: Some((status.right_ascension, status.declination)),
            },
            Err(e) => {
                tracing::debug!("Slew status read for {} failed: {}", mount_id, e);
                skotiq_sequencer::slew_arrival::SlewSample {
                    slewing: None,
                    position: None,
                }
            }
        }
    }

    async fn mount_abort_slew(&self, mount_id: &str) -> DeviceResult<()> {
        tracing::info!("Aborting slew for mount {}", mount_id);

        get_device_manager()
            .mount_abort(mount_id)
            .await
            .map_err(|e| format!("Abort slew failed: {}", e))
    }

    async fn mount_get_coordinates(&self, mount_id: &str) -> DeviceResult<(f64, f64)> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        Ok((status.right_ascension, status.declination))
    }

    async fn mount_readback_frame(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<(f64, f64)> {
        // Mirror `DeviceManager::mount_slew`/`mount_sync` exactly — the same
        // `epoch::j2000_to_mount_frame` decision, simulator frame included:
        // whatever transform is applied on the way TO the mount has to be
        // applied to a target before it is compared with what the mount reads
        // BACK. If these two ever disagree, a correct slew reports as a miss by
        // the precession offset.
        let driver_type = get_device_manager()
            .get_device(mount_id)
            .await
            .map(|device| device.info.driver_type);

        Ok(match driver_type {
            // An unknown device id is not a licence to guess: report the target
            // unchanged and let the caller's own error path say the mount is
            // missing, rather than inventing a precessed position for it.
            None => (ra_hours, dec_degrees),
            Some(driver_type) => crate::device_manager::epoch::j2000_to_mount_frame(
                driver_type,
                ra_hours,
                dec_degrees,
            ),
        })
    }

    async fn mount_readback_to_j2000(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<(f64, f64)> {
        let driver_type = get_device_manager()
            .get_device(mount_id)
            .await
            .map(|device| device.info.driver_type)
            .ok_or_else(|| format!("mount {mount_id} is not registered"))?;
        Ok(crate::device_manager::epoch::mount_frame_to_j2000(
            driver_type,
            ra_hours,
            dec_degrees,
        ))
    }

    async fn mount_sync(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> DeviceResult<()> {
        tracing::info!(
            "Syncing mount {} to RA={:.4}h Dec={:.4}°",
            mount_id,
            ra_hours,
            dec_degrees
        );

        get_device_manager()
            .mount_sync(mount_id, ra_hours, dec_degrees)
            .await
            .map_err(|e| format!("Sync failed: {}", e))
    }

    async fn mount_park(&self, mount_id: &str) -> DeviceResult<()> {
        tracing::info!("Parking mount {}", mount_id);

        // `DeviceManager::mount_park` publishes the park's start and end.
        get_device_manager()
            .mount_park(mount_id)
            .await
            .map_err(|e| format!("Park failed: {}", e))
    }

    async fn mount_unpark(&self, mount_id: &str) -> DeviceResult<()> {
        tracing::info!("Unparking mount {}", mount_id);

        // `DeviceManager::mount_unpark` publishes `MountUnparked`.
        get_device_manager()
            .mount_unpark(mount_id)
            .await
            .map_err(|e| format!("Unpark failed: {}", e))
    }

    async fn mount_find_home(&self, mount_id: &str) -> DeviceResult<()> {
        tracing::info!("Homing mount {}", mount_id);

        get_device_manager()
            .mount_find_home(mount_id)
            .await
            .map_err(|e| format!("Home failed: {}", e))
    }

    async fn mount_is_at_home(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        status
            .at_home
            .ok_or_else(|| "Mount does not report whether it is at home".to_string())
    }

    async fn mount_is_slewing(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        Ok(status.slewing)
    }

    async fn mount_is_parked(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        parked_from_status(mount_id, &status)
    }

    async fn mount_can_flip(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        if !status.can_slew {
            return Ok(false);
        }
        // None (couldn't read or unsupported) collapses to Unknown — both
        // prevent the sequencer from issuing a meridian flip.
        match status.side_of_pier {
            None | Some(crate::device::PierSide::Unknown) => Err(
                "Mount does not report side-of-pier state; flip capability cannot be determined"
                    .to_string(),
            ),
            Some(_) => Ok(true),
        }
    }

    async fn mount_side_of_pier(
        &self,
        mount_id: &str,
    ) -> DeviceResult<skotiq_sequencer::meridian::PierSide> {
        // Get pier side from mount status. None collapses to Unknown so the
        // meridian module receives a single "indeterminate" signal.
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        Ok(match status.side_of_pier {
            Some(crate::device::PierSide::East) => skotiq_sequencer::meridian::PierSide::East,
            Some(crate::device::PierSide::West) => skotiq_sequencer::meridian::PierSide::West,
            Some(crate::device::PierSide::Unknown) | None => {
                skotiq_sequencer::meridian::PierSide::Unknown
            }
        })
    }

    async fn mount_is_tracking(&self, mount_id: &str) -> DeviceResult<bool> {
        let status = get_device_manager()
            .mount_get_status(mount_id)
            .await
            .map_err(|e| format!("Failed to get mount status: {}", e))?;

        Ok(status.tracking)
    }

    async fn mount_move_axis(
        &self,
        mount_id: &str,
        axis: i32,
        rate_deg_per_sec: f64,
    ) -> DeviceResult<()> {
        get_device_manager()
            .mount_move_axis(mount_id, axis, rate_deg_per_sec)
            .await
            .map_err(|e| format!("Move axis failed: {}", e))
    }

    async fn mount_set_tracking(&self, mount_id: &str, enabled: bool) -> DeviceResult<()> {
        tracing::info!(
            "Setting tracking {} for mount {}",
            if enabled { "on" } else { "off" },
            mount_id
        );

        get_device_manager()
            .mount_set_tracking(mount_id, enabled)
            .await
            .map_err(|e| format!("Set tracking failed: {}", e))
    }

    async fn request_mount_fault_hold(&self, mount_id: &str, message: &str) {
        tracing::warn!("[MOTION GUARD] {mount_id}: {message}");
        let message = message.to_string();
        // The executor lock is not taken from inside the run's own task.
        tokio::spawn(async move {
            let executor = skotiq_sequencer::get_executor().read().await;
            if let Err(e) = executor.hold_for_mount_fault(&message).await {
                tracing::error!("[MOTION GUARD] Could not hold the run: {e}");
            }
        });
    }
}

/// Decisions-verify refutation D4 (2026-08-14, corrected by the focused
/// re-refute): a mount that cannot READ park state (the LX200 family without
/// a cached park entry) reaches the status layer as a fabricated
/// `parked=false`, marked by `availability[PARKED] = Unsupported`. Surface
/// that unknowability as an error so callers take their read-failed path
/// (the sequencer's unpark gate falls through and issues the unpark) instead
/// of trusting a value the mount never produced.
///
/// `can_park=false` alone is NOT the signal: ASCOM mandates `AtPark` be
/// readable regardless of `CanPark`, and Alpaca can lose `can_park` to a
/// transient capabilities hiccup while reading `parked` genuinely — erroring
/// on those would fail every autopilot run at its head `Unpark` node on
/// mounts that simply cannot park.
fn parked_from_status(mount_id: &str, status: &crate::device::MountStatus) -> DeviceResult<bool> {
    use crate::device::{mount_status_field, FieldAvailability};
    match status.availability.get(mount_status_field::PARKED) {
        Some(FieldAvailability::Unsupported) | Some(FieldAvailability::Error(_)) => {
            Err(format!("Mount {} cannot report park state", mount_id))
        }
        _ => Ok(status.parked),
    }
}

#[cfg(test)]
mod parked_from_status_tests {
    use super::parked_from_status;
    use crate::device::MountStatus;
    use std::collections::HashMap;

    fn status(parked: bool, can_park: bool) -> MountStatus {
        MountStatus {
            connected: true,
            tracking: false,
            slewing: false,
            parked,
            at_home: None,
            side_of_pier: None,
            right_ascension: 0.0,
            declination: 0.0,
            altitude: None,
            azimuth: None,
            sidereal_time: None,
            tracking_rate: None,
            can_park,
            can_slew: true,
            can_sync: true,
            can_pulse_guide: false,
            can_set_tracking_rate: false,
            availability: HashMap::new(),
        }
    }

    #[test]
    fn a_trustworthy_report_passes_through() {
        assert!(parked_from_status("m", &status(true, true)).unwrap());
        assert!(!parked_from_status("m", &status(false, true)).unwrap());
    }

    fn unreadable(mut s: MountStatus) -> MountStatus {
        s.availability.insert(
            crate::device::mount_status_field::PARKED.to_string(),
            crate::device::FieldAvailability::Unsupported,
        );
        s
    }

    /// ASCOM mandates AtPark be readable regardless of CanPark: an honest
    /// "this mount cannot park" with a genuine parked=false must pass
    /// through, or every autopilot run fails at its head Unpark node.
    #[test]
    fn cannot_park_with_a_readable_state_is_not_an_error() {
        assert!(!parked_from_status("m", &status(false, false)).unwrap());
    }

    /// Only a park state the backend could not READ (Native NotSupported,
    /// marked via availability) refuses to serve the fabricated bool.
    #[test]
    fn an_unreadable_park_state_is_an_error_not_a_fabricated_false() {
        let err = parked_from_status("m", &unreadable(status(false, false))).unwrap_err();
        assert!(err.to_string().contains("cannot report park state"));
    }
}
