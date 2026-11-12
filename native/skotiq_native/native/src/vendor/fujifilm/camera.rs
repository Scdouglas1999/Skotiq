//! `FujifilmCamera` state and inherent helpers.

use super::*;

#[derive(Debug)]
pub struct FujifilmCamera {
    pub(crate) id: String,
    pub(crate) name: String,
    /// What the open session is joined by: the serial number, or the product
    /// name of a body that lists none.
    pub(crate) address: String,
    /// `XSDK_Detect`'s serial number for the body, when it lists one.
    pub(crate) serial_number: Option<String>,
    pub(crate) model: FujifilmModel,

    /// The open SDK session on the body, shared with its lens focuser;
    /// `None` while disconnected.
    pub(crate) session: Option<Arc<Session>>,

    pub(crate) firmware_version: String,
    pub(crate) sensor_info: SensorInfo,

    // RAW sample-depth provenance. `refresh_raw_depth` folds these into
    // `sensor_info.bit_depth` / `sensor_info.max_adu`, preferring
    // measured-from-frame over SDK-reported over the model table.
    /// Bit depth the camera reports for itself: `XSDK_GetProp` with
    /// `API_CODE_GetRAWOutputDepth` (XAPIOpt.H:229) at connect, then
    /// `XSDK_ImageInformation::lImageBitDepth` (XAPI.H:123) for every RAW frame
    /// `XSDK_ReadImageInfo` describes.
    pub(crate) sdk_reported_bit_depth: Option<u32>,
    /// True bit depth of the last decoded RAF: `RawFrame::bits_per_pixel`.
    pub(crate) measured_bit_depth: Option<u32>,
    /// Container full scale of the last decoded RAF: `RawFrame::white_level`,
    /// i.e. LibRaw's `color.maximum` saturation level.
    pub(crate) measured_white_level: Option<u32>,

    pub(crate) is_exposing: bool,
    pub(crate) is_bulb_mode: bool,
    pub(crate) exposure_start: Option<Instant>,
    pub(crate) exposure_duration: Duration,

    /// Shared with the task that stops live view once nobody watches it.
    pub(crate) live_view: Arc<Mutex<LiveViewDemand>>,

    pub(crate) current_iso: i32,
    pub(crate) current_offset: i32,
    /// The fixed ISO values the body reported, lowest first.
    pub(crate) supported_isos: Vec<i32>,
    /// Whether long exposure noise reduction is still on after connect tried
    /// to switch it off: the body then shoots a dark after every frame.
    pub(crate) long_exposure_nr: bool,
}

impl FujifilmCamera {
    pub fn new(device_info: &FujifilmDeviceInfo) -> Self {
        let address = device_info
            .serial_number
            .clone()
            .unwrap_or_else(|| device_info.name.clone());
        let (width, height, pixel_size, bit_depth) = device_info.model.sensor_specs();

        Self {
            id: format!("native:fujifilm:{}", address),
            name: device_info.name.clone(),
            address,
            serial_number: device_info.serial_number.clone(),
            model: device_info.model,
            session: None,
            firmware_version: String::new(),
            sensor_info: SensorInfo {
                width,
                height,
                pixel_size_x: pixel_size,
                pixel_size_y: pixel_size,
                // Pre-first-frame estimate. Superseded by the camera-reported
                // depth at connect and by the decoded frame's measured white
                // level thereafter — see `refresh_raw_depth`.
                max_adu: resolve_max_adu(None, bit_depth),
                bit_depth,
                color: true,
                bayer_pattern: if device_info.model.is_xtrans() {
                    None // X-Trans is not Bayer
                } else {
                    Some(BayerPattern::Rggb) // GFX uses standard Bayer
                },
                saturation_adu: None,
            },
            sdk_reported_bit_depth: None,
            measured_bit_depth: None,
            measured_white_level: None,
            is_exposing: false,
            is_bulb_mode: false,
            exposure_start: None,
            exposure_duration: Duration::ZERO,
            live_view: Arc::default(),
            current_iso: 800,
            current_offset: 0,
            supported_isos: Vec::new(),
            long_exposure_nr: false,
        }
    }

    /// The body's SDK handle; null while disconnected.
    pub(crate) fn handle(&self) -> XsdkHandle {
        self.session
            .as_ref()
            .map_or(std::ptr::null_mut(), |s| s.handle())
    }

