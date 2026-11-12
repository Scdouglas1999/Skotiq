use super::*;
use crate::ascom_sensor_type::is_colour_sensor;

/// Get capabilities for an Alpaca camera or mount
///
/// # Silent-fallback contract
///
/// This function probes optional ASCOM/Alpaca capability properties (`CanSlew`,
/// `CanPark`, etc.). Per the ASCOM specification, drivers signal "this feature is
/// not supported" by returning Alpaca error `0x400` (`NotImplemented`) or, on
/// transport failure, a HTTP/parse error. The capability struct exists exactly to
/// expose these advertised-feature flags to the UI; the lenient `unwrap_or(false)`
/// at each site is therefore the **correct** semantics: "if the driver refuses to
/// answer, treat the feature as unavailable rather than crashing the connection
/// dialog". The per-site `// Why:` annotations below cite the specific ASCOM
/// property each fallback represents.
pub(crate) async fn get_alpaca_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    // Use cached parsing for better performance
    let parsed = parse_device_id_cached(device_id)?;
    let (_, _, _, device_type, device_num) = parsed
        .alpaca_info()
        .ok_or_else(|| SkotiqError::invalid_device_id(device_id, "Not an Alpaca device"))?;
    let base_url = parsed
        .alpaca_base_url()
        .ok_or_else(|| SkotiqError::invalid_device_id(device_id, "Missing base URL"))?;

    match device_type {
        "telescope" | "mount" => {
            let telescope = skotiq_alpaca::AlpacaTelescope::from_server(base_url, device_num);

            // probe-and-restore. If the driver is already connected
            // (e.g. the UI has the mount open), reuse the connection rather
            // than connect/disconnect-ing around the property reads, which
            // would kick the active session. `is_connected()` Err → assume
            // connected (fail-safe: never disconnect a session we can't prove
            // we opened).
            let was_connected = telescope.is_connected().await.unwrap_or(true);
            if !was_connected {
                telescope
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
            }

            // Why: every `CanXxx` flag below maps to an OPTIONAL ASCOM telescope
            // property. Drivers that don't implement a capability return 0x400 /
            // NotImplemented; defaulting to `false` means "feature absent" — the
            // intended ASCOM contract for capability discovery.
            let supported_tracking_rates = telescope
                .tracking_rates()
                .await
                .unwrap_or_default()
                .into_iter()
                .map(|rate| match rate {
                    skotiq_alpaca::DriveRate::Sidereal => TrackingRate::Sidereal,
                    skotiq_alpaca::DriveRate::Lunar => TrackingRate::Lunar,
                    skotiq_alpaca::DriveRate::Solar => TrackingRate::Solar,
                    skotiq_alpaca::DriveRate::King => TrackingRate::King,
                })
                .collect::<Vec<_>>();
            let can_set_tracking_rate = !supported_tracking_rates.is_empty();

            let caps = MountCapabilities {
                can_slew: telescope.can_slew().await.unwrap_or(false), // Why: ASCOM ITelescopeV3.CanSlew (optional)
                can_slew_async: telescope.can_slew_async().await.unwrap_or(false), // Why: ASCOM ITelescopeV3.CanSlewAsync (optional)
                can_sync: telescope.can_sync().await.unwrap_or(false), // Why: ASCOM ITelescopeV3.CanSync (optional)
                can_park: telescope.can_park().await.unwrap_or(false), // Why: ASCOM ITelescopeV3.CanPark (optional)
                can_unpark: telescope.can_unpark().await.unwrap_or(false), // Why: ASCOM ITelescopeV3.CanUnpark (optional)
                can_set_park: telescope.can_set_park().await.unwrap_or(false), // Why: ASCOM ITelescopeV3.CanSetPark (optional)
                can_pulse_guide: telescope.can_pulse_guide().await.unwrap_or(false), // Why: ASCOM ITelescopeV3.CanPulseGuide (optional)
                can_set_tracking: telescope.can_set_tracking().await.unwrap_or(false), // Why: ASCOM ITelescopeV3.CanSetTracking (optional)
                // TelescopeRates is the ASCOM/Alpaca contract for which drive
                // rates may be selected. CanSetTracking only controls the
                // boolean Tracking property and is not a rate capability.
                can_set_tracking_rate,
                supported_tracking_rates,
                // An unreadable AlignmentMode is not classified as equatorial.
                is_equatorial: telescope
                    .alignment_mode()
                    .await
                    .is_ok_and(|mode| skotiq_alpaca::AlignmentMode::from(mode).is_equatorial()),
                can_find_home: telescope.can_find_home().await.unwrap_or(false), // Why: ASCOM ITelescopeV3.CanFindHome (optional)
                tracking: telescope.tracking().await.ok(),
                can_abort_slew: true, // Most mounts support abort
                axis_count: 2,        // Alpaca lacks axis_count method, default to 2
                // Why: ASCOM/Alpaca ITelescopeV3 has NO pulse-guide duration-range
                // property — PulseGuide(direction, duration) accepts any non-negative
                // duration and the spec defines no min/max. None = "range unknown",
                // so the UI imposes no artificial clamp on guide-pulse length.
                min_pulse_guide_ms: None,
                max_pulse_guide_ms: None,
                ..Default::default()
            };

            if !was_connected {
                telescope.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::Mount(caps))
        }
        "camera" => {
            let camera = skotiq_alpaca::AlpacaCamera::from_server(base_url, device_num);

            // see top-level docblock. Reuse existing connection if
            // the driver already has it open.
            let was_connected = camera.is_connected().await.unwrap_or(true);
            if !was_connected {
                camera
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
            }

            // Why: ASCOM ICameraV3 capability struct. `CameraXSize/YSize` and `MaxADU`
            // are MANDATORY for any working camera, but we tolerate failure to keep
            // the capability dialog usable on partially-broken drivers (the user
            // will see "0x0 sensor" and disconnect). All `Can*` and `MaxBinX/Y` are
            // optional; defaulting bin to 1 means "no binning supported", which
            // matches the ASCOM convention for cameras that omit `MaxBinX`.
            let controls = camera.controls().await;
            let caps = CameraCapabilities {
                // Why: ICameraV3.CameraXSize is mandatory but treating 0 as "unknown
                // sensor" lets the dialog open even if the driver flakes out on first
                // query; user sees clearly-broken dimensions and reconnects.
                max_width: camera.camera_x_size().await.unwrap_or(0) as u32,
                max_height: camera.camera_y_size().await.unwrap_or(0) as u32, // Why: same as max_width above
                bit_depth: camera
                    .max_adu()
                    .await
                    .map(|a| {
                        if a > 65535 {
                            32
                        } else if a > 255 {
                            16
                        } else {
                            8
                        }
                    })
                    // Why: ICameraV3.MaxADU missing → assume the dominant astro-CCD
                    // depth of 16-bit. 8-bit cameras are vanishingly rare; assuming
                    // 16-bit avoids truncating real 16-bit data should the driver
                    // recover later in the session.
                    .unwrap_or(16),
                has_shutter: camera.has_shutter().await.unwrap_or(false), // Why: ICameraV3.HasShutter (optional, cooled CCDs only)
                can_set_ccd_temperature: camera.can_set_ccd_temperature().await.unwrap_or(false), // Why: ICameraV3.CanSetCCDTemperature (optional)
                // Why: ICameraV3.MaxBinX absent → assume bin 1×1 (no binning), the
                // safest assumption that prevents the UI from offering bin modes
                // the driver may reject.
                can_bin: camera.max_bin_x().await.unwrap_or(1) > 1,
                max_bin_x: camera.max_bin_x().await.unwrap_or(1), // Why: same MaxBinX rationale
                max_bin_y: camera.max_bin_y().await.unwrap_or(1), // Why: same — MaxBinY absent → 1
                can_abort_exposure: camera.can_abort_exposure().await.unwrap_or(false), // Why: ICameraV3.CanAbortExposure (optional)
                can_stop_exposure: camera.can_stop_exposure().await.unwrap_or(false), // Why: ICameraV3.CanStopExposure (optional)
                pixel_size_x: camera.pixel_size_x().await.ok(),
                pixel_size_y: camera.pixel_size_y().await.ok(),
                // Why: ICameraV3.SensorType names a colour family only for the
                // ordinals 1..=5 (see `crate::ascom_sensor_type`); an ordinal
                // outside the enum names no family, and a hidden property names
                // nothing at all. Both read monochrome — debayering a mono frame
                // is a no-op, while claiming colour on a guess produces a green
                // frame.
                is_color: camera
                    .sensor_type()
                    .await
                    .map(is_colour_sensor)
                    .unwrap_or(false),
                can_set_gain: controls.gain.is_present(),
                gain_min: controls.gain.range().map(|(min, _)| min),
                gain_max: controls.gain.range().map(|(_, max)| max),
                can_set_offset: controls.offset.is_present(),
                offset_min: controls.offset.range().map(|(min, _)| min),
                offset_max: controls.offset.range().map(|(_, max)| max),
                can_asymmetric_bin: camera.can_asymmetric_bin().await.unwrap_or(false),
                can_get_cooler_power: camera.can_get_cooler_power().await.unwrap_or(false),
                // CoolerOn is NotImplemented on a camera without a cooler.
                can_set_cooler: camera.cooler_on().await.is_ok(),
                exposure_min: camera.exposure_min().await.ok(),
                exposure_max: camera.exposure_max().await.ok(),
                // Why: ASCOM/Alpaca ICameraV3 exposes SetCCDTemperature (the
                // setpoint) but NO min/max bounds for it — the spec defines no
                // achievable-range property. None = "range unknown"; the UI shows
                // the setpoint field without inventing clamps.
                cooler_min_temp_c: None,
                cooler_max_temp_c: None,
                ..Default::default()
            };

            if !was_connected {
                camera.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::Camera(caps))
        }
        // These have a handle and answer through it once connected
        // (`read_capabilities`); an id that reaches here was never registered.
        "focuser" | "filterwheel" | "rotator" | "dome" | "covercalibrator"
        | "observingconditions" | "safetymonitor" | "switch" => {
            Err(SkotiqError::DeviceNotFound(device_id.to_string()))
        }
        _ => Err(SkotiqError::not_supported(device_id, "get_capabilities")),
    }
}

