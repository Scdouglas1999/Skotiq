use crate::device_manager::{rig, DeviceManager};
use crate::dispatch::error::DeviceOpError;
use skotiq_device::ImageData;

impl DeviceManager {
    pub async fn camera_download_image(&self, device_id: &str) -> Result<ImageData, DeviceOpError> {
        let camera = self.camera(device_id).await?;

        rig::camera::download(camera.as_ref(), device_id).await
    }

    /// Capture a live-view / preview JPEG frame when the connected driver supports it.
    pub async fn camera_capture_preview(&self, device_id: &str) -> Result<Vec<u8>, DeviceOpError> {
        let camera = self.camera(device_id).await?;

        camera.capture_preview().await
    }
}

#[cfg(test)]
mod alpaca_bayer_gate_tests {
    use skotiq_device::ascom::sensor_type::{bayer_pattern_from_sensor, has_nameable_bayer_order};
    use skotiq_device::BayerPattern;
    use std::cell::Cell;

    /// Stands in for the Alpaca camera's `BayerOffsetX`/`BayerOffsetY`
    /// properties and counts how many times they are read.
    struct OffsetSpy {
        offset_x: Result<i32, String>,
        offset_y: Result<i32, String>,
        reads: Cell<u32>,
    }

    impl OffsetSpy {
        fn readable(x: i32, y: i32) -> Self {
            Self {
                offset_x: Ok(x),
                offset_y: Ok(y),
                reads: Cell::new(0),
            }
        }

        fn unreadable() -> Self {
            Self {
                offset_x: Err("BayerOffsetX not implemented".to_string()),
                offset_y: Err("BayerOffsetY not implemented".to_string()),
                reads: Cell::new(0),
            }
        }

        async fn bayer_offset_x(&self) -> Result<i32, String> {
            self.reads.set(self.reads.get() + 1);
            self.offset_x.clone()
        }

        async fn bayer_offset_y(&self) -> Result<i32, String> {
            self.reads.set(self.reads.get() + 1);
            self.offset_y.clone()
        }
    }

    /// Mirrors the `SensorType`/offset gate in the Alpaca branch of
    /// `camera_download_image` so it is exercised without an HTTP camera: the
    /// offsets are read only for a family whose element order they can name,
    /// and the pattern always comes from `ascom_sensor_type`.
    async fn download_bayer_pattern(sensor_type: i32, camera: &OffsetSpy) -> Option<BayerPattern> {
        let (offset_x, offset_y) = if has_nameable_bayer_order(sensor_type) {
            match (camera.bayer_offset_x().await, camera.bayer_offset_y().await) {
                (Ok(x), Ok(y)) => (Some(x), Some(y)),
                (_, _) => (None, None),
            }
        } else {
            (None, None)
        };
        bayer_pattern_from_sensor(sensor_type, offset_x, offset_y)
    }

    /// SensorType 2 is the RGGB family; the offset pair names which corner
    /// holds red, so all four orders are reachable from the one ordinal.
    #[tokio::test]
    async fn rggb_family_maps_every_offset_corner() {
        for (x, y, expected) in [
            (0, 0, BayerPattern::Rggb),
            (1, 1, BayerPattern::Bggr),
            (0, 1, BayerPattern::Gbrg),
            (1, 0, BayerPattern::Grbg),
        ] {
            let camera = OffsetSpy::readable(x, y);
            assert_eq!(
                download_bayer_pattern(2, &camera).await,
                Some(expected),
                "offsets ({x}, {y}) named the wrong element order"
            );
            assert_eq!(
                camera.reads.get(),
                2,
                "both offsets are read, never assumed"
            );
        }
    }

    /// SensorType 1 is a direct-colour sensor with no Bayer mask: its offsets
    /// name nothing, so they are not read and no BAYERPAT card is produced.
    #[tokio::test]
    async fn direct_colour_sensor_reads_no_offsets_and_has_no_pattern() {
        let camera = OffsetSpy::readable(0, 0);
        assert_eq!(download_bayer_pattern(1, &camera).await, None);
        assert_eq!(
            camera.reads.get(),
            0,
            "a Bayer-less colour sensor's offsets are meaningless, so they are not read"
        );
    }

    /// Monochrome carries no mask either.
    #[tokio::test]
    async fn monochrome_sensor_reads_no_offsets_and_has_no_pattern() {
        let camera = OffsetSpy::readable(0, 0);
        assert_eq!(download_bayer_pattern(0, &camera).await, None);
        assert_eq!(camera.reads.get(), 0);
    }

    /// CMYG (3), CMYG2 (4) and LRGB (5) are mosaics whose offsets index an
    /// order `BayerPattern` cannot express, so the pattern stays unknown.
    #[tokio::test]
    async fn non_rggb_mosaics_have_no_nameable_order() {
        for sensor_type in [3, 4, 5] {
            let camera = OffsetSpy::readable(0, 0);
            assert_eq!(
                download_bayer_pattern(sensor_type, &camera).await,
                None,
                "SensorType={sensor_type} named an RGGB pattern"
            );
            assert_eq!(camera.reads.get(), 0);
        }
    }

    /// An unreadable offset leaves the pattern unknown rather than defaulting
    /// to the (0, 0) corner, which would transpose red and blue on a BGGR or
    /// GRBG sensor and stamp the wrong BAYERPAT.
    #[tokio::test]
    async fn unreadable_offsets_leave_the_pattern_unknown() {
        let camera = OffsetSpy::unreadable();
        assert_eq!(download_bayer_pattern(2, &camera).await, None);
        assert_eq!(camera.reads.get(), 2);
    }

    /// A half-readable pair is unknown too: one axis cannot name a corner.
    #[tokio::test]
    async fn partially_readable_offsets_leave_the_pattern_unknown() {
        let camera = OffsetSpy {
            offset_x: Ok(1),
            offset_y: Err("BayerOffsetY not implemented".to_string()),
            reads: Cell::new(0),
        };
        assert_eq!(download_bayer_pattern(2, &camera).await, None);
    }

    /// An offset pair outside the 2×2 block is unknown, not silently RGGB.
    #[tokio::test]
    async fn out_of_range_offsets_leave_the_pattern_unknown() {
        let camera = OffsetSpy::readable(2, 0);
        assert_eq!(download_bayer_pattern(2, &camera).await, None);
    }

    /// A failed `SensorType` read names no family, so nothing is read and
    /// nothing is guessed.
    #[tokio::test]
    async fn unknown_sensor_type_reads_no_offsets_and_has_no_pattern() {
        let camera = OffsetSpy::readable(0, 0);
        assert_eq!(download_bayer_pattern(-1, &camera).await, None);
        assert_eq!(camera.reads.get(), 0);
    }
}