    /// Recompute the published sample depth from the best evidence available.
    ///
    /// Authority order, highest first:
    ///
    /// 1. **Measured from the frame** — `RawFrame::bits_per_pixel` and
    ///    `RawFrame::white_level` (LibRaw `color.maximum`) for the RAF this
    ///    driver last decoded. Exact, and the only source that survives the
    ///    user changing the body's RAW settings behind our back.
    /// 2. **Reported by the camera** — `XSDK_ImageInformation::lImageBitDepth`
    ///    (XAPI.H:123), populated by `XSDK_ReadImageInfo` for every frame, and
    ///    `XSDK_GetProp(API_CODE_GetRAWOutputDepth)` (XAPIOpt.H:229) at connect.
    ///    This is the only pre-decode source that tracks a GFX body switched to
    ///    `SDK_RAWOUTPUTDEPTH_16BIT` (XAPIOpt.H:585).
    /// 3. **Model table** — [`FujifilmModel::sensor_specs`], a static estimate.
    pub(crate) fn refresh_raw_depth(&mut self) {
        let bit_depth = resolve_bit_depth(
            self.measured_bit_depth,
            self.sdk_reported_bit_depth,
            self.model.sensor_specs().3,
        );
        self.sensor_info.bit_depth = bit_depth;
        self.sensor_info.max_adu = resolve_max_adu(self.measured_white_level, bit_depth);
    }

