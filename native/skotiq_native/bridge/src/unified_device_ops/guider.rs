use super::*;

#[async_trait]
impl GuiderOps for UnifiedDeviceOps {
    async fn guider_dither(
        &self,
        pixels: f64,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
        ra_only: bool,
    ) -> DeviceResult<()> {
        tracing::info!(
            "Dithering {} pixels (settle: <{}px in {}s)",
            pixels,
            settle_pixels,
            settle_time
        );

        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or(DeviceError::NO_GUIDER)?;
        api_guider_dither(
            guider_id,
            pixels,
            ra_only as u8,
            settle_pixels,
            settle_time,
            settle_timeout,
        )
        .await
        .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))
    }

    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or(DeviceError::NO_GUIDER)?;
        let status = api_guider_get_status(guider_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))?;

        Ok(GuidingStatus {
            is_guiding: status.state == "Guiding",
            rms_ra: status.rms_ra,
            rms_dec: status.rms_dec,
            rms_total: status.rms_total,
        })
    }

    async fn guider_is_active(&self) -> DeviceResult<bool> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or(DeviceError::NO_GUIDER)?;
        let status = api_guider_get_status(guider_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))?;
        Ok(guider_state_may_move_mount(&status.state))
    }

    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or(DeviceError::NO_GUIDER)?;
        let calib = crate::api::phd2::api_guider_get_calibration(guider_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))?;
        Ok(GuidingCalibration {
            is_calibrated: calib.is_calibrated,
            ra_angle_deg: calib.ra_angle,
            dec_angle_deg: calib.dec_angle,
        })
    }

    async fn guider_start(
        &self,
        settle_pixels: f64,
        settle_time: f64,
        settle_timeout: f64,
    ) -> DeviceResult<()> {
        tracing::info!("Starting guiding");

        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or(DeviceError::NO_GUIDER)?;
        api_guider_start_guiding(guider_id, settle_pixels, settle_time, settle_timeout)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))
    }

    async fn guider_select_fresh_star(&self) -> DeviceResult<()> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or(DeviceError::NO_GUIDER)?;
        crate::api::phd2::select_fresh_guide_star(&guider_id, None)
            .await
            .map(|_| ())
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))
    }

    async fn guider_select_fresh_star_above(
        &self,
        floor: skotiq_sequencer::GuideStarFloor,
    ) -> DeviceResult<()> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or(DeviceError::NO_GUIDER)?;
        crate::api::phd2::select_fresh_guide_star(&guider_id, Some(floor))
            .await
            .map(|_| ())
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))
    }

    async fn guider_star_quality(
        &self,
    ) -> DeviceResult<Option<skotiq_sequencer::GuideStarQuality>> {
        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or(DeviceError::NO_GUIDER)?;
        let status = api_guider_get_status(guider_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))?;
        Ok((status.snr > 0.0 && status.star_mass > 0.0).then_some(
            skotiq_sequencer::GuideStarQuality {
                snr: status.snr,
                star_mass: status.star_mass,
            },
        ))
    }

    async fn guider_stop(&self) -> DeviceResult<()> {
        tracing::info!("Stopping guiding");

        let guider_id = get_active_guider_id_for_ops()
            .await
            .ok_or(DeviceError::NO_GUIDER)?;
        crate::api::phd2::guider_stop_for_run(guider_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))
    }

    async fn guider_note_stop_reason(&self, reason: Option<skotiq_sequencer::GuidingStopReason>) {
        crate::api::phd2::set_guiding_stop_reason(reason);
    }
}

/// Whether a guider in `state` (PHD2's app state, or the built-in guider's)
/// may move the mount: anything but connected-and-idle, looping or paused.
/// PHD2 in LostLock keeps searching and guides again the moment it finds the
/// star; settling and calibrating move the mount; a state this build does not
/// know is treated as active.
pub(crate) fn guider_state_may_move_mount(state: &str) -> bool {
    !matches!(
        state,
        "Disconnected" | "Connected" | "Stopped" | "Selected" | "Looping" | "Paused"
    )
}

#[cfg(test)]
mod guider_state_tests {
    use super::guider_state_may_move_mount;

    #[test]
    fn a_guider_that_may_move_the_mount_is_any_but_idle_looping_or_paused() {
        for state in [
            "Guiding",
            "Calibrating",
            "Settling",
            "LostLock",
            "GuidingPaused",
        ] {
            assert!(guider_state_may_move_mount(state), "{state}");
        }
        for state in [
            "Disconnected",
            "Connected",
            "Stopped",
            "Selected",
            "Looping",
            "Paused",
        ] {
            assert!(!guider_state_may_move_mount(state), "{state}");
        }
    }
}
