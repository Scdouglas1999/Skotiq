//! `QhyCamera` state and the SDK reads and writes its trait methods share.

use super::*;
use crate::camera_core::{CameraCore, SdkHandle};

/// A rectangle of sensor pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Area {
    pub(crate) x: u32,
    pub(crate) y: u32,
    pub(crate) width: u32,
    pub(crate) height: u32,
}

#[derive(Debug)]
pub struct QhyCamera {
    /// The id the SDK lists the camera under (`GetQHYCCDId`), which is also
    /// its name.
    pub(crate) camera_id: String,
    pub(crate) core: CameraCore,
    pub(crate) handle: Option<QhyCamHandle>,

    /// The imaging area (`GetQHYCCDEffectiveArea`) in unbinned pixels. Frames
    /// cover it and leave out the overscan border, as INDI and NINA do by
    /// default; a subframe is placed inside it.
    pub(crate) sensor_area: Area,
    pub(crate) supported_bins: Vec<i32>,
    pub(crate) gain_range: Option<(f64, f64)>,
    pub(crate) offset_range: Option<(f64, f64)>,
    /// `CONTROL_EXPOSURE` limits in microseconds.
    pub(crate) exposure_range_us: Option<(f64, f64)>,

    /// `ExpQHYCCDSingleFrame` answered QHYCCD_READ_DIRECTLY for the exposure
    /// in progress: the frame is to be read at once and the read waits out
    /// the exposure.
    pub(crate) read_directly: bool,

    pub(crate) has_manual_pwm: bool,
    /// Full-scale `CONTROL_MANULPWM` (255 on every camera INDI and NINA met).
    pub(crate) pwm_max: f64,
    pub(crate) has_thermometer: bool,

    // The QHY SDK has no register to read the cooler switch or set-point back
    // (CONTROL_COOLER is the set-point to write, not an on/off flag), so the
    // core's cooler state only ever holds this connection's last command.
    pub(crate) keepalive: CoolerKeepalive,
}

// SAFETY: the raw `QhyCamHandle` is only passed to the SDK while its lock
// guard is held (every `unsafe` call site below and in camera_ops.rs).
unsafe impl Send for QhyCamera {}
// SAFETY: as for `Send`; shared references never call the SDK without the lock.
unsafe impl Sync for QhyCamera {}

impl QhyCamera {
    /// The SDK, held for this camera (see `sdk_loader::lock_scope`).
    pub(crate) async fn sdk(
        &self,
    ) -> Result<crate::vendor::sdk_loader::SdkGuard<QhySdk>, skotiq_device::DriverError> {
        use crate::vendor::sdk_loader::{device_key, lock_scope};
        QhySdk::slot()
            .lock_device(
                lock_scope(&skotiq_device::Vendor::Qhy),
                device_key(&self.camera_id),
            )
            .await
    }

    pub fn new(camera_id: String) -> Self {
        let mut core = CameraCore::new(format!("native:qhy:{}", camera_id), camera_id.clone());
        // Before connect: the 16-bit container connect is about to ask for,
        // ADC precision unknown.
        core.sensor_info.max_adu = container_max_adu(16, None, true);
        core.sensor_info.bit_depth = 16;
        let mut camera = Self {
            camera_id,
            core,
            handle: None,
            sensor_area: Area {
                x: 0,
                y: 0,
                width: 0,
                height: 0,
            },
            supported_bins: vec![1],
            gain_range: None,
            offset_range: None,
            exposure_range_us: None,
            read_directly: false,
            has_manual_pwm: false,
            pwm_max: 255.0,
            has_thermometer: false,
            keepalive: CoolerKeepalive::default(),
        };
        camera.publish_capabilities(false, false, false);
        camera
    }

