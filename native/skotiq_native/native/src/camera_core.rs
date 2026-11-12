//! What every vendor camera driver keeps and does the same way.
//!
//! [`CameraCore`] is the state each driver embeds (identity, connection,
//! gain/offset/binning/subframe, what is known of the cooler, exposure timing,
//! capabilities and sensor description), with the one connected check. [`Frame`] is the one
//! place a downloaded frame becomes [`ImageData`]; the free functions are the
//! pixel unpacking and SDK-value conversions the drivers share.
//!
//! Rules that differ between vendors are inputs here, never decided here: each
//! driver names its byte order, its 8-bit rule and the metadata values that
//! do not come from the cached state.

use skotiq_device::camera::{
    BayerPattern, CameraCapabilities, CameraState, ImageData, ImageMetadata, SensorInfo, SubFrame,
    VendorFeatures,
};
use skotiq_device::DriverError;

/// What a driver knows of its camera's cooler: the camera's last read-back
/// or this connection's last accepted command. A field is `None` until one of
/// the two has said it; a driver never fills it with a default, because a
/// camera can still be cooling from an earlier session.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(crate) struct CoolerState {
    pub(crate) enabled: Option<bool>,
    pub(crate) target_c: Option<f64>,
}

impl CoolerState {
    pub(crate) const UNKNOWN: Self = Self {
        enabled: None,
        target_c: None,
    };
}

/// State common to the vendor camera drivers.
#[derive(Debug)]
pub(crate) struct CameraCore {
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) connected: bool,
    pub(crate) capabilities: CameraCapabilities,
    pub(crate) sensor_info: SensorInfo,
    pub(crate) state: CameraState,
    pub(crate) gain: i32,
    pub(crate) offset: i32,
    pub(crate) bin_x: i32,
    pub(crate) bin_y: i32,
    pub(crate) subframe: Option<SubFrame>,
    /// Behind a lock because some drivers refresh it from a status read,
    /// which only has `&self`.
    cooler: std::sync::Mutex<CoolerState>,
    pub(crate) exposure_started_at: Option<std::time::Instant>,
    /// Seconds requested for the exposure in progress or last taken.
    pub(crate) exposure_duration: f64,
}

impl CameraCore {
    /// A disconnected camera at bin 1, gain and offset 0, cooler unknown.
    pub(crate) fn new(device_id: String, name: String) -> Self {
        Self {
            device_id,
            name,
            connected: false,
            capabilities: CameraCapabilities::default(),
            sensor_info: SensorInfo::default(),
            state: CameraState::Idle,
            gain: 0,
            offset: 0,
            bin_x: 1,
            bin_y: 1,
            subframe: None,
            cooler: std::sync::Mutex::new(CoolerState::UNKNOWN),
            exposure_started_at: None,
            exposure_duration: 0.0,
        }
    }

    /// The connected check. Which methods call it, and where among their
    /// other early returns, is each driver's own contract.
    pub(crate) fn require_connected(&self) -> Result<(), DriverError> {
        if self.connected {
            Ok(())
        } else {
            Err(DriverError::NotConnected)
        }
    }

    pub(crate) fn cooler(&self) -> CoolerState {
        *self.cooler.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub(crate) fn update_cooler(&self, update: impl FnOnce(&mut CoolerState)) {
        update(&mut self.cooler.lock().unwrap_or_else(|e| e.into_inner()));
    }

    /// A frame described by the cached state: exposure time, gain, offset,
    /// binning and subframe as last set, no temperature, no vendor data. A
    /// driver overrides the fields its SDK reports for the frame itself.
    pub(crate) fn frame(
        &self,
        width: u32,
        height: u32,
        data: Vec<u16>,
        bits_per_pixel: u32,
        bayer_pattern: Option<BayerPattern>,
    ) -> Frame {
        Frame {
            width,
            height,
            data,
            bits_per_pixel,
            bayer_pattern,
            exposure_time: self.exposure_duration,
            gain: self.gain,
            offset: self.offset,
            bin_x: self.bin_x,
            bin_y: self.bin_y,
            temperature: None,
            subframe: self.subframe.clone(),
            readout_mode: None,
            vendor_data: VendorFeatures::default(),
        }
    }
}

/// Everything a driver knows about one downloaded frame.
pub(crate) struct Frame {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) data: Vec<u16>,
    pub(crate) bits_per_pixel: u32,
    pub(crate) bayer_pattern: Option<BayerPattern>,
    pub(crate) exposure_time: f64,
    pub(crate) gain: i32,
    pub(crate) offset: i32,
    pub(crate) bin_x: i32,
    pub(crate) bin_y: i32,
    pub(crate) temperature: Option<f64>,
    pub(crate) subframe: Option<SubFrame>,
    pub(crate) readout_mode: Option<String>,
    pub(crate) vendor_data: VendorFeatures,
}