#[cfg(test)]
mod alpaca_sensor_type_tests {
    use super::is_colour_sensor;

    /// The `is_color` projection the camera arm above applies to
    /// `ICameraV3.SensorType`, including the unreadable-property arm.
    fn is_color(sensor_type: Result<i32, String>) -> bool {
        sensor_type.map(is_colour_sensor).unwrap_or(false)
    }

    /// SensorType 1..=5 are the colour families: direct colour, RGGB, CMYG,
    /// CMYG2, LRGB. All are colour whether or not their mosaic has an element
    /// order this app can name.
    #[test]
    fn colour_families_report_colour() {
        for sensor_type in 1..=5 {
            assert!(
                is_color(Ok(sensor_type)),
                "SensorType={sensor_type} is a colour family"
            );
        }
    }

    /// Monochrome is the one in-enum ordinal that is not colour.
    #[test]
    fn monochrome_reports_mono() {
        assert!(!is_color(Ok(0)));
    }

    /// An ordinal outside the enum names no family, so the camera reads
    /// monochrome rather than being claimed colour on a guess — matching
    /// `ascom_sensor_type`, which leaves such a sensor without a Bayer pattern.
    #[test]
    fn out_of_enum_sensor_type_reports_mono() {
        for sensor_type in [-1, 6, 99, i32::MAX] {
            assert!(
                !is_color(Ok(sensor_type)),
                "SensorType={sensor_type} is outside the enum and names no family"
            );
        }
    }

    /// A driver that refuses SensorType (Alpaca error 0x400, or any transport
    /// failure) names nothing, so the frame stays monochrome instead of being
    /// debayered on a guess.
    #[test]
    fn unreadable_sensor_type_reports_mono() {
        assert!(!is_color(Err("SensorType: Alpaca error 0x400".to_string())));
        assert!(!is_color(
            Err("http 500 from the Alpaca server".to_string())
        ));
    }
}
