use super::UnifiedDeviceOps;
use crate::unified_device_ops::pointing::context_altitude_pointing;
use crate::unified_device_ops::rich_header::build_rich_header;
use async_trait::async_trait;
use skotiq_sequencer::{DeviceResult, FrameStoreOps, ImageData, SiteOps};

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

        crate::frame_header::write_capture_frame(
            file_path.to_string(),
            image_data.width,
            image_data.height,
            image_data.data.clone(),
            header,
        )
        .await
        .map_err(|e| format!("Save frame failed: {}", e).into())
    }

    fn frame_file_extension(&self) -> &'static str {
        skotiq_sequencer::executor_handle()
            .run_config()
            .frame_format
            .extension()
    }

    async fn measure_light_frame(
        &self,
        image_data: &ImageData,
    ) -> DeviceResult<skotiq_sequencer::LightFrameMeasurement> {
        // The camera layer detected this frame's stars when it stored it for
        // the screens; unless the samples changed since, that detection is
        // this one.
        let stored = crate::last_frame::detected_stars(
            image_data.width,
            image_data.height,
            &image_data.data,
        )
        .await;
        let image = skotiq_imaging::ImageData::from_u16(
            image_data.width,
            image_data.height,
            1,
            &image_data.data,
        );
        // Seconds of CPU on a large sensor: off the async runtime, which also
        // carries the event bridge, the device heartbeats and the HTTP API.
        tokio::task::spawn_blocking(move || {
            measure_light_frame(&image, stored.as_deref().map(Vec::as_slice))
        })
        .await
        .map_err(|e| format!("Star measurement stopped: {e}").into())
    }
}

/// One detection serves the star count and the shape: `detected` when the
/// caller has the frame's stars already, else a fresh one. The trail is
/// measured from the image alongside it.
///
/// The HFR is the shape's, not the mean of every detection's HFR: on a real
/// frame most detections are faint, and the detector's clipped 41x41 box reads
/// them at 15-16 px, so the 09-14 run graded an in-focus frame (HFR ~1.9 px by
/// an independent fit) at 13.22 px and rejected every frame of the night. The
/// eccentricity is from adaptive moments over isolated, unsaturated stars: the
/// detector's own moments include the round seeing halo and its clipped noise
/// floor, which read three trailed 09-14 frames (0.83-0.98 by a PSF fit) at
/// 0.52-0.74, under the 0.7 gate.
pub(crate) fn measure_light_frame(
    image: &skotiq_imaging::ImageData,
    detected: Option<&[skotiq_imaging::DetectedStar]>,
) -> skotiq_sequencer::LightFrameMeasurement {
    let config = skotiq_imaging::StarDetectionConfig::default();
    let ((star_count, shape), trail) = rayon::join(
        || {
            let fresh;
            let stars = match detected {
                Some(stars) => stars,
                None => {
                    fresh = skotiq_imaging::detect_stars(image, &config);
                    &fresh
                }
            };
            let shape = skotiq_imaging::measure_frame_shape_from(
                image,
                stars,
                f64::from(config.saturation_limit),
            );
            (stars.len() as u32, shape)
        },
        || skotiq_imaging::measure_frame_trail(image),
    );
    skotiq_sequencer::LightFrameMeasurement {
        hfr: shape.map(|shape| shape.hfr),
        star_count: Some(star_count),
        star_shape: shape.map(|shape| skotiq_sequencer::FrameStarShape {
            eccentricity: shape.eccentricity,
            elongation: Some((shape.elongation_angle_deg, shape.elongation_consistency)),
        }),
        trail,
    }
}