    fn publish_capabilities(&mut self, can_cool: bool, has_shutter: bool, has_guider_port: bool) {
        let max_bin = self.supported_bins.iter().copied().max().unwrap_or(1);
        self.core.capabilities = CameraCapabilities {
            can_cool,
            can_set_gain: true,
            can_set_offset: true,
            can_set_binning: max_bin > 1,
            can_subframe: true,
            has_shutter,
            has_guider_port,
            max_bin_x: max_bin,
            max_bin_y: max_bin,
            supports_readout_modes: true,
        };
    }

    pub(crate) fn connected_handle(&self) -> Result<QhyCamHandle, DriverError> {
        self.core.require_connected()?;
        self.handle.ok_or(DriverError::NotConnected)
    }

    pub(crate) fn available(&self, sdk: &QhySdk, control: QhyControl) -> bool {
        let Some(handle) = self.handle else {
            return false;
        };
        // SAFETY: `handle` is open (it is cleared on disconnect) and the caller
        // holds the SDK lock; the control id is a plain integer.
        unsafe { (sdk.is_qhyccd_control_available)(handle, control as c_int) == QHYCCD_SUCCESS }
    }

    /// A reading, or `None` when the camera cannot give one.
    pub(crate) fn read(&self, sdk: &QhySdk, control: QhyControl) -> Option<f64> {
        let handle = self.handle?;
        // SAFETY: as in `available`.
        param_value(unsafe { (sdk.get_qhyccd_param)(handle, control as c_int) })
    }

    pub(crate) fn write(
        &self,
        sdk: &QhySdk,
        control: QhyControl,
        value: f64,
        what: &str,
    ) -> Result<(), DriverError> {
        let handle = self.handle.ok_or(DriverError::NotConnected)?;
        check_qhy_error(
            // SAFETY: as in `available`; the value is passed by value.
            unsafe { (sdk.set_qhyccd_param)(handle, control as c_int, value) },
            what,
        )
    }

    pub(crate) fn range(&self, sdk: &QhySdk, control: QhyControl) -> Option<(f64, f64)> {
        let handle = self.handle?;
        let (mut min, mut max, mut step) = (0.0, 0.0, 0.0);
        // SAFETY: as in `available`; the three out-pointers are live locals.
        let result = unsafe {
            (sdk.get_qhyccd_param_min_max_step)(
                handle,
                control as c_int,
                &mut min,
                &mut max,
                &mut step,
            )
        };
        (result == QHYCCD_SUCCESS && min.is_finite() && max.is_finite() && min <= max)
            .then_some((min, max))
    }

