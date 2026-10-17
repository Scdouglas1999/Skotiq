use super::*;

impl DeviceManager {
    /// Download image from camera
    pub async fn camera_download_image(&self, device_id: &str) -> Result<ImageData, DeviceOpError> {
        // Get the driver type for this device
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Ascom) => {
                #[cfg(windows)]
                {
                    let cameras = self.ascom_cameras.read().await;
                    if let Some(camera) = cameras.get(device_id) {
                        let mut camera = camera.write().await;
                        return camera.download_image().await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to download image from ASCOM camera {}: {}",
                                    device_id, e
                                ),
                            )
                        });
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("ASCOM camera {} not found", device_id),
                ))
            }
            Some(DriverType::Alpaca) => {
                let cameras = self.alpaca_cameras.read().await;
                if let Some(camera) = cameras.get(device_id) {
                    // Use the new download_image_data method
                    let (width, height, pixels) =
                        camera.download_image_data().await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to download image from Alpaca camera {}: {}",
                                    device_id, e
                                ),
                            )
                        })?;

                    // Get camera metadata
                    // Same as the INDI path below: record a failed read as UNKNOWN
                    // rather than 0, so it cannot outrank the configured gain and
                    // mislabel the frame's FITS header.
                    let gain = match camera.gain().await {
                        Ok(g) => g,
                        Err(e) => {
                            warn!(
                                "Failed to read camera gain for {}: {}. Recording it as \
                                 unknown so the configured gain is used instead.",
                                device_id, e
                            );
                            UNKNOWN_CAMERA_SETTING
                        }
                    };
                    let offset = match camera.offset().await {
                        Ok(o) => o,
                        Err(e) => {
                            warn!(
                                "Failed to read camera offset for {}: {}. Recording it as \
                                 unknown so the configured offset is used instead.",
                                device_id, e
                            );
                            UNKNOWN_CAMERA_SETTING
                        }
                    };
                    let bin_x = match camera.bin_x().await {
                        Ok(b) => b,
                        Err(e) => {
                            warn!(
                                "Failed to read camera bin_x for {}: {}. Using default 1.",
                                device_id, e
                            );
                            1
                        }
                    };
                    let bin_y = match camera.bin_y().await {
                        Ok(b) => b,
                        Err(e) => {
                            warn!(
                                "Failed to read camera bin_y for {}: {}. Using default 1.",
                                device_id, e
                            );
                            1
                        }
                    };
                    let temp = camera.ccd_temperature().await.ok();
                    let exposure_time = match camera.last_exposure_duration().await {
                        Ok(d) => d,
                        Err(e) => {
                            warn!("Failed to read last exposure duration for {}: {}. Using default 0.0.", device_id, e);
                            0.0
                        }
                    };

                    // ASCOM ICameraV3 SensorType: 0=Monochrome, 1=Color (direct
                    // colour, no Bayer mask), 2=RGGB, 3=CMYG, 4=CMYG2, 5=LRGB.
                    // A failed read yields an ordinal outside the enum, which names
                    // no family and so produces no Bayer pattern.
                    let sensor_type = match camera.sensor_type().await {
                        Ok(t) => t,
                        Err(e) => {
                            warn!(
                                "Failed to read sensor type for {}: {}. Marking sensor type unknown.",
                                device_id, e
                            );
                            -1
                        }
                    };
                    // Both offsets must be READ, not assumed: they, and never the
                    // SensorType ordinal, carry which corner of the 2x2 block holds
                    // red. Defaulting a failed read to 0 maps to RGGB —
                    // indistinguishable from a genuine RGGB sensor — which transposes
                    // red and blue on a BGGR/GRBG one-shot-colour camera and stamps
                    // the wrong BAYERPAT into the FITS header, neither of which is
                    // recoverable from the saved frame. `None` means "pattern
                    // unknown", which leaves the frame undebayered rather than
                    // debayered wrongly.
                    let (bayer_offset_x, bayer_offset_y) =
                        if crate::ascom_sensor_type::has_nameable_bayer_order(sensor_type) {
                            match (camera.bayer_offset_x().await, camera.bayer_offset_y().await) {
                                (Ok(x), Ok(y)) => (Some(x), Some(y)),
                                (x, y) => {
                                    warn!(
                                        "Failed to read bayer offsets for {} (x: {:?}, y: {:?}). \
                                         Leaving the Bayer pattern UNKNOWN so the frame is not \
                                         debayered with a guessed pattern.",
                                        device_id,
                                        x.err(),
                                        y.err()
                                    );
                                    (None, None)
                                }
                            }
                        } else {
                            // Nothing to read: no other sensor family carries an
                            // RGGB-style order, so the two property round-trips are
                            // skipped for every frame off a mono, direct-colour or
                            // CMYG/CMYG2/LRGB camera.
                            (None, None)
                        };
                    let bayer_pattern = crate::ascom_sensor_type::bayer_pattern_from_sensor(
                        sensor_type,
                        bayer_offset_x,
                        bayer_offset_y,
                    );

                    // A colour sensor with no nameable Bayer order leaves this
                    // frame undebayered and writes no BAYERPAT card. That is
                    // correct for a direct-colour or CMYG/CMYG2/LRGB sensor, but
                    // silent for a Bayer one-shot-colour camera whose driver
                    // MISREPORTS SensorType as 1 — the OSC gate keys on 2 — and
                    // the loss is not recoverable from the saved frame. Say it
                    // here, on the download, so the operator reads it in the
                    // app's log rather than finding it in the pixels; latched
                    // per (device, SensorType) because a legitimately
                    // undebayerable camera downloads a frame every exposure.
                    crate::ascom_sensor_type::warn_debayer_skip_once(device_id, sensor_type);

                    return Ok(ImageData {
                        width,
                        height,
                        data: pixels,
                        bits_per_pixel: 16,
                        bayer_pattern,
                        metadata: skotiq_native::camera::ImageMetadata {
                            exposure_time,
                            gain,
                            offset,
                            bin_x,
                            bin_y,
                            temperature: temp,
                            timestamp: chrono::Utc::now(),
                            subframe: None,
                            readout_mode: None,
                            vendor_data: skotiq_native::camera::VendorFeatures::default(),
                        },
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca camera {} not found", device_id),
                ))
            }
            Some(DriverType::Indi) => {
                // For INDI, image download uses event-based BLOB handling
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");

                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        // Create an IndiCamera wrapper to handle BLOB download
                        let camera = skotiq_indi::IndiCamera::new(Arc::clone(client), &device_name);

                        // Subscribe to BLOB events BEFORE enable_blob + the
                        // metadata round-trips below: the exposure may already
                        // be completing, and a BLOB emitted during those reads
                        // would otherwise be missed by a later subscription.
                        let mut rx = {
                            let locked_client = client.read().await;
                            locked_client.subscribe()
                        };

                        // Enable BLOB transfer if not already enabled. A refused
                        // enableBLOB means the image can never arrive on this
                        // connection, and the only symptom downstream is the
                        // 30-second "Timeout waiting for INDI image BLOB" below —
                        // which reads as a slow camera. Name the real cause.
                        if let Err(e) = camera.enable_blob().await {
                            warn!(
                                "Failed to enable INDI BLOB transfer for {}: {}. No image can \
                                 be delivered on this connection until it succeeds.",
                                device_id, e
                            );
                        }

                        // Get image metadata
                        let width = match camera.get_sensor_width().await {
                            Some(w) => w as u32,
                            None => {
                                warn!(
                                    "Failed to read INDI sensor width for {}. Using default 1920.",
                                    device_id
                                );
                                1920
                            }
                        };
                        let height = match camera.get_sensor_height().await {
                            Some(h) => h as u32,
                            None => {
                                warn!(
                                    "Failed to read INDI sensor height for {}. Using default 1080.",
                                    device_id
                                );
                                1080
                            }
                        };
                        let (bin_x, bin_y) = match camera
                            .get_binning_or_default(std::time::Duration::from_millis(0))
                            .await
                        {
                            Ok(b) => b,
                            Err(e) => {
                                warn!(
                                    "Failed to read INDI binning for {}: {}. Using default (1, 1).",
                                    device_id, e
                                );
                                (1, 1)
                            }
                        };
                        let temp = camera.get_temperature().await.ok();
                        // A FAILED read must not masquerade as "gain 0": that 0 was
                        // wrapped in Some() downstream, which short-circuited
                        // `image_data.gain.or(config.gain)` and let it BEAT the
                        // operator's configured gain — stamping GAIN=0 into every
                        // frame's FITS header for the run and permanently breaking
                        // dark/flat library matching, which keys on gain.
                        // UNKNOWN_CAMERA_SETTING is mapped back to None at the
                        // ImageMetadata boundary so the configured value wins.
                        let gain = match camera.get_gain().await {
                            Ok(g) => g,
                            Err(e) => {
                                warn!(
                                    "Failed to read INDI gain for {}: {}. Recording it as \
                                     unknown so the configured gain is used instead.",
                                    device_id, e
                                );
                                UNKNOWN_CAMERA_SETTING
                            }
                        };
                        let offset = match camera.get_offset().await {
                            Ok(o) => o,
                            Err(e) => {
                                warn!(
                                    "Failed to read INDI offset for {}: {}. Recording it as \
                                     unknown so the configured offset is used instead.",
                                    device_id, e
                                );
                                UNKNOWN_CAMERA_SETTING
                            }
                        };

                        // Build an ImageData from a raw INDI image BLOB (FITS or
                        // raw u16). Shared by the event path and the cached-BLOB
                        // fallback below so both decode identically.
                        let build_image = |data: Vec<u8>| -> ImageData {
                            // The FITS header carries the frame's TRUE geometry in
                            // the mandatory NAXIS1/NAXIS2 keywords; prefer them
                            // over the CCD_INFO-derived guess. CCD_MAX_X/Y is the
                            // full UNBINNED sensor, so at bin 2 the two disagree —
                            // measured against a live INDI CCD simulator: CCD_INFO
                            // says 1280x1024 while the BLOB says NAXIS1=640,
                            // NAXIS2=512. Trusting CCD_INFO there builds an
                            // ImageData claiming 1280x1024 around a 640x512 frame,
                            // which fails validation outright; and when CCD_INFO is
                            // unreadable the 1920x1080 fallback below silently
                            // CROPS and re-strides the frame instead, because the
                            // truncate() makes the downstream size check pass
                            // tautologically.
                            let mut fits_dims: Option<(u32, u32)> = None;
                            let image_data = if data.starts_with(b"SIMPLE") {
                                let mut off = 0;
                                let mut naxis1: Option<u32> = None;
                                let mut naxis2: Option<u32> = None;
                                for chunk in data.chunks(80) {
                                    off += 80;
                                    if chunk.starts_with(b"NAXIS1") {
                                        naxis1 = parse_fits_card_u32(chunk);
                                    } else if chunk.starts_with(b"NAXIS2") {
                                        naxis2 = parse_fits_card_u32(chunk);
                                    }
                                    if chunk.starts_with(b"END") {
                                        off = ((off + 2879) / 2880) * 2880;
                                        break;
                                    }
                                }
                                if let (Some(w), Some(h)) = (naxis1, naxis2) {
                                    if w > 0 && h > 0 {
                                        fits_dims = Some((w, h));
                                    }
                                }
                                let binary_data = &data[off.min(data.len())..];
                                let mut pixels: Vec<u16> =
                                    Vec::with_capacity(binary_data.len() / 2);
                                for chunk in binary_data.as_chunks::<2>().0.iter() {
                                    pixels.push(u16::from_be_bytes([chunk[0], chunk[1]]));
                                }
                                pixels
                            } else {
                                let mut pixels: Vec<u16> = Vec::with_capacity(data.len() / 2);
                                for chunk in data.as_chunks::<2>().0.iter() {
                                    pixels.push(u16::from_le_bytes([chunk[0], chunk[1]]));
                                }
                                pixels
                            };
                            let (eff_width, eff_height) = match fits_dims {
                                Some((w, h)) => {
                                    if (w, h) != (width, height) {
                                        tracing::info!(
                                            "INDI {}: using FITS NAXIS {}x{} instead of \
                                             CCD_INFO-derived {}x{} (binning/subframe)",
                                            device_id,
                                            w,
                                            h,
                                            width,
                                            height
                                        );
                                    }
                                    (w, h)
                                }
                                None => (width, height),
                            };
                            // Trim FITS block padding beyond width*height. Only ever
                            // discards the tail padding now that the dimensions are
                            // the frame's own; a SHORT buffer is left short so
                            // validation can still catch it rather than being
                            // silently reshaped.
                            let expected_pixels = (eff_width as usize) * (eff_height as usize);
                            let mut image_data = image_data;
                            if image_data.len() > expected_pixels {
                                image_data.truncate(expected_pixels);
                            }
                            ImageData {
                                width: eff_width,
                                height: eff_height,
                                data: image_data,
                                bits_per_pixel: 16,
                                bayer_pattern: None,
                                metadata: skotiq_native::camera::ImageMetadata {
                                    exposure_time: 0.0,
                                    gain,
                                    offset,
                                    bin_x,
                                    bin_y,
                                    temperature: temp,
                                    timestamp: chrono::Utc::now(),
                                    subframe: None,
                                    readout_mode: None,
                                    vendor_data: skotiq_native::camera::VendorFeatures::default(),
                                },
                            }
                        };

                        // Wait for BLOB data with timeout (30 seconds)
                        let timeout = std::time::Duration::from_secs(30);
                        let start_time = std::time::Instant::now();

                        loop {
                            if start_time.elapsed() > timeout {
                                return Err(DeviceOpError::hardware(
                                    Some(device_id.to_string()),
                                    "Timeout waiting for INDI image BLOB",
                                ));
                            }

                            match tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
                                .await
                            {
                                Ok(Ok(event)) => match event {
                                    skotiq_indi::IndiEvent::BlobReceived {
                                        device,
                                        element,
                                        data,
                                        ..
                                    } if device == device_name
                                        && (element == "CCD1" || element == "CCD2") =>
                                    {
                                        return Ok(build_image(data));
                                    }
                                    _ => {}
                                },
                                Ok(Err(_)) => {
                                    return Err(DeviceOpError::hardware(
                                        Some(device_id.to_string()),
                                        "INDI event channel closed",
                                    ));
                                }
                                Err(_) => {
                                    // recv timed out; the reader may have stored
                                    // the BLOB before we subscribed. Poll the
                                    // cache before looping so a race can't hang.
                                    let cached = {
                                        let lc = client.read().await;
                                        match lc.take_blob(&device_name, "CCD1", "CCD1").await {
                                            Some(d) => Some(d),
                                            None => {
                                                lc.take_blob(&device_name, "CCD2", "CCD2").await
                                            }
                                        }
                                    };
                                    if let Some(data) = cached {
                                        return Ok(build_image(data));
                                    }
                                    continue;
                                }
                            }
                        }
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => {
                // Project gain/offset/bin/temperature from the singleton so a
                // simulated download reflects whatever the test or UI
                // configured via set_gain / set_offset / set_binning /
                // set_cooler, and take the frame geometry from the SAME sensor
                // declaration the camera advertised.
                let sim = crate::device_manager::ops::sim_gate::read_camera_status().await?;
                let request =
                    crate::device_manager::ops::sim_gate::read_camera_last_exposure().await?;
                // Claim the finished frame, which both refuses a download the
                // camera cannot honestly satisfy and returns it to idle so a
                // caller that polls completion afterwards is not told to keep
                // waiting. Ungated, this synthesized a full frame stamped with
                // the requested EXPTIME mid-exposure and after an abort, so a
                // cancelled or raced capture still produced a saved light frame.
                crate::api::devices::simulation::take_sim_exposure_for_download()
                    .await
                    .map_err(|detail| {
                        DeviceOpError::hardware(Some(device_id.to_string()), detail)
                    })?;
                // Synthetic download: an electron-domain frame whose star PSF
                // tracks focuser defocus, painting the sky the mount is actually
                // on. `crate::sim_capture` is the single renderer for this path
                // and for the Imaging screen's manual capture, so a simulated
                // frame is plate-solvable however it was taken.
                let frame =
                    crate::sim_capture::render_sim_frame(crate::sim_capture::SimCaptureRequest {
                        exposure_secs: request.secs,
                        sensor_width: sim.sensor_width.max(1),
                        sensor_height: sim.sensor_height.max(1),
                        pixel_size_um: sim.pixel_size_x,
                        gain: sim.gain,
                        offset: sim.offset,
                        bin_x: sim.bin_x.max(1) as u32,
                        bin_y: sim.bin_y.max(1) as u32,
                        subframe: request.subframe,
                        frame_type: request.frame_type,
                        max_adu: sim.max_adu.clamp(1, u32::from(u16::MAX)) as u16,
                    })
                    .await;
                let (width, height) = (frame.width, frame.height);
                Ok(ImageData {
                    width,
                    height,
                    data: frame.data,
                    bits_per_pixel: 16,
                    bayer_pattern: None,
                    metadata: skotiq_native::camera::ImageMetadata {
                        exposure_time: request.secs,
                        gain: sim.gain,
                        offset: sim.offset,
                        bin_x: sim.bin_x,
                        bin_y: sim.bin_y,
                        temperature: sim.sensor_temp,
                        timestamp: chrono::Utc::now(),
                        subframe: request.subframe.map(|(start_x, start_y, width, height)| {
                            skotiq_native::camera::SubFrame {
                                start_x,
                                start_y,
                                width,
                                height,
                            }
                        }),
                        readout_mode: None,
                        vendor_data: skotiq_native::camera::VendorFeatures::default(),
                    },
                })
            }
            Some(DriverType::Native) => {
                let mut native_cameras = self.native_cameras.write().await;
                if let Some(camera) = native_cameras.get_mut(device_id) {
                    return camera.download_image().await.map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            None => Err(DeviceOpError::not_connected(
                Some(device_id.to_string()),
                format!("Camera {} not found", device_id),
            )),
        }
    }

    /// Capture a live-view / preview JPEG frame when the connected driver supports it.
    pub async fn camera_capture_preview(&self, device_id: &str) -> Result<Vec<u8>, DeviceOpError> {
        let driver_type = {
            let devices = self.devices.read().await;
            devices.get(device_id).map(|d| d.info.driver_type.clone())
        };

        match driver_type {
            Some(DriverType::Native) => {
                let native_cameras = self.native_cameras.read().await;
                if let Some(camera) = native_cameras.get(device_id) {
                    return camera.capture_preview().await.map_err(DeviceOpError::from);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Native SDK camera {} not found", device_id),
                ))
            }
            Some(DriverType::Simulator) => Err(DeviceOpError::unsupported(
                crate::device_manager::ops::sim_gate::unsupported_simulator_device(
                    "camera preview",
                ),
            )),
            _ => Err(DeviceOpError::unsupported(format!(
                "Live view preview is not supported for driver {:?} on camera {}",
                driver_type, device_id
            ))),
        }
    }
}

#[cfg(test)]
mod alpaca_bayer_gate_tests {
    use crate::ascom_sensor_type::{bayer_pattern_from_sensor, has_nameable_bayer_order};
    use skotiq_native::camera::BayerPattern;
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
