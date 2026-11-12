//! `FliCamera` state and inherent helpers.

use super::*;

pub struct FliCamera {
    /// The address from the device id (see `open_device`).
    pub(crate) device_path: String,
    pub(crate) core: CameraCore,
    pub(crate) handle: FliDev,
    pub(crate) serial: Option<String>,
    pub(crate) visible: VisibleArea,
    /// The rectangle last given to FLISetImageArea; a download reads this.
    pub(crate) image_area: ImageArea,
}

impl std::fmt::Debug for FliCamera {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FliCamera")
            .field("device_id", &self.core.device_id)
            .field("name", &self.core.name)
            .field("device_path", &self.device_path)
            .finish()
    }
}

impl FliCamera {
    pub fn new(device_path: String) -> Self {
        let device_id = device_path.replace("/", "_").replace("\\", "_");
        Self {
            device_path: device_path.clone(),
            core: CameraCore::new(
                format!("fli_{}", device_id),
                "FLI Camera".to_string(),
                -10.0,
            ),
            handle: FLI_INVALID_DEVICE,
            serial: None,
            visible: VisibleArea::default(),
            image_area: ImageArea::default(),
        }
    }

    /// The camera's geometry and modes, read once the handle is open. Any
    /// error leaves the handle for the caller to close.
    fn configure(&mut self, sdk: &FliSdk) -> Result<(), DriverError> {
        if let Some(model) = read_model(sdk, self.handle) {
            self.core.name = model;
        }
        self.serial = read_serial(sdk, self.handle);

        let mut pixel_x: c_double = 0.0;
        let mut pixel_y: c_double = 0.0;
        // SAFETY: self.handle is open; both out-pointers are valid stack pointers.
        let result = unsafe { (sdk.get_pixel_size)(self.handle, &mut pixel_x, &mut pixel_y) };
        check_fli_error(result, "get pixel size")?;
        // A zero pitch zeroes the plate scale everywhere downstream.
        let pixel_x = pixel_size_microns(pixel_x)?;
        let pixel_y = pixel_size_microns(pixel_y)?;

        let mut ul_x: c_long = 0;
        let mut ul_y: c_long = 0;
        let mut lr_x: c_long = 0;
        let mut lr_y: c_long = 0;
        // SAFETY: self.handle is open; all four out-pointers are valid stack pointers.
        let result = unsafe {
            (sdk.get_visible_area)(self.handle, &mut ul_x, &mut ul_y, &mut lr_x, &mut lr_y)
        };
        check_fli_error(result, "get visible area")?;
        self.visible = VisibleArea::from_corners(ul_x, ul_y, lr_x, lr_y)?;

        // Select 16-bit mode before publishing the sensor's bit depth. If this write
        // fails the camera stays in 8-bit while the app advertises a 65535 full scale,
        // so every subsequent frame would be scaled, stretched and written to FITS
        // against a ceiling 256x too large. A device that reached us and refused is
        // therefore fatal to the connect.
        //
        // A device with no bit-depth control at all is the other case, and it is not
        // that one: libfli answers a command a model does not implement with a
        // not-supported errno, and an FLI body with no selectable depth is 16-bit —
        // the mode being asked for. Refusing those made 16-bit-only bodies impossible
        // to connect, where they had imaged for years. Every USB body is one
        // (libfli-camera-usb.c answers -EINVAL for MaxCam, IMG and ProLine alike).
        // SAFETY: self.handle is open; FLI_MODE_16BIT is a pass-by-value constant.
        let result = unsafe { (sdk.set_bit_depth)(self.handle, FLI_MODE_16BIT) };
        match fli_capability_answer(result) {
            FliCapabilityAnswer::Done => {}
            FliCapabilityAnswer::NotSupported(code) => {
                tracing::debug!(
                    "FLI camera '{}' has no selectable bit depth (FLISetBitDepth returned {}); it reads out 16-bit, the mode being selected",
                    self.core.name,
                    code
                );
            }
            FliCapabilityAnswer::Failed(code) => check_fli_error(code, "set 16-bit mode")?,
        }

        // libfli has no cooler-presence flag, so the temperature channel is the only
        // evidence available. It is one-directional: a body that cannot report a CCD
        // temperature has no regulation to offer, but a body that can may still be
        // uncooled, because libfli answers FLIGetTemperature on those too.
        let mut probe_temp: c_double = 0.0;
        // SAFETY: self.handle is open; `&mut probe_temp` is a valid stack out-pointer.
        let temp_result = unsafe { (sdk.get_temperature)(self.handle, &mut probe_temp) };
        let can_cool = temp_result == 0;
        if !can_cool {
            tracing::warn!(
                "FLI camera '{}' did not report a CCD temperature ({}); reporting no cooling",
                self.core.name,
                fli_error_text(temp_result)
            );
        }

        // `bit_depth`/`max_adu` describe the 16-bit mode confirmed above. libfli
        // reports no colour-filter-array information and delivers frames with no
        // Bayer metadata, so frames are published as mono; a one-shot-colour FLI
        // body is therefore not debayered.
        self.core.sensor_info = SensorInfo {
            width: self.visible.width,
            height: self.visible.height,
            pixel_size_x: pixel_x,
            pixel_size_y: pixel_y,
            max_adu: 65535,
            bit_depth: 16,
            color: false,
            bayer_pattern: None,
        };

        // libfli publishes no per-model capability table, so only the API's own
        // documented limits and the probe above are asserted here: binning 1..=16
        // (libfli.c FLISetHBin/FLISetVBin), and gain and offset have no SDK
        // control at all.
        self.core.capabilities = CameraCapabilities {
            can_cool,
            can_set_gain: false,
            can_set_offset: false,
            can_set_binning: true,
            can_subframe: true,
            has_shutter: true,
            has_guider_port: false,
            max_bin_x: FLI_MAX_BIN,
            max_bin_y: FLI_MAX_BIN,
            supports_readout_modes: false,
        };

        self.core.bin_x = 1;
        self.core.bin_y = 1;
        self.core.subframe = None;
        self.write_binning(sdk, 1, 1)?;
        self.write_image_area(sdk, image_area(self.visible, None, 1, 1)?)
    }