    /// Bring a freshly initialized camera (connect, or the re-initialization a
    /// read-mode change needs) to Skotiq's settings and read what it is.
    pub(crate) fn configure(&mut self, sdk: &QhySdk) -> Result<(), DriverError> {
        let handle = self.handle.ok_or(DriverError::NotConnected)?;
        self.check_sensor_power(sdk)?;

        let (mut chip_w, mut chip_h, mut img_w, mut img_h) = (0.0, 0.0, 0, 0);
        let (mut pixel_w, mut pixel_h, mut bpp) = (0.0, 0.0, 0);
        // SAFETY: `handle` is open and initialized; all seven out-pointers are
        // live locals of the types the SDK writes.
        let result = unsafe {
            (sdk.get_qhyccd_chip_info)(
                handle,
                &mut chip_w,
                &mut chip_h,
                &mut img_w,
                &mut img_h,
                &mut pixel_w,
                &mut pixel_h,
                &mut bpp,
            )
        };
        check_qhy_error(result, "report its sensor size")?;

        // The effective area depends on the binning, so read it at 1x1 (NINA).
        // SAFETY: as above.
        let bin_result = unsafe { (sdk.set_qhyccd_binmode)(handle, 1, 1) };
        bin_mode_result(bin_result, 1)?;
        let full = Area {
            x: 0,
            y: 0,
            width: img_w,
            height: img_h,
        };
        let (mut ex, mut ey, mut ew, mut eh) = (0, 0, 0, 0);
        // SAFETY: as above; four live out-pointers.
        let result =
            unsafe { (sdk.get_qhyccd_effective_area)(handle, &mut ex, &mut ey, &mut ew, &mut eh) };
        self.sensor_area = imaging_area(
            full,
            (result == QHYCCD_SUCCESS).then_some(Area {
                x: ex,
                y: ey,
                width: ew,
                height: eh,
            }),
        );

        // SAFETY: as above; 16 is a documented bit depth.
        let bits_result = unsafe { (sdk.set_qhyccd_bits_mode)(handle, 16) };
        // The transfer depth in force (8 or 16): the width of the samples
        // `GetQHYCCDSingleFrame` writes.
        let container_bits = if bits_result == QHYCCD_SUCCESS {
            16
        } else {
            tracing::warn!(
                "QHY camera {}: SetQHYCCDBitsMode(16) answered 0x{:X}; frames stay {}-bit",
                self.camera_id,
                bits_result,
                bpp
            );
            bpp
        };
        let actual_bits = self.probe_output_data_actual_bits(sdk);
        let high_aligned = self.probe_output_data_high_aligned(sdk);

        let can_cool = self.available(sdk, QhyControl::CONTROL_COOLER);
        self.has_manual_pwm = self.available(sdk, QhyControl::CONTROL_MANULPWM);
        self.pwm_max = self
            .range(sdk, QhyControl::CONTROL_MANULPWM)
            .map(|(_, max)| max)
            .filter(|max| *max > 0.0)
            .unwrap_or(255.0);
        self.has_thermometer = self.available(sdk, QhyControl::CONTROL_CURTEMP);
        let has_shutter =
            self.available(sdk, QhyControl::CAM_MECHANICALSHUTTER) && sdk.control_shutter.is_some();
        let has_guider_port = self.available(sdk, QhyControl::CONTROL_ST4PORT);
        self.supported_bins = [
            (1, QhyControl::CAM_BIN1X1MODE),
            (2, QhyControl::CAM_BIN2X2MODE),
            (3, QhyControl::CAM_BIN3X3MODE),
            (4, QhyControl::CAM_BIN4X4MODE),
        ]
        .into_iter()
        .filter(|(bin, control)| *bin == 1 || self.available(sdk, *control))
        .map(|(bin, _)| bin)
        .collect();
        self.gain_range = self.range(sdk, QhyControl::CONTROL_GAIN);
        self.offset_range = self.range(sdk, QhyControl::CONTROL_OFFSET);
        self.exposure_range_us = self.range(sdk, QhyControl::CONTROL_EXPOSURE);

        // IsQHYCCDControlAvailable(CAM_COLOR) answers with the BAYER_ID, as
        // INDI and NINA read it; GetQHYCCDParam(CAM_COLOR) has no handler.
        // SAFETY: as above.
        let bayer_id =
            unsafe { (sdk.is_qhyccd_control_available)(handle, QhyControl::CAM_COLOR as c_int) };
        let bayer_pattern = bayer_from_id(bayer_id);
        if bayer_pattern.is_some() {
            if let Some(set_debayer) = sdk.set_debayer {
                // The raw mosaic is what Skotiq stores and debayers itself (NINA).
                // SAFETY: as above.
                let result = unsafe { set_debayer(handle, false) };
                if result != QHYCCD_SUCCESS {
                    tracing::warn!(
                        "QHY camera {}: SetQHYCCDDebayerOnOff(false) answered 0x{:X}",
                        self.camera_id,
                        result
                    );
                }
            }
        }

        self.publish_capabilities(can_cool, has_shutter, has_guider_port);
        self.core.sensor_info = SensorInfo {
            width: self.sensor_area.width,
            height: self.sensor_area.height,
            pixel_size_x: pixel_w,
            pixel_size_y: pixel_h,
            // `max_adu` is the pixel-container full scale and `bit_depth` the
            // ADC precision, two different SDK queries; see [`container_max_adu`].
            max_adu: container_max_adu(container_bits, actual_bits, high_aligned),
            bit_depth: actual_bits.unwrap_or(bpp),
            color: bayer_pattern.is_some(),
            bayer_pattern: bayer_pattern.map(Into::into),
            saturation_adu: None,
        };

        self.core.readout_mode = self.current_read_mode_name(sdk);
        self.core.bin_x = 1;
        self.core.bin_y = 1;
        self.core.subframe = None;
        self.apply_roi(sdk, 1, None)?;
        Ok(())
    }