    /// Set the shutter speed (`code`, or bulb when `bulb` is 1), repeating
    /// while the camera reports itself busy: three more tries 250 ms apart, as
    /// the owner's drivers do.
    pub(crate) async fn set_shutter(
        &self,
        sdk: &FujifilmSdk,
        code: c_long,
        bulb: c_long,
        seconds: f64,
    ) -> Result<(), DriverError> {
        let mut retries_left = 3;
        loop {
            // SAFETY: `self.handle()` is the connected XSDK handle; XSDK_SetShutterSpeed takes (handle, c_long, c_long) POD arguments per XAPI.h.
            let result = unsafe { (sdk.set_shutter_speed)(self.handle(), code, bulb) };
            if result == XSDK_COMPLETE {
                return Ok(());
            }
            let (api_code, err_code) = last_error(self.handle(), sdk);
            if retries_left == 0 || !is_busy(err_code) {
                return Err(sdk_failure(
                    &format!("setting the shutter for a {seconds} s exposure"),
                    api_code,
                    err_code,
                ));
            }
            retries_left -= 1;
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    }

    /// Select the supported ISO nearest to `requested` and record what the
    /// camera accepted.
    pub(crate) async fn apply_iso(
        &mut self,
        sdk: &FujifilmSdk,
        requested: i32,
    ) -> Result<(), DriverError> {
        let iso = nearest_sensitivity(&self.supported_isos, requested);
        if iso != requested {
            tracing::info!(
                "Fujifilm {}: ISO {} is not one of the camera's fixed values; using ISO {}",
                self.id,
                requested,
                iso
            );
        }
        // SAFETY: `self.handle()` is the connected XSDK handle; XSDK_SetSensitivity takes (handle, c_long) POD per XAPI.h.
        let result = unsafe { (sdk.set_sensitivity)(self.handle(), iso as c_long) };
        if result != XSDK_COMPLETE {
            return Err(sdk_error(self.handle(), sdk, &format!("setting ISO {iso}")));
        }
        self.current_iso = iso;
        tokio::time::sleep(Duration::from_millis(100)).await;
        Ok(())
    }

    /// The shutter codes the body offers in its current mode and ISO.
    pub(crate) fn shutter_speeds(&self, sdk: &FujifilmSdk) -> ShutterSpeeds {
        let mut count: c_long = 0;
        let mut bulb_capable: c_long = 0;
        // SAFETY: `self.handle()` is the connected XSDK handle; a NULL code buffer asks only for the count (SDK Programming Reference 4.1.9.4); both out-pointers are valid stack c_long locals.
        let result = unsafe {
            (sdk.cap_shutter_speed)(
                self.handle(),
                &mut count,
                std::ptr::null_mut(),
                &mut bulb_capable,
            )
        };
        if result != XSDK_COMPLETE || count <= 0 {
            tracing::warn!(
                "Fujifilm {}: the camera reported no shutter speeds (result {}); exposures of a second or more use bulb",
                self.id,
                result
            );
            return ShutterSpeeds::default();
        }
        let mut codes: Vec<c_long> = vec![0; count as usize];
        // SAFETY: `codes` holds exactly the `count` entries the first call reported, and `count` tells the SDK that capacity.
        let result = unsafe {
            (sdk.cap_shutter_speed)(
                self.handle(),
                &mut count,
                codes.as_mut_ptr(),
                &mut bulb_capable,
            )
        };
        if result != XSDK_COMPLETE {
            return ShutterSpeeds::default();
        }
        codes.truncate(count.max(0) as usize);
        ShutterSpeeds::from_reported(&codes)
    }

    /// Open the shutter in bulb mode. The SDK lock stays held for the 600 ms
    /// the sequence takes, so the body's lens focuser cannot step in between.
    pub(crate) async fn start_bulb_exposure(
        &mut self,
        sdk: &FujifilmSdk,
        duration_secs: f64,
    ) -> Result<(), DriverError> {
        let mut shot_opt: c_long = 0;
        let mut af_status: c_long = 0;

        // lBulb = 1 selects bulb; the shutter code is then ignored (SDK
        // Programming Reference 4.1.9.5).
        self.set_shutter(sdk, BULB_CODE as c_long, 1, duration_secs)
            .await?;
        tokio::time::sleep(Duration::from_millis(100)).await;

        // SAFETY: `self.handle()` is the connected XSDK handle; `&mut shot_opt` and `&mut af_status` are valid stack out-pointers to c_long; XSDK_RELEASE_S1ON is the documented half-press release flag from XAPI.h.
        let result = unsafe {
            (sdk.release)(
                self.handle(),
                XSDK_RELEASE_S1ON,
                &mut shot_opt,
                &mut af_status,
            )
        };
        if result != XSDK_COMPLETE {
            return Err(sdk_error(
                self.handle(),
                sdk,
                "half-pressing the shutter for a bulb exposure",
            ));
        }
        // Both owner drivers wait 500 ms between the half press and the full
        // press; shorter pauses left bodies without an exposure.
        tokio::time::sleep(Duration::from_millis(500)).await;

        // SAFETY: `self.handle()` still valid; out-pointers valid c_long stack locals; XSDK_RELEASE_BULBS2_ON opens the shutter in bulb mode per XAPI.h's mandatory S1ON→BULBS2_ON sequence.
        let result = unsafe {
            (sdk.release)(
                self.handle(),
                XSDK_RELEASE_BULBS2_ON,
                &mut shot_opt,
                &mut af_status,
            )
        };
        if result != XSDK_COMPLETE {
            let error = sdk_error(
                self.handle(),
                sdk,
                "opening the shutter for a bulb exposure",
            );
            // SAFETY: as above; N_S1OFF releases the half press so the body is not left holding it.
            unsafe {
                (sdk.release)(
                    self.handle(),
                    XSDK_RELEASE_N_S1OFF,
                    &mut shot_opt,
                    &mut af_status,
                )
            };
            return Err(error);
        }

        self.is_bulb_mode = true;
        self.exposure_start = Some(Instant::now());
        self.exposure_duration = Duration::from_secs_f64(duration_secs);
        self.is_exposing = true;

        Ok(())
    }

    /// Close the bulb shutter. The exposure the frame records becomes the time
    /// the shutter was actually held open.
    pub(crate) async fn stop_bulb_exposure(
        &mut self,
        sdk: &FujifilmSdk,
    ) -> Result<(), DriverError> {
        let mut shot_opt: c_long = 0;
        let mut af_status: c_long = 0;

        // SAFETY: `self.handle()` is the connected XSDK handle; out-pointers valid c_long stack locals; XSDK_RELEASE_N_BULBS1OFF closes the shutter, completing the documented bulb sequence.
        let result = unsafe {
            (sdk.release)(
                self.handle(),
                XSDK_RELEASE_N_BULBS1OFF,
                &mut shot_opt,
                &mut af_status,
            )
        };
        if result != XSDK_COMPLETE {
            return Err(sdk_error(
                self.handle(),
                sdk,
                "closing the shutter of the bulb exposure",
            ));
        }
        if let Some(opened) = self.exposure_start {
            self.exposure_duration = opened.elapsed();
        }

        self.is_bulb_mode = false;
        tokio::time::sleep(Duration::from_millis(100)).await;

        Ok(())
    }

    /// End the running exposure and throw away the frame it leaves behind: a
    /// cancelled or stopped exposure still lands a frame in the buffer, and
    /// left there it would be downloaded as the next exposure's frame
    /// (measured on a GFX100S II, owner's NINA plugin 3.1.0.0).
    pub(crate) async fn end_exposure_and_discard_frame(&mut self) -> Result<(), DriverError> {
        if !self.is_exposing {
            return Ok(());
        }
        let sdk = FujifilmSdk::lock().await?;
        if self.is_bulb_mode {
            self.stop_bulb_exposure(&sdk).await?;
        } else {
            let mut shot_opt: c_long = 0;
            let mut status: c_long = 0;
            // SAFETY: `self.handle()` is the connected XSDK handle; out-pointers are valid stack c_long locals; XSDK_RELEASE_CANCEL ends a timed exposure in progress (XAPI.h).
            let result = unsafe {
                (sdk.release)(
                    self.handle(),
                    XSDK_RELEASE_CANCEL,
                    &mut shot_opt,
                    &mut status,
                )
            };
            if result != XSDK_COMPLETE {
                tracing::warn!(
                    "Fujifilm {}: the camera refused to cancel the timed exposure ({}); it runs to the end and its frame is discarded before the next exposure",
                    self.id,
                    sdk_error(self.handle(), &sdk, "cancelling the exposure")
                );
            }
        }
        drop(sdk);
        self.is_exposing = false;
        self.exposure_start = None;

        // The frame appears once the body has read out the sensor.
        let mut discarded = 0;
        for _ in 0..12 {
            tokio::time::sleep(Duration::from_millis(250)).await;
            let sdk = FujifilmSdk::lock().await?;
            discarded += discard_buffered_frames(self.handle(), &sdk);
            if discarded > 0 && frames_in_buffer(self.handle(), &sdk).is_ok_and(|n| n == 0) {
                break;
            }
        }
        tracing::info!(
            "Fujifilm {}: exposure ended early; discarded {} frame(s) it left in the camera",
            self.id,
            discarded
        );
        Ok(())
    }

    /// The newest live view frame as JPEG, starting live view first when it
    /// is not running.
    pub(crate) async fn live_view_frame(&self) -> Result<Vec<u8>, DriverError> {
        let session = self.session.as_ref().ok_or(DriverError::NotConnected)?;
        if self.is_exposing {
            return Err(DriverError::SdkError(
                "Fujifilm camera: live view pauses while the camera takes an exposure".into(),
            ));
        }
        {
            let sdk = FujifilmSdk::lock().await?;
            if lock(&self.live_view).request(Instant::now()) {
                start_live_view(session.handle(), &sdk)?;
                let start = lock(&self.live_view).started();
                tracing::info!("Fujifilm {}: live view started", self.id);
                stop_when_unwatched(
                    self.id.clone(),
                    session.clone(),
                    self.live_view.clone(),
                    start,
                );
            }
        }
        let deadline = Instant::now() + live_view::FRAME_WAIT;
        loop {
            let frame = {
                let sdk = FujifilmSdk::lock().await?;
                read_newest_live_frame(session.handle(), &sdk)?
            };
            if let Some(frame) = frame {
                return Ok(frame);
            }
            if Instant::now() >= deadline {
                return Err(DriverError::Timeout(format!(
                    "Fujifilm camera: live view sent no frame for {:.1} s. Check the USB cable.",
                    live_view::FRAME_WAIT.as_secs_f64()
                )));
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
    }

    /// Stop live view if it runs: before a still exposure and at disconnect.
    pub(crate) async fn end_live_view(&self, sdk: &FujifilmSdk) {
        if !lock(&self.live_view).is_running() {
            return;
        }
        stop_live_view(self.handle(), sdk, &self.id);
        lock(&self.live_view).stopped();
        // The owner's NINA plugin pauses as long before the body takes
        // another command.
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

impl Drop for FujifilmCamera {
    /// A camera the bridge replaces without disconnecting it still gives up
    /// its hold on the body's session.
    fn drop(&mut self) {
        if let Some(session) = self.session.take() {
            lock(&self.live_view).stopped();
            session::leave_later(session);
        }
    }
}

pub(crate) fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|e| e.into_inner())
}

fn start_live_view(handle: XsdkHandle, sdk: &FujifilmSdk) -> Result<(), DriverError> {
    // StartLiveView answers BUSY unless the image buffer is empty (SDK
    // Programming Reference 4.2.16.1).
    discard_buffered_frames(handle, sdk);
    // Fine, because a GFX100S II refuses Normal and every body tested takes
    // Fine (owner's NINA plugin 3.1.0.0); Large, the biggest preview.
    for (code, value, what) in [
        (
            API_CODE_SET_LIVE_VIEW_IMAGE_QUALITY,
            SDK_LIVEVIEW_QUALITY_FINE,
            "quality Fine",
        ),
        (
            API_CODE_SET_LIVE_VIEW_IMAGE_SIZE,
            SDK_LIVEVIEW_SIZE_L,
            "size Large",
        ),
    ] {
        // SAFETY: `handle` is the connected XSDK handle; the value form of XSDK_SetProp takes one c_long after the count (API_PARAM_SetLiveViewImageQuality/Size = 1 in every model header).
        let result = unsafe { (sdk.set_prop)(handle, code, API_PARAM_ONE_VALUE, value) };
        if result != XSDK_COMPLETE {
            tracing::warn!(
                "Fujifilm: the camera kept its own live view setting: {}",
                sdk_error(handle, sdk, &format!("setting live view {what}"))
            );
        }
    }
    // SAFETY: `handle` is the connected XSDK handle; StartLiveView takes no value (API_PARAM_StartLiveView = 0 in every model header).
    let result = unsafe { (sdk.set_prop)(handle, API_CODE_START_LIVE_VIEW, API_PARAM_NONE) };
    if result != XSDK_COMPLETE {
        return Err(sdk_error(handle, sdk, "starting live view"));
    }
    Ok(())
}

fn stop_live_view(handle: XsdkHandle, sdk: &FujifilmSdk, id: &str) {
    // SAFETY: `handle` is the connected XSDK handle; StopLiveView takes no value (API_PARAM_StopLiveView = 0 in every model header).
    let result = unsafe { (sdk.set_prop)(handle, API_CODE_STOP_LIVE_VIEW, API_PARAM_NONE) };
    if result != XSDK_COMPLETE {
        tracing::warn!(
            "Fujifilm {id}: {}",
            sdk_error(handle, sdk, "stopping live view")
        );
    }
    tracing::info!("Fujifilm {id}: live view stopped");
}

/// The newest live view frame waiting in the buffer, `None` when none is
/// there yet. Older ones are dropped first: the body streams 15-18 frames a
/// second and the app asks for at most ten.
fn read_newest_live_frame(
    handle: XsdkHandle,
    sdk: &FujifilmSdk,
) -> Result<Option<Vec<u8>>, DriverError> {
    let waiting = frames_in_buffer(handle, sdk).unwrap_or(0);
    for _ in 0..live_view::frames_to_skip(waiting) {
        // SAFETY: `handle` is the connected XSDK handle; XSDK_DeleteImage takes only the handle.
        if unsafe { (sdk.delete_image)(handle) } != XSDK_COMPLETE {
            break;
        }
    }
    let mut info = XsdkImageInformation::default();
    // SAFETY: `handle` is the connected XSDK handle; `&mut info` is a valid stack out-pointer to the `#[repr(C, packed)]` struct the SDK fills. Its packed fields are copied to locals before use.
    let result = unsafe { (sdk.read_image_info)(handle, &mut info) };
    let (format, size) = (info.l_format, info.l_data_size);
    if result != XSDK_COMPLETE {
        return Err(sdk_error(handle, sdk, "reading the live view frame"));
    }
    if size <= 0 {
        return Ok(None);
    }
    if BufferedImage::from_format(format) != BufferedImage::LiveView {
        tracing::warn!("Fujifilm: dropped a still frame (format 0x{format:X}) that stood in front of live view");
        // SAFETY: as above.
        unsafe { (sdk.delete_image)(handle) };
        return Ok(None);
    }
    let mut buffer = vec![0u8; size as usize];
    // SAFETY: `buffer` holds exactly `size` bytes and that size is passed, so XSDK_ReadImage cannot write past it. ReadImage removes the frame from the buffer.
    let result = unsafe { (sdk.read_image)(handle, buffer.as_mut_ptr(), size as c_ulong) };
    if result != XSDK_COMPLETE {
        return Err(sdk_error(handle, sdk, "downloading the live view frame"));
    }
    Ok(Some(buffer))
}

/// Stop live view once previews stop coming (see `live_view::IDLE_STOP`).
fn stop_when_unwatched(
    id: String,
    session: Arc<Session>,
    demand: Arc<Mutex<LiveViewDemand>>,
    start: u64,
) {
    tokio::spawn(async move {
        loop {
            tokio::time::sleep(Duration::from_secs(1)).await;
            let Ok(sdk) = FujifilmSdk::lock().await else {
                return;
            };
            let idle = {
                let state = lock(&demand);
                if !state.watches(start) {
                    return;
                }
                state.idle(Instant::now())
            };
            if idle {
                stop_live_view(session.handle(), &sdk, &id);
                lock(&demand).stopped();
                return;
            }
        }
    });
}
