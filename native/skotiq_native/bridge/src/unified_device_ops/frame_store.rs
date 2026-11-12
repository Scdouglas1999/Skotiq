use super::*;

#[async_trait]
impl FrameStoreOps for UnifiedDeviceOps {
    async fn save_fits(
        &self,
        image_data: &ImageData,
        file_path: &str,
        frame_ctx: &skotiq_sequencer::scheduling::FrameContext,
    ) -> DeviceResult<()> {
        tracing::info!(
            "Saving FITS image to: {} ({})",
            file_path,
            frame_ctx.log_label()
        );

        // Only ask the mount when the caller did not already sample it. A
        // sequencer frame arrives with the pointing on its `FrameContext`, and
        // re-reading here would both cost a driver round-trip per saved frame
        // and re-open the gap this whole path exists to close — two reads of a
        // moving mount, taken at different instants, disagreeing about one
        // frame. What such a frame CAN still be missing is the derived
        // altitude, which app settings can supply even when the sequencer's own
        // location seed could not.
        // The horizon frame is evaluated at the EXPOSURE MIDPOINT, not at save
        // time: this runs after readout, so `Utc::now()` here dated the
        // altitude — and therefore AIRMASS — by the whole exposure plus
        // download. See `FrameContext::exposure_midpoint`. Frames that never
        // recorded a shutter-open instant fall back to the clock, which is no
        // worse than before.
        let sky_epoch = frame_ctx
            .exposure_midpoint()
            .unwrap_or_else(chrono::Utc::now);
        let pointing = if frame_ctx.mount_ra_hours.is_some() {
            context_altitude_pointing(frame_ctx, self.get_observer_location(), sky_epoch)
        } else {
            self.read_mount_pointing(sky_epoch).await
        };
        let header = build_rich_header(image_data, frame_ctx, pointing);

        crate::frame_header::write_frame_fits(
            file_path.to_string(),
            image_data.width,
            image_data.height,
            image_data.data.clone(),
            header,
        )
        .await
        .map_err(|e| format!("Save FITS failed: {}", e).into())
    }

    async fn calculate_image_hfr(&self, image_data: &ImageData) -> DeviceResult<Option<f64>> {
        // The grading and HFR-trigger metric. Not the mean of every
        // detection's HFR: on a real frame most detections are faint, and the
        // detector's clipped 41x41 box reads them at 15-16 px, so the 09-14
        // run graded an in-focus frame (HFR ~1.9 px by an independent fit) at
        // 13.22 px and rejected every frame of the night.
        Ok(frame_shape(image_data).map(|shape| shape.hfr))
    }

    async fn detect_stars_in_image(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Vec<(f64, f64, f64)>> {
        use skotiq_imaging::{detect_stars, StarDetectionConfig};

        let img = skotiq_imaging::ImageData::from_u16(
            image_data.width,
            image_data.height,
            1,
            &image_data.data,
        );

        let config = StarDetectionConfig::default();
        let stars = detect_stars(&img, &config);

        // Convert to (x, y, hfr) tuples
        let result: Vec<(f64, f64, f64)> = stars.iter().map(|s| (s.x, s.y, s.hfr)).collect();

        Ok(result)
    }

    async fn measure_frame_eccentricity(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<f64>> {
        // Adaptive moments over isolated, unsaturated stars. The detector's
        // own moments include the round seeing halo and its clipped noise
        // floor, which read three trailed 09-14 frames (0.83-0.98 by a PSF
        // fit) at 0.52-0.74, under the 0.7 gate. `None` when fewer than five
        // stars can be measured, never a fabricated value.
        Ok(frame_shape(image_data).map(|shape| shape.eccentricity))
    }

    async fn measure_frame_trail(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<skotiq_imaging::FrameTrail>> {
        let img = skotiq_imaging::ImageData::from_u16(
            image_data.width,
            image_data.height,
            1,
            &image_data.data,
        );
        Ok(skotiq_imaging::measure_frame_trail(&img))
    }

    async fn measure_frame_star_shape(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<Option<skotiq_sequencer::FrameStarShape>> {
        Ok(
            frame_shape(image_data).map(|shape| skotiq_sequencer::FrameStarShape {
                eccentricity: shape.eccentricity,
                elongation: Some((shape.elongation_angle_deg, shape.elongation_consistency)),
            }),
        )
    }
}

/// Star size and shape for one frame, the grader's view of it.
fn frame_shape(image_data: &ImageData) -> Option<skotiq_imaging::FrameShape> {
    let img = skotiq_imaging::ImageData::from_u16(
        image_data.width,
        image_data.height,
        1,
        &image_data.data,
    );
    skotiq_imaging::measure_frame_shape(&img)
}