    /// After `InitQHYCCD` the camera holds its read mode's own gain and
    /// offset: put back the ones Skotiq set and take the camera's for the
    /// rest, so status and frame headers name the values in use.
    pub(crate) fn settle_gain_and_offset(&mut self, sdk: &QhySdk) -> Result<(), DriverError> {
        if self.core.gain_commanded {
            let gain = self.core.gain;
            self.write(
                sdk,
                QhyControl::CONTROL_GAIN,
                f64::from(gain),
                &format!("keep the gain {gain} in the new read mode"),
            )?;
        } else if let Some(gain) = self.read(sdk, QhyControl::CONTROL_GAIN) {
            self.core.gain = gain as i32;
        }
        if self.core.offset_commanded {
            let offset = self.core.offset;
            self.write(
                sdk,
                QhyControl::CONTROL_OFFSET,
                f64::from(offset),
                &format!("keep the offset {offset} in the new read mode"),
            )?;
        } else if let Some(offset) = self.read(sdk, QhyControl::CONTROL_OFFSET) {
            self.core.offset = offset as i32;
        }
        Ok(())
    }

    /// QHY's sensor power protection (UVLO): 2 and 9 mean the sensor lost
    /// its supply; frames are garbage until the camera is power-cycled (NINA).
    pub(crate) fn check_sensor_power(&self, sdk: &QhySdk) -> Result<(), DriverError> {
        if !self.available(sdk, QhyControl::CAM_Sensor_ULVO_Status) {
            return Ok(());
        }
        match self.read(sdk, QhyControl::CAM_Sensor_ULVO_Status) {
            Some(status) if status == 2.0 || status == 9.0 => Err(DriverError::SdkError(format!(
                "QHY camera {} reports that its sensor power protection tripped (UVLO status {}). \
                 Turn the camera's 12 V power off and on again, and check the power supply and cable.",
                self.camera_id, status
            ))),
            _ => Ok(()),
        }
    }

    fn current_read_mode_name(&self, sdk: &QhySdk) -> Option<String> {
        let handle = self.handle?;
        let mut mode: c_uint = 0;
        // SAFETY: as in `available`; `mode` is a live local.
        if unsafe { (sdk.get_qhyccd_read_mode)(handle, &mut mode) } != QHYCCD_SUCCESS {
            return None;
        }
        let mut name = [0 as c_char; 256];
        // SAFETY: as above; the buffer is larger than any read-mode name.
        if unsafe { (sdk.get_qhyccd_read_mode_name)(handle, mode, name.as_mut_ptr()) }
            != QHYCCD_SUCCESS
        {
            return None;
        }
        Some(
            // SAFETY: the SDK wrote a NUL-terminated name.
            unsafe { CStr::from_ptr(name.as_ptr()) }
                .to_string_lossy()
                .into_owned(),
        )
    }