impl Frame {
    /// The frame hand-off. The timestamp is the moment of the hand-off.
    pub(crate) fn into_image(self) -> ImageData {
        ImageData {
            width: self.width,
            height: self.height,
            data: self.data,
            bits_per_pixel: self.bits_per_pixel,
            bayer_pattern: self.bayer_pattern,
            metadata: ImageMetadata {
                exposure_time: self.exposure_time,
                gain: self.gain,
                offset: self.offset,
                bin_x: self.bin_x,
                bin_y: self.bin_y,
                temperature: self.temperature,
                timestamp: chrono::Utc::now(),
                subframe: self.subframe,
                readout_mode: self.readout_mode,
                vendor_data: self.vendor_data,
                camera_file: None,
            },
        }
    }
}

/// How a vendor SDK lays samples out in the byte buffer it fills.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SampleLayout {
    /// 16-bit samples in host byte order.
    U16Native,
    /// 16-bit samples, little-endian on the wire.
    U16Little,
    /// 8-bit samples scaled to the 16-bit range (`x * 256`).
    U8Scaled,
    /// 8-bit samples kept at their own value.
    U8Unscaled,
}

/// Decode an SDK byte buffer into 16-bit pixels. A trailing odd byte of a
/// 16-bit buffer is dropped.
pub(crate) fn unpack_samples(bytes: &[u8], layout: SampleLayout) -> Vec<u16> {
    match layout {
        SampleLayout::U16Native => bytes
            .as_chunks::<2>()
            .0
            .iter()
            .map(|chunk| u16::from_ne_bytes([chunk[0], chunk[1]]))
            .collect(),
        SampleLayout::U16Little => bytes
            .as_chunks::<2>()
            .0
            .iter()
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect(),
        // u8 widened to u16 times 256 tops out at 65280, inside u16.
        SampleLayout::U8Scaled => bytes.iter().map(|&x| (x as u16) * 256).collect(),
        SampleLayout::U8Unscaled => bytes.iter().copied().map(u16::from).collect(),
    }
}

/// A ROI dimension an SDK reported as a C `int`. A negative value is SDK
/// corruption and is reported instead of wrapping into a huge `u32`.
pub(crate) fn roi_dimension(vendor: &str, axis: &str, value: i32) -> Result<u32, DriverError> {
    u32::try_from(value).map_err(|_| {
        DriverError::SdkError(format!(
            "{} returned negative ROI {}: {}",
            vendor, axis, value
        ))
    })
}

/// An image dimension computed as `usize`, narrowed to the `u32` of [`ImageData`].
pub(crate) fn image_dimension(vendor: &str, axis: &str, value: usize) -> Result<u32, DriverError> {
    u32::try_from(value).map_err(|_| {
        DriverError::SdkError(format!(
            "{} image {} does not fit in u32: {}",
            vendor, axis, value
        ))
    })
}

/// The device layer's name for a decoded raw frame's color filter.
pub(crate) fn mosaic_bayer_pattern(cfa: &skotiq_imaging::ColorFilterArray) -> BayerPattern {
    use skotiq_imaging::BayerPattern as Cell;
    match cfa {
        skotiq_imaging::ColorFilterArray::Bayer(Cell::RGGB) => BayerPattern::Rggb,
        skotiq_imaging::ColorFilterArray::Bayer(Cell::GRBG) => BayerPattern::Grbg,
        skotiq_imaging::ColorFilterArray::Bayer(Cell::GBRG) => BayerPattern::Gbrg,
        skotiq_imaging::ColorFilterArray::Bayer(Cell::BGGR) => BayerPattern::Bggr,
        skotiq_imaging::ColorFilterArray::XTrans(_) => BayerPattern::XTrans(
            skotiq_device::XTransCell::from_letters(&cfa.letters())
                .expect("an X-Trans cell is 36 R, G and B letters"),
        ),
    }
}

