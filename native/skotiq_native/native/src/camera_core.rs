//! What every vendor camera driver keeps and does the same way.
//!
//! [`CameraCore`] is the state each driver embeds (identity, connection,
//! gain/offset and who chose them, binning/subframe, what is known of the
//! cooler, the exposure clock, capabilities and sensor description), with the
//! one connected check. [`Frame`] is the one
//! place a downloaded frame becomes [`ImageData`]; the free functions are the
//! pixel unpacking and SDK-value conversions the drivers share.
//!
//! Rules that differ between vendors are inputs here, never decided here: each
//! driver names its byte order, its 8-bit rule and the metadata values that
//! do not come from the cached state. A DSLR or mirrorless body fits with ISO
//! as its gain, offset 0, bin 1 and no cooler.

use skotiq_cfa::{BayerPattern, ColorFilterArray};
use skotiq_device::camera::{
    CameraCapabilities, CameraState, ImageData, ImageMetadata, SensorInfo, SubFrame, VendorFeatures,
};
use skotiq_device::{CameraFile, DriverError, ExposureAbort};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

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

/// An abort asked for while a frame read is in flight. The read checks it
/// between SDK calls; the next exposure clears it.
#[derive(Debug, Default)]
pub(crate) struct AbortRequest(AtomicBool);

impl ExposureAbort for AbortRequest {
    fn request(&self) {
        self.0.store(true, Ordering::Release);
    }
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
    /// Gain and offset in force. Each is the camera's own value (read at
    /// connect, or again after the camera changed it with its read mode) until
    /// this connection commands one; `gain_commanded` / `offset_commanded`
    /// say which. On a DSLR the gain is the ISO.
    pub(crate) gain: i32,
    pub(crate) offset: i32,
    pub(crate) gain_commanded: bool,
    pub(crate) offset_commanded: bool,
    pub(crate) bin_x: i32,
    pub(crate) bin_y: i32,
    pub(crate) subframe: Option<SubFrame>,
    /// The camera's name for the read mode it is in; `None` for a camera
    /// without read modes, or before the driver has read it on connect. The
    /// driver sets it when it reads the mode and when it changes it.
    pub(crate) readout_mode: Option<String>,
    /// Behind a lock because some drivers refresh it from a status read,
    /// which only has `&self`.
    cooler: std::sync::Mutex<CoolerState>,
    pub(crate) exposure_started_at: Option<std::time::Instant>,
    /// Seconds requested for the exposure in progress or last taken.
    pub(crate) exposure_duration: f64,
    abort: Arc<AbortRequest>,
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
            gain_commanded: false,
            offset_commanded: false,
            bin_x: 1,
            bin_y: 1,
            subframe: None,
            readout_mode: None,
            cooler: std::sync::Mutex::new(CoolerState::UNKNOWN),
            exposure_started_at: None,
            exposure_duration: 0.0,
            abort: Arc::default(),
        }
    }

    /// For [`skotiq_device::CameraDriver::exposure_abort`], in a driver
    /// whose frame read checks [`Self::abort_requested`].
    pub(crate) fn abort_handle(&self) -> Arc<dyn ExposureAbort> {
        self.abort.clone()
    }

    /// Whether the frame read in flight was asked to give up.
    pub(crate) fn abort_requested(&self) -> bool {
        self.abort.0.load(Ordering::Acquire)
    }

    /// A new exposure starts with no abort pending.
    pub(crate) fn clear_abort(&self) {
        self.abort.0.store(false, Ordering::Release);
    }

    /// What a frame read that was given up answers.
    pub(crate) fn read_given_up(&self) -> DriverError {
        DriverError::Unknown(format!(
            "the frame read of {} was given up because the exposure was aborted",
            self.name
        ))
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

    /// The camera accepted a gain this connection asked for.
    pub(crate) fn command_gain(&mut self, gain: i32) {
        self.gain = gain;
        self.gain_commanded = true;
    }

    /// The camera accepted an offset this connection asked for.
    pub(crate) fn command_offset(&mut self, offset: i32) {
        self.offset = offset;
        self.offset_commanded = true;
    }

    /// A new connection: nothing commanded yet, the cooler and read mode
    /// unknown, no exposure in progress. The driver then reads the camera's
    /// own values.
    pub(crate) fn begin_connection(&mut self) {
        self.gain = 0;
        self.offset = 0;
        self.gain_commanded = false;
        self.offset_commanded = false;
        self.readout_mode = None;
        self.update_cooler(|cooler| *cooler = CoolerState::UNKNOWN);
        self.end_exposure();
    }

    /// The camera started an exposure of `seconds`.
    pub(crate) fn begin_exposure(&mut self, seconds: f64) {
        self.exposure_duration = seconds;
        self.exposure_started_at = Some(std::time::Instant::now());
        self.state = CameraState::Exposing;
    }

    /// The exposure was read, aborted or lost. Its duration stays as the
    /// last one taken.
    pub(crate) fn end_exposure(&mut self) {
        self.exposure_started_at = None;
        self.state = CameraState::Idle;
    }

    /// Seconds left on the exposure clock, 0 once its time is up; `None`
    /// when no exposure was started or the last one has ended.
    pub(crate) fn exposure_remaining(&self) -> Option<f64> {
        self.exposure_started_at
            .map(|started| (self.exposure_duration - started.elapsed().as_secs_f64()).max(0.0))
    }

    /// A frame described by the cached state: exposure time, gain, offset,
    /// binning, subframe and read mode as last set, no temperature, no vendor
    /// data. A driver overrides the fields its SDK reports for the frame
    /// itself.
    pub(crate) fn frame(
        &self,
        width: u32,
        height: u32,
        data: Vec<u16>,
        bits_per_pixel: u32,
        bayer_pattern: Option<ColorFilterArray>,
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
            readout_mode: self.readout_mode.clone(),
            vendor_data: VendorFeatures::default(),
            camera_file: None,
        }
    }
}