    /// Put the camera's binning and readout window where `bin` and `subframe`
    /// say. Returns the window in binned sensor pixels.
    pub(crate) fn apply_roi(
        &mut self,
        sdk: &QhySdk,
        bin: i32,
        subframe: Option<&SubFrame>,
    ) -> Result<Area, DriverError> {
        let handle = self.handle.ok_or(DriverError::NotConnected)?;
        let window = readout_window(self.sensor_area, bin, subframe)?;
        if bin != self.core.bin_x {
            let bin_u = bin as c_uint;
            bin_mode_result(
                // SAFETY: as in `available`; `bin` was checked to be a supported factor.
                unsafe { (sdk.set_qhyccd_binmode)(handle, bin_u, bin_u) },
                bin,
            )?;
            self.core.bin_x = bin;
            self.core.bin_y = bin;
        }
        // SAFETY: as in `available`; the window lies inside the binned sensor.
        let result = unsafe {
            (sdk.set_qhyccd_resolution)(handle, window.x, window.y, window.width, window.height)
        };
        check_qhy_error(
            result,
            &format!(
                "accept the readout window {}x{} at ({}, {})",
                window.width, window.height, window.x, window.y
            ),
        )?;
        self.core.subframe = subframe.cloned();
        Ok(window)
    }

    pub(crate) fn check_bin(&self, bin_x: i32, bin_y: i32) -> Result<i32, DriverError> {
        if bin_x != bin_y || !self.supported_bins.contains(&bin_x) {
            return Err(DriverError::InvalidParameter(format!(
                "QHY camera {} bins {}; {}x{} was asked",
                self.camera_id,
                self.supported_bins
                    .iter()
                    .map(|b| format!("{b}x{b}"))
                    .collect::<Vec<_>>()
                    .join(", "),
                bin_x,
                bin_y
            )));
        }
        Ok(bin_x)
    }

    /// The sensor temperature, when the camera has a thermometer and its
    /// reading is a temperature (INDI treats anything above 100 C as a fault).
    pub(crate) fn temperature(&self, sdk: &QhySdk) -> Option<f64> {
        if !self.has_thermometer {
            return None;
        }
        self.read(sdk, QhyControl::CONTROL_CURTEMP)
            .filter(|t| (-100.0..=100.0).contains(t))
    }

    pub(crate) fn cooler_power(&self, sdk: &QhySdk) -> Option<f64> {
        if !self.core.capabilities.can_cool {
            return None;
        }
        self.read(sdk, QhyControl::CONTROL_CURPWM)
            .and_then(|raw| cooler_percent(raw, self.pwm_max))
    }

    /// Read the ADC precision behind the delivered container, or `None` when
    /// this camera cannot report it.
    ///
    /// `OutputDataActualBits` is documented in the QHYCCD SDK API manual §21 as
    /// "the actual number of bits of raw data output by the chip" — the ADC
    /// precision, which `GetQHYCCDChipInfo`'s `bpp` (the container) is not.
    pub(crate) fn probe_output_data_actual_bits(&self, sdk: &QhySdk) -> Option<u32> {
        if !self.available(sdk, QhyControl::OutputDataActualBits) {
            return None;
        }
        let raw = self.read(sdk, QhyControl::OutputDataActualBits)?;
        if !(1.0..=16.0).contains(&raw) {
            tracing::debug!(
                "QHY camera {}: OutputDataActualBits returned {}, outside 1..=16; \
                 falling back to the container ceiling",
                self.camera_id,
                raw
            );
            return None;
        }
        Some(raw as u32)
    }

    /// Whether the ADC bits sit at the top of the container.
    ///
    /// QHYCCD SDK API manual §22: "If the return value is 1, it indicates high
    /// alignment; if the return value is 0, it indicates low alignment." The
    /// parameter is optional; when it is unavailable we use the behaviour
    /// §14/§21 document for every camera: 16-bit output is produced by "low
    /// zero padding" of the raw data, i.e. high alignment.
    pub(crate) fn probe_output_data_high_aligned(&self, sdk: &QhySdk) -> bool {
        if !self.available(sdk, QhyControl::OutputDataAlignment) {
            return true;
        }
        if self.read(sdk, QhyControl::OutputDataAlignment) == Some(0.0) {
            tracing::info!(
                "QHY camera {}: OutputDataAlignment reports low alignment; \
                 publishing the ADC range as the container ceiling",
                self.camera_id
            );
            return false;
        }
        true
    }

