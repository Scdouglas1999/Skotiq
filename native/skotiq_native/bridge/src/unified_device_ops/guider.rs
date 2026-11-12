use super::*;
use crate::guider::Guider;

/// The rig's guider, or the sequencer's "no guider" when the profile names
/// none and none is connected.
async fn active_guider() -> DeviceResult<Guider> {
    Guider::active()
        .await
        .map_err(|e| DeviceError::from(e.to_string()))?
        .ok_or(DeviceError::NO_GUIDER)
}

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
        active_guider()
            .await?
            .dither(pixels, ra_only, settle_pixels, settle_time, settle_timeout)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))
    }

    async fn guider_get_status(&self) -> DeviceResult<GuidingStatus> {
        let status = active_guider()
            .await?
            .status()
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
        let status = active_guider()
            .await?
            .status()
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))?;
        Ok(crate::guider::state_may_move_mount(&status.state))
    }

    async fn guider_get_calibration(&self) -> DeviceResult<GuidingCalibration> {
        let calib = active_guider()
            .await?
            .calibration()
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
        active_guider()
            .await?
            .start(settle_pixels, settle_time, settle_timeout)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))
    }

    async fn guider_select_fresh_star(&self) -> DeviceResult<()> {
        active_guider()
            .await?
            .select_fresh_star(None)
            .await
            .map_err(|e| e.to_string().into())
    }

    async fn guider_select_fresh_star_above(
        &self,
        floor: skotiq_sequencer::GuideStarFloor,
    ) -> DeviceResult<()> {
        active_guider()
            .await?
            .select_fresh_star(Some(floor))
            .await
            .map_err(|e| e.to_string().into())
    }

    async fn guider_star_quality(
        &self,
    ) -> DeviceResult<Option<skotiq_sequencer::GuideStarQuality>> {
        let status = active_guider()
            .await?
            .status()
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
        active_guider()
            .await?
            .stop()
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Guider))
    }

    async fn guider_note_stop_reason(&self, reason: Option<skotiq_sequencer::GuidingStopReason>) {
        crate::guider::stop_reason::set(reason);
    }
}