    pub(crate) fn write_binning(
        &self,
        sdk: &FliSdk,
        bin_x: i32,
        bin_y: i32,
    ) -> Result<(), DriverError> {
        // SAFETY: self.handle is open; the bins were checked to 1..=16 by image_area.
        let result = unsafe { (sdk.set_hbin)(self.handle, bin_x as c_long) };
        check_fli_error(result, "set horizontal binning")?;
        // SAFETY: as above.
        let result = unsafe { (sdk.set_vbin)(self.handle, bin_y as c_long) };
        check_fli_error(result, "set vertical binning")
    }

    pub(crate) fn write_image_area(
        &mut self,
        sdk: &FliSdk,
        area: ImageArea,
    ) -> Result<(), DriverError> {
        // SAFETY: self.handle is open; the corners come from image_area, inside the visible area.
        let result = unsafe {
            (sdk.set_image_area)(self.handle, area.ul_x, area.ul_y, area.lr_x, area.lr_y)
        };
        check_fli_error(result, "set image area")?;
        self.image_area = area;
        Ok(())
    }
}

#[async_trait]
impl DeviceDriver for FliCamera {
    fn id(&self) -> &str {
        &self.core.device_id
    }

    fn name(&self) -> &str {
        &self.core.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Fli
    }

    fn serial_number(&self) -> Option<String> {
        self.serial.clone()
    }

    fn is_connected(&self) -> bool {
        self.core.connected
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.core.connected {
            return Ok(());
        }

        let sdk = FliSdk::lock().await?;
        let (handle, filename) = open_device(&sdk, &self.device_path, FliDeviceType::Camera)?;
        self.handle = handle;
        if let Err(error) = self.configure(&sdk) {
            close_fli_handle(&sdk, &mut self.handle);
            return Err(error);
        }

        self.core.connected = true;
        self.core.state = CameraState::Idle;

        tracing::info!(
            "Connected to FLI camera {} at '{}' ({}x{}, {} x {} um pixels, serial {:?})",
            self.core.name,
            filename,
            self.core.sensor_info.width,
            self.core.sensor_info.height,
            self.core.sensor_info.pixel_size_x,
            self.core.sensor_info.pixel_size_y,
            self.serial
        );

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.core.connected {
            return Ok(());
        }

        let sdk = FliSdk::lock().await?;

        // SAFETY: self.handle is valid because the camera is connected (only set after successful connect()).
        let _ = unsafe { (sdk.cancel_exposure)(self.handle) };

        // SAFETY: self.handle was successfully opened during connect(). FLIClose pairs with FLIOpen.
        let result = unsafe { (sdk.close)(self.handle) };
        check_fli_error(result, "close camera")?;

        self.handle = FLI_INVALID_DEVICE;
        self.core.connected = false;
        self.core.state = CameraState::Idle;

        tracing::info!("Disconnected from FLI camera: {}", self.core.name);

        Ok(())
    }
}