    /// The temperature the camera is told to hold while its cooler is on.
    pub(crate) fn start_cooling(&mut self, sdk: &QhySdk, target_c: f64) -> Result<(), DriverError> {
        let handle = self.connected_handle()?;
        self.write(
            sdk,
            QhyControl::CONTROL_COOLER,
            target_c,
            &format!("take the cooler set-point {target_c} C"),
        )?;
        self.keepalive
            .start(self.camera_id.clone(), SdkHandle(handle), target_c);
        Ok(())
    }
}

/// Sends the cooler set-point once a second while the cooler is on.
///
/// QHY's advice, quoted by NINA, is to treat every camera as running the old
/// firmware that stops regulating unless the set-point keeps arriving; the SDK
/// header says the same of ControlQHYCCDTemp ("call this api every single
/// second"), and INDI resends CONTROL_COOLER every poll while regulating.
#[derive(Debug, Default)]
pub(crate) struct CoolerKeepalive(Option<tokio::task::JoinHandle<()>>);

pub(crate) const COOLER_RESEND_INTERVAL: Duration = Duration::from_secs(1);

impl CoolerKeepalive {
    fn start(&mut self, camera_id: String, handle: SdkHandle<QhyCamHandle>, target_c: f64) {
        self.stop();
        self.0 = Some(tokio::spawn(async move {
            let handle = handle;
            loop {
                tokio::time::sleep(COOLER_RESEND_INTERVAL).await;
                // Held for this camera only, like the camera's own calls: a
                // resend waiting for the whole SDK would queue behind another
                // camera's frame read and hold every later call up with it.
                let Ok(sdk) = QhySdk::slot()
                    .lock_device(
                        crate::vendor::sdk_loader::lock_scope(&skotiq_device::Vendor::Qhy),
                        crate::vendor::sdk_loader::device_key(&camera_id),
                    )
                    .await
                else {
                    return;
                };
                // The camera's session ended (disconnect, unplug): stop.
                if session::current(&camera_id) != Some(handle.0) {
                    return;
                }
                // SAFETY: the session still holds this handle and the SDK
                // lock is held for the call.
                let result = unsafe {
                    (sdk.set_qhyccd_param)(handle.0, QhyControl::CONTROL_COOLER as c_int, target_c)
                };
                if result != QHYCCD_SUCCESS {
                    tracing::debug!(
                        "QHY camera {camera_id}: resending the cooler set-point answered 0x{result:X}"
                    );
                }
            }
        }));
    }

    pub(crate) fn stop(&mut self) {
        if let Some(task) = self.0.take() {
            task.abort();
        }
    }
}

impl Drop for CoolerKeepalive {
    fn drop(&mut self) {
        self.stop();
    }
}

/// The BAYER_ID enum of `qhyccdstruct.h` (1 GB, 2 GR, 3 BG, 4 RG), named the
/// way INDI and NINA name it; anything else is a mono sensor.
pub(crate) fn bayer_from_id(id: c_uint) -> Option<BayerPattern> {
    match id {
        1 => Some(BayerPattern::Gbrg),
        2 => Some(BayerPattern::Grbg),
        3 => Some(BayerPattern::Bggr),
        4 => Some(BayerPattern::Rggb),
        _ => None,
    }
}

/// The 2x2 pattern seen from a pixel `dx` columns and `dy` rows further on.
pub(crate) fn shifted_bayer(pattern: BayerPattern, dx: u32, dy: u32) -> BayerPattern {
    pattern.shifted(i64::from(dx), i64::from(dy))
}