/// Everything a driver knows about one downloaded frame.
pub(crate) struct Frame {
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) data: Vec<u16>,
    pub(crate) bits_per_pixel: u32,
    pub(crate) bayer_pattern: Option<ColorFilterArray>,
    pub(crate) exposure_time: f64,
    pub(crate) gain: i32,
    pub(crate) offset: i32,
    pub(crate) bin_x: i32,
    pub(crate) bin_y: i32,
    pub(crate) temperature: Option<f64>,
    pub(crate) subframe: Option<SubFrame>,
    pub(crate) readout_mode: Option<String>,
    pub(crate) vendor_data: VendorFeatures,
    /// The raw file a DSLR or mirrorless body wrote for the frame.
    pub(crate) camera_file: Option<CameraFile>,
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
                camera_file: self.camera_file,
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

/// Full-scale ADU of a 16-bit pixel container holding samples of a
/// `bit_depth`-bit ADC, as the ASI-style SDKs (ZWO, Player One, SVBony)
/// deliver them in their 16-bit raw format.
///
/// These SDKs left-justify sub-16-bit samples into the 16-bit buffer, so a
/// 12-bit ADC produces values that are multiples of 16 spanning `0 ..= 4095 <<
/// 4` (65520), NOT `0 ..= 4095`. Measured on a live ASI1600MM-Cool: a
/// nowhere-near-saturated 2 ms frame read min 3856, max 5792, median 4464
/// (every one a multiple of 16), and a saturated frame clipped at 65504
/// (`4094 << 4`); an SV305 shows the same signature. Reporting
/// `(1 << bit_depth) - 1` makes the camera status claim `maxAdu: 4095` for a
/// camera whose frames reach 65504, a 16x error that puts every
/// percent-of-full-scale consumer (flat-frame targets above all) out of reach.
///
/// `bit_depth >= 16` needs no shift. `bit_depth == 0` means the SDK never
/// populated the property; the container's own ceiling is the answer then,
/// not 0, which would say "this camera cannot produce any signal".
pub(crate) fn raw16_container_max_adu(bit_depth: u32) -> u32 {
    const CONTAINER_BITS: u32 = 16;
    const CONTAINER_MAX: u32 = u16::MAX as u32;
    if bit_depth == 0 || bit_depth >= CONTAINER_BITS {
        return CONTAINER_MAX;
    }
    (((1u32 << bit_depth) - 1) << (CONTAINER_BITS - bit_depth)) & CONTAINER_MAX
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

    // Pixel-container full scale.

    #[test]
    fn raw16_container_max_adu_accounts_for_left_justification() {
        // 12-bit ASI1600MM/ASI183/ASI294, SV305: 4095 << 4.
        assert_eq!(raw16_container_max_adu(12), 65520);
        // 14-bit ASI2600/ASI6200: 16383 << 2.
        assert_eq!(raw16_container_max_adu(14), 65532);
        // 10-bit: 1023 << 6.
        assert_eq!(raw16_container_max_adu(10), 65472);
        // 8-bit sensor read out in Raw16: 255 << 8.
        assert_eq!(raw16_container_max_adu(8), 65280);
        // A true 16-bit sensor (IMX455/IMX571 class) needs no shift.
        assert_eq!(raw16_container_max_adu(16), 65535);
    }

    /// Every ceiling is a value a `u16` sample can hold and lies on the
    /// sample grid of a left-justified ADC.
    #[test]
    fn raw16_container_max_adu_is_a_reachable_u16_sample() {
        for bit_depth in 1..=16u32 {
            let max = raw16_container_max_adu(bit_depth);
            assert!(
                max <= u16::MAX as u32,
                "bit_depth {bit_depth} produced {max}, outside the u16 container"
            );
            let step = 1u32 << (16 - bit_depth.min(16));
            assert_eq!(
                max % step,
                0,
                "bit_depth {bit_depth}: {max} is not a multiple of the {step}-ADU sample step"
            );
        }
    }

    #[test]
    fn raw16_container_max_adu_unknown_bit_depth_falls_back_to_container() {
        assert_eq!(raw16_container_max_adu(0), 65535);
        assert_eq!(raw16_container_max_adu(32), 65535);
        assert_eq!(raw16_container_max_adu(u32::MAX), 65535);
    }

    /// The imaging pipeline's saturation threshold (65024 = 4064 << 4) sits
    /// just under the 12-bit ceiling, so saturation on the most common astro
    /// sensor class is detected; the live ASI1600MM clip at 65504 is flagged.
    #[test]
    fn raw16_container_max_adu_agrees_with_pipeline_saturation_threshold() {
        let twelve_bit_ceiling = raw16_container_max_adu(12);
        assert!(65024 < twelve_bit_ceiling);
        assert!(65024 <= 65504 && 65504 <= twelve_bit_ceiling);
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
    fn the_exposure_clock_runs_from_begin_to_end() {
        let mut core = CameraCore::new("native:test:0".into(), "Test".into());
        assert_eq!(core.exposure_remaining(), None);
        core.begin_exposure(30.0);
        assert_eq!(core.state, CameraState::Exposing);
        let left = core.exposure_remaining().expect("an exposure is running");
        assert!(left > 29.0 && left <= 30.0, "{left}");
        core.begin_exposure(0.0);
        assert_eq!(core.exposure_remaining(), Some(0.0));
        core.end_exposure();
        assert_eq!(core.state, CameraState::Idle);
        assert_eq!(core.exposure_remaining(), None);
        assert_eq!(core.exposure_duration, 0.0);
    }

    #[test]
    fn a_new_connection_forgets_what_the_last_one_commanded() {
        let mut core = CameraCore::new("native:test:0".into(), "Test".into());
        core.command_gain(120);
        core.command_offset(30);
        core.update_cooler(|cooler| {
            cooler.enabled = Some(true);
            cooler.target_c = Some(-10.0);
        });
        core.begin_exposure(5.0);
        assert!(core.gain_commanded && core.offset_commanded);
        assert_eq!((core.gain, core.offset), (120, 30));

        core.readout_mode = Some("High Gain Mode".into());
        core.begin_connection();
        assert!(!core.gain_commanded && !core.offset_commanded);
        assert_eq!(core.readout_mode, None);
        assert_eq!((core.gain, core.offset), (0, 0));
        assert_eq!(core.cooler(), CoolerState::UNKNOWN);
        assert_eq!(core.exposure_remaining(), None);
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
        core.readout_mode = Some("High Gain Mode".into());
        let image = Frame {
            gain: 121,
            temperature: Some(-9.5),
            ..core.frame(2, 1, vec![7, 9], 12, Some(BayerPattern::Grbg.into()))
        }
        .into_image();
        assert_eq!((image.width, image.height), (2, 1));
        assert_eq!(image.data, vec![7, 9]);
        assert_eq!(image.bits_per_pixel, 12);
        assert_eq!(image.bayer_pattern, Some(BayerPattern::Grbg.into()));
        assert_eq!(image.metadata.exposure_time, 12.5);
        assert_eq!(image.metadata.gain, 121);
        assert_eq!(image.metadata.offset, 30);
        assert_eq!((image.metadata.bin_x, image.metadata.bin_y), (2, 2));
        assert_eq!(image.metadata.temperature, Some(-9.5));
        assert_eq!(image.metadata.subframe.map(|s| s.width), Some(16));
        assert_eq!(
            image.metadata.readout_mode.as_deref(),
            Some("High Gain Mode")
        );
    }
}

#[cfg(test)]
mod mosaic_pattern_tests {
    use super::*;

    #[test]
    fn a_decoded_mosaic_keeps_its_cell_through_the_camera_frame() {
        let core = CameraCore::new("test".to_string(), "Mosaic camera".to_string());
        for letters in ["GBRG", "GGRGGBGGBGGRBRGRBGGGBGGRGGRGGBRBGBRG"] {
            let cfa = ColorFilterArray::parse(letters).unwrap();
            let frame = core.frame(6, 6, vec![123; 36], 14, Some(cfa)).into_image();
            assert_eq!(frame.bayer_pattern, Some(cfa));
            assert_eq!(frame.bayer_pattern.unwrap().letters(), letters);
        }
    }
}