/// The Bayer index the ASI-style SDKs (ZWO, Player One, SVBony) report:
/// 0 RGGB, 1 BGGR, 2 GRBG, 3 GBRG. Anything else reads as RGGB.
pub(crate) fn bayer_from_asi_index(index: i32) -> BayerPattern {
    match index {
        0 => BayerPattern::Rggb,
        1 => BayerPattern::Bggr,
        2 => BayerPattern::Grbg,
        3 => BayerPattern::Gbrg,
        _ => BayerPattern::Rggb,
    }
}

/// A raw vendor SDK device handle held by a driver.
///
/// The pointer is opaque: a driver never dereferences it, it only hands it
/// back to the SDK that issued it, and only while holding that SDK's lock.
pub(crate) struct SdkHandle<T>(pub(crate) T);

// SAFETY: the wrapped value is an opaque token for the vendor SDK. Every use
// passes it to an SDK function under that SDK's lock guard (the exceptions are
// listed at their call sites), so moving it to another thread cannot cause
// concurrent access to what it points at.
unsafe impl<T> Send for SdkHandle<T> {}
// SAFETY: as for `Send`: shared references only ever copy the token out to
// pass it to the SDK under its lock.
unsafe impl<T> Sync for SdkHandle<T> {}

impl<T: std::fmt::Pointer> std::fmt::Debug for SdkHandle<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SdkHandle({:p})", self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BYTES: [u8; 9] = [0x00, 0x01, 0xff, 0x00, 0x34, 0x12, 0xff, 0xff, 0x7f];

    // The expressions below are the ones each driver had inline before it used
    // `unpack_samples`; the shared function must give the same pixels.

    #[test]
    fn native_order_unpacking_matches_the_zwo_and_player_one_expression() {
        let legacy: Vec<u16> = BYTES
            .as_chunks::<2>()
            .0
            .iter()
            .map(|chunk| u16::from_ne_bytes([chunk[0], chunk[1]]))
            .collect();
        assert_eq!(unpack_samples(&BYTES, SampleLayout::U16Native), legacy);
        assert_eq!(legacy.len(), 4);
    }

    #[test]
    fn little_endian_unpacking_matches_the_qhy_svbony_atik_fli_expression() {
        let legacy: Vec<u16> = BYTES
            .as_chunks::<2>()
            .0
            .iter()
            .map(|chunk| u16::from_le_bytes([chunk[0], chunk[1]]))
            .collect();
        assert_eq!(unpack_samples(&BYTES, SampleLayout::U16Little), legacy);
        assert_eq!(legacy, vec![0x0100, 0x00ff, 0x1234, 0xffff]);
    }

    #[test]
    fn scaled_eight_bit_matches_the_zwo_player_one_qhy_expression() {
        let legacy: Vec<u16> = BYTES.iter().map(|&x| (x as u16) * 256).collect();
        assert_eq!(unpack_samples(&BYTES, SampleLayout::U8Scaled), legacy);
        assert_eq!(legacy[2], 65280);
    }

    #[test]
    fn unscaled_eight_bit_matches_the_svbony_expression() {
        let legacy: Vec<u16> = BYTES.iter().copied().map(u16::from).collect();
        assert_eq!(unpack_samples(&BYTES, SampleLayout::U8Unscaled), legacy);
        assert_eq!(legacy[2], 255);
    }

    #[test]
    fn a_negative_roi_dimension_keeps_each_vendors_message() {
        for (vendor, legacy) in [
            ("ZWO", "ZWO returned negative ROI width: -3"),
            ("Player One", "Player One returned negative ROI width: -3"),
            ("SVBony", "SVBony returned negative ROI width: -3"),
        ] {
            match roi_dimension(vendor, "width", -3) {
                Err(DriverError::SdkError(message)) => assert_eq!(message, legacy),
                other => panic!("expected an SDK error, got {:?}", other),
            }
        }
        assert_eq!(roi_dimension("ZWO", "height", 0).unwrap(), 0);
        assert_eq!(
            roi_dimension("ZWO", "height", i32::MAX).unwrap(),
            i32::MAX as u32
        );
    }

    #[test]
    fn an_oversized_image_dimension_keeps_the_atik_and_fli_message() {
        if usize::BITS > 32 {
            let too_wide = u32::MAX as usize + 1;
            match image_dimension("Atik", "width", too_wide) {
                Err(DriverError::SdkError(message)) => assert_eq!(
                    message,
                    format!("Atik image width does not fit in u32: {}", too_wide)
                ),
                other => panic!("expected an SDK error, got {:?}", other),
            }
        }
        assert_eq!(image_dimension("FLI", "height", 4096).unwrap(), 4096);
    }

    #[test]
    fn asi_bayer_index_matches_the_table_the_three_drivers_carried() {
        let legacy = |index: i32| match index {
            0 => BayerPattern::Rggb,
            1 => BayerPattern::Bggr,
            2 => BayerPattern::Grbg,
            3 => BayerPattern::Gbrg,
            _ => BayerPattern::Rggb,
        };
        for index in [-1, 0, 1, 2, 3, 4, 99] {
            assert_eq!(bayer_from_asi_index(index), legacy(index));
        }
    }

    #[test]
    fn only_a_connected_core_passes_the_guard() {
        let mut core = CameraCore::new("native:test:0".into(), "Test".into());
        assert!(matches!(
            core.require_connected(),
            Err(DriverError::NotConnected)
        ));
        core.connected = true;
        assert!(core.require_connected().is_ok());
    }

    #[test]
    fn a_frame_takes_cached_state_unless_the_driver_overrides_it() {
        let mut core = CameraCore::new("native:test:0".into(), "Test".into());
        core.gain = 120;
        core.offset = 30;
        core.bin_x = 2;
        core.bin_y = 2;
        core.exposure_duration = 12.5;
        core.subframe = Some(SubFrame {
            start_x: 8,
            start_y: 4,
            width: 16,
            height: 8,
        });
        let image = Frame {
            gain: 121,
            temperature: Some(-9.5),
            ..core.frame(2, 1, vec![7, 9], 12, Some(BayerPattern::Grbg))
        }
        .into_image();
        assert_eq!((image.width, image.height), (2, 1));
        assert_eq!(image.data, vec![7, 9]);
        assert_eq!(image.bits_per_pixel, 12);
        assert_eq!(image.bayer_pattern, Some(BayerPattern::Grbg));
        assert_eq!(image.metadata.exposure_time, 12.5);
        assert_eq!(image.metadata.gain, 121);
        assert_eq!(image.metadata.offset, 30);
        assert_eq!((image.metadata.bin_x, image.metadata.bin_y), (2, 2));
        assert_eq!(image.metadata.temperature, Some(-9.5));
        assert_eq!(image.metadata.subframe.map(|s| s.width), Some(16));
        assert_eq!(image.metadata.readout_mode, None);
    }
}

#[cfg(test)]
mod mosaic_pattern_tests {
    use super::*;

    #[test]
    fn a_decoded_xtrans_mosaic_keeps_its_cell_in_the_device_layer() {
        let letters = "GGRGGBGGBGGRBRGRBGGGBGGRGGRGGBRBGBRG";
        let cfa = skotiq_imaging::ColorFilterArray::parse(letters).unwrap();
        let pattern = mosaic_bayer_pattern(&cfa);
        assert!(matches!(pattern, BayerPattern::XTrans(_)));
        assert_eq!(pattern.fits_name(), letters);
        let bayer = skotiq_imaging::ColorFilterArray::parse("GBRG").unwrap();
        assert_eq!(mosaic_bayer_pattern(&bayer), BayerPattern::Gbrg);
    }
}