/// The color filter of a frame read at `bin` from a window starting `dx`, `dy`
/// pixels into the imaging area. A binned color frame sums each 2x2 cell into
/// one pixel, so it is no mosaic (NINA marks only 1x1 color frames Bayered).
pub(crate) fn frame_bayer(
    pattern: Option<BayerPattern>,
    bin: i32,
    subframe: Option<&SubFrame>,
) -> Option<BayerPattern> {
    let pattern = pattern?;
    if bin != 1 {
        return None;
    }
    let (dx, dy) = subframe.map_or((0, 0), |s| (s.start_x, s.start_y));
    Some(shifted_bayer(pattern, dx, dy))
}

/// The imaging area: the effective area the SDK reports, or the whole chip
/// when it reports none or one that does not fit the chip.
pub(crate) fn imaging_area(chip: Area, effective: Option<Area>) -> Area {
    effective
        .filter(|e| {
            e.width > 0
                && e.height > 0
                && e.x.checked_add(e.width).is_some_and(|r| r <= chip.width)
                && e.y.checked_add(e.height).is_some_and(|b| b <= chip.height)
        })
        .unwrap_or(chip)
}

/// The window `SetQHYCCDResolution` takes, in binned sensor pixels: the
/// imaging area, or the subframe placed in it. A subframe is in binned pixels
/// counted from the imaging area's corner, like every Skotiq camera's.
pub(crate) fn readout_window(
    area: Area,
    bin: i32,
    subframe: Option<&SubFrame>,
) -> Result<Area, DriverError> {
    let bin = u32::try_from(bin).ok().filter(|b| *b >= 1).ok_or_else(|| {
        DriverError::InvalidParameter(format!("QHY binning {bin} is not a factor"))
    })?;
    let full = Area {
        x: area.x / bin,
        y: area.y / bin,
        width: area.width / bin,
        height: area.height / bin,
    };
    let Some(sub) = subframe else {
        return Ok(full);
    };
    let fits = sub.width > 0
        && sub.height > 0
        && sub
            .start_x
            .checked_add(sub.width)
            .is_some_and(|r| r <= full.width)
        && sub
            .start_y
            .checked_add(sub.height)
            .is_some_and(|b| b <= full.height);
    if !fits {
        return Err(DriverError::InvalidParameter(format!(
            "The subframe {}x{} at ({}, {}) does not fit the {}x{} sensor at {}x{} binning",
            sub.width, sub.height, sub.start_x, sub.start_y, full.width, full.height, bin, bin
        )));
    }
    Ok(Area {
        x: full.x + sub.start_x,
        y: full.y + sub.start_y,
        width: sub.width,
        height: sub.height,
    })
}

/// `SetQHYCCDBinMode`'s answer: some cameras answer QHYCCD_DELAY_200MS and
/// need that long before the next command (NINA waits it out).
pub(crate) fn bin_mode_result(code: c_uint, bin: i32) -> Result<(), DriverError> {
    if code == QHYCCD_DELAY_200MS {
        std::thread::sleep(Duration::from_millis(200));
        return Ok(());
    }
    check_qhy_error(code, &format!("switch to {bin}x{bin} binning"))
}

/// `CONTROL_CURPWM` (0..=pwm_max) as a percentage, as INDI and NINA report it.
pub(crate) fn cooler_percent(raw: f64, pwm_max: f64) -> Option<f64> {
    (raw >= 0.0 && raw <= pwm_max && pwm_max > 0.0).then(|| raw / pwm_max * 100.0)
}

/// `value` against a range the camera reported; no range means no check.
pub(crate) fn check_range(
    value: f64,
    range: Option<(f64, f64)>,
    what: &str,
    shown: impl Fn(f64) -> String,
) -> Result<(), DriverError> {
    match range {
        Some((min, max)) if value < min - 1e-9 * min.abs() || value > max + 1e-9 * max.abs() => {
            Err(DriverError::InvalidParameter(format!(
                "The camera's {what} goes from {} to {}; {} was asked",
                shown(min),
                shown(max),
                shown(value)
            )))
        }
        _ => Ok(()),
    }
}
