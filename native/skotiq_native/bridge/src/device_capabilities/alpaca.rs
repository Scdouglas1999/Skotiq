use super::*;
use crate::ascom_sensor_type::is_colour_sensor;

/// Get capabilities for an Alpaca device
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
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
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
                // Why: ASCOM EquatorialSystem enum (0=Other, 1=Topocentric…). Treating an
                // unreadable value as "0 → not equatorial" is conservative: AltAz-only
                // mounts return 0 explicitly, so the downstream UI shouldn't enable
                // RA/Dec controls if the property is missing.
                is_equatorial: telescope.equatorial_system().await.unwrap_or(0) > 0,
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
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            // Why: ASCOM ICameraV3 capability struct. `CameraXSize/YSize` and `MaxADU`
            // are MANDATORY for any working camera, but we tolerate failure to keep
            // the capability dialog usable on partially-broken drivers (the user
            // will see "0x0 sensor" and disconnect). All `Can*` and `MaxBinX/Y` are
            // optional; defaulting bin to 1 means "no binning supported", which
            // matches the ASCOM convention for cameras that omit `MaxBinX`.
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
                exposure_min: None, // Alpaca lacks exposure_min method
                exposure_max: None, // Alpaca lacks exposure_max method
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
        "focuser" => {
            let focuser = skotiq_alpaca::AlpacaFocuser::from_server(base_url, device_num);

            // see top-level docblock.
            let was_connected = focuser.is_connected().await.unwrap_or(true);
            if !was_connected {
                focuser
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            let caps = FocuserCapabilities {
                // Why: ASCOM IFocuserV3.MaxStep is mandatory but tolerating absence
                // with 0 keeps the dialog usable on relative-only focusers that
                // misreport. Downstream UI shows "max 0" → user disables auto-focus.
                max_position: focuser.max_step().await.unwrap_or(0),
                max_increment: focuser.max_increment().await.unwrap_or(0), // Why: IFocuserV3.MaxIncrement (mandatory but tolerated, same as MaxStep)
                step_size: focuser.step_size().await.ok(),
                absolute: focuser.absolute().await.unwrap_or(false), // Why: IFocuserV3.Absolute — default to relative focuser if unknown (safer: forces relative-move UI)
                temp_comp_available: focuser.temp_comp_available().await.unwrap_or(false), // Why: IFocuserV3.TempCompAvailable (optional)
                temp_comp: focuser.temp_comp().await.unwrap_or(false), // Why: IFocuserV3.TempComp — off by default if unreadable
                temperature: focuser.temperature().await.ok(),
                is_moving: focuser.is_moving().await.unwrap_or(false), // Why: IFocuserV3.IsMoving — "not moving" is the safer default; UI re-polls
                position: focuser.position().await.ok(),
                // Alpaca IFocuserV3 exposes Halt as a required method and has
                // no CanHalt property. Reporting the default false contradicts
                // the working halt operation and disables the UI control.
                can_halt: true,
                ..Default::default()
            };

            if !was_connected {
                focuser.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::Focuser(caps))
        }
        "filterwheel" => {
            let fw = skotiq_alpaca::AlpacaFilterWheel::from_server(base_url, device_num);

            // see top-level docblock.
            let was_connected = fw.is_connected().await.unwrap_or(true);
            if !was_connected {
                fw.connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            // A FAILED names lookup must not be reported as "an empty wheel":
            // `position_count: 0` is indistinguishable from a wheel that really
            // has no filters, and it makes the scheduler reject every filtered
            // target ("required filter not in wheel"). Surfacing the error lets
            // the caller retry (or rescan) against a real diagnosis instead of
            // acting on a fabricated capability. A SUCCESSFUL-but-empty list is
            // still passed through untouched — that answer is honest.
            let names = fw.names().await.map_err(|e| {
                SkotiqError::connection_failed(
                    device_id,
                    format!("Failed to read Alpaca filter wheel names: {e}"),
                )
            })?;
            // FocusOffsets is a softer case: an empty list means "no per-filter
            // focus compensation", which degrades a feature rather than
            // fabricating a capability. Keep going, but say so — silently losing
            // offsets looks identical to a wheel that has none configured.
            let offsets = match fw.focus_offsets().await {
                Ok(o) => o,
                Err(e) => {
                    tracing::warn!(
                        "Alpaca filter wheel {}: focus-offset read failed ({}); per-filter \
                         focus compensation will be skipped for this wheel.",
                        device_id,
                        e
                    );
                    Vec::new()
                }
            };

            let caps = FilterWheelCapabilities {
                position_count: names.len() as i32,
                current_position: fw.position().await.ok().map(|p| p as i32),
                filter_names: names,
                focus_offsets: offsets,
                is_moving: false, // Alpaca doesn't have a direct is_moving
                ..Default::default()
            };

            if !was_connected {
                fw.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::FilterWheel(caps))
        }
        "rotator" => {
            let rotator = skotiq_alpaca::AlpacaRotator::from_server(base_url, device_num);

            // see top-level docblock.
            let was_connected = rotator.is_connected().await.unwrap_or(true);
            if !was_connected {
                rotator
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            let caps = RotatorCapabilities {
                can_reverse: rotator.can_reverse().await.unwrap_or(false), // Why: ASCOM IRotatorV3.CanReverse (optional; pre-V3 rotators lack reversal)
                reverse: rotator.reverse().await.unwrap_or(false), // Why: IRotatorV3.Reverse — false (not reversed) is the safer default
                step_size: rotator.step_size().await.ok(),
                is_moving: rotator.is_moving().await.unwrap_or(false), // Why: IRotatorV3.IsMoving — "stationary" default; UI re-polls during slew
                mechanical_position: rotator.mechanical_position().await.ok(),
                position: rotator.position().await.ok(),
                can_move_absolute: true, // Alpaca rotators support absolute positioning
                can_halt: true,          // All rotators support halt
                can_sync: true,          // Most rotators support sync
                // Why: ASCOM/Alpaca IRotatorV3 has NO min/max angle property — the
                // mechanical range is implicit (positions wrap within 0–360 per the
                // spec). None = "range unknown / unbounded by contract".
                min_angle_deg: None,
                max_angle_deg: None,
            };

            if !was_connected {
                rotator.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::Rotator(caps))
        }
        "dome" => {
            let dome = skotiq_alpaca::AlpacaDome::from_server(base_url, device_num);

            // see top-level docblock.
            let was_connected = dome.is_connected().await.unwrap_or(true);
            if !was_connected {
                dome.connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            // Convert Alpaca ShutterStatus to our ShutterStatus
            let shutter_status = dome.shutter_status().await.ok().map(|s| match s {
                skotiq_alpaca::ShutterStatus::Open => ShutterStatus::Open,
                skotiq_alpaca::ShutterStatus::Closed => ShutterStatus::Closed,
                skotiq_alpaca::ShutterStatus::Opening => ShutterStatus::Opening,
                skotiq_alpaca::ShutterStatus::Closing => ShutterStatus::Closing,
                skotiq_alpaca::ShutterStatus::Error => ShutterStatus::Unknown,
            });

            // Why: ASCOM IDomeV2 `Can*` and state flags are all OPTIONAL per spec
            // (a clamshell-only dome implements almost none). Defaulting to false
            // means "feature absent / not in that state", which is the conservative
            // posture for a structure that costs money to mis-control.
            let caps = DomeCapabilities {
                can_set_azimuth: dome.can_set_azimuth().await.unwrap_or(false), // Why: IDomeV2.CanSetAzimuth (optional)
                can_park: dome.can_park().await.unwrap_or(false), // Why: IDomeV2.CanPark (optional)
                can_find_home: dome.can_find_home().await.unwrap_or(false), // Why: IDomeV2.CanFindHome (optional)
                can_set_shutter: dome.can_set_shutter().await.unwrap_or(false), // Why: IDomeV2.CanSetShutter (optional; clamshells often false)
                can_sync_azimuth: dome.can_sync_azimuth().await.unwrap_or(false), // Why: IDomeV2.CanSyncAzimuth (optional)
                azimuth: dome.azimuth().await.ok(),
                slewing: dome.slewing().await.unwrap_or(false), // Why: IDomeV2.Slewing — "not slewing" is the safe initial state
                at_home: dome.at_home().await.unwrap_or(false), // Why: IDomeV2.AtHome — "not at home" is the safe initial state
                at_park: dome.at_park().await.unwrap_or(false), // Why: IDomeV2.AtPark — assume not parked until proven otherwise
                shutter_status,
                can_slave: dome.can_slave().await.unwrap_or(false), // Why: IDomeV2.CanSlave (optional)
                slaved: dome.slaved().await.unwrap_or(false), // Why: IDomeV2.Slaved — "not slaved" is the safe default
                can_abort: true,                              // Alpaca domes support abort
            };

            if !was_connected {
                dome.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::Dome(caps))
        }
        "covercalibrator" => {
            let cc = skotiq_alpaca::AlpacaCoverCalibrator::from_server(base_url, device_num);

            // see top-level docblock.
            let was_connected = cc.is_connected().await.unwrap_or(true);
            if !was_connected {
                cc.connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            // Convert Alpaca CoverStatus to our CoverState
            let cover_state = cc.cover_state().await.ok().map(|s| match s {
                skotiq_alpaca::CoverStatus::NotPresent => CoverState::NotPresent,
                skotiq_alpaca::CoverStatus::Closed => CoverState::Closed,
                skotiq_alpaca::CoverStatus::Moving => CoverState::Moving,
                skotiq_alpaca::CoverStatus::Open => CoverState::Open,
                skotiq_alpaca::CoverStatus::Unknown => CoverState::Unknown,
                skotiq_alpaca::CoverStatus::Error => CoverState::Error,
            });

            // Convert Alpaca CalibratorStatus to our CalibratorState
            let calibrator_state = cc.calibrator_state().await.ok().map(|s| match s {
                skotiq_alpaca::CalibratorStatus::NotPresent => CalibratorState::NotPresent,
                skotiq_alpaca::CalibratorStatus::Off => CalibratorState::Off,
                skotiq_alpaca::CalibratorStatus::NotReady => CalibratorState::NotReady,
                skotiq_alpaca::CalibratorStatus::Ready => CalibratorState::Ready,
                skotiq_alpaca::CalibratorStatus::Unknown => CalibratorState::Unknown,
                skotiq_alpaca::CalibratorStatus::Error => CalibratorState::Error,
            });

            let caps = CoverCalibratorCapabilities {
                // Why: ICoverCalibratorV1.MaxBrightness is mandatory only when a
                // calibrator is present. Defaulting to 0 means "no brightness
                // levels available" — correct for cover-only devices where the
                // calibrator slot is absent.
                max_brightness: cc.max_brightness().await.unwrap_or(0),
                cover_present: cover_state.map_or(false, |s| s != CoverState::NotPresent),
                calibrator_present: calibrator_state
                    .map_or(false, |s| s != CalibratorState::NotPresent),
                cover_state,
                calibrator_state,
                brightness: cc.brightness().await.ok(),
            };

            if !was_connected {
                cc.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::CoverCalibrator(caps))
        }
        "observingconditions" => {
            let weather =
                skotiq_alpaca::AlpacaObservingConditions::from_server(base_url, device_num);

            // see top-level docblock.
            let was_connected = weather.is_connected().await.unwrap_or(true);
            if !was_connected {
                weather
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            // Check which sensors are available by trying to read them
            // If a sensor returns an error, it's likely not available
            let has_cloud_cover = weather.cloud_cover().await.is_ok();
            let has_dew_point = weather.dew_point().await.is_ok();
            let has_humidity = weather.humidity().await.is_ok();
            let has_pressure = weather.pressure().await.is_ok();
            let has_rain_rate = weather.rain_rate().await.is_ok();
            let has_sky_brightness = weather.sky_brightness().await.is_ok();
            let has_sky_quality = weather.sky_quality().await.is_ok();
            let has_sky_temperature = weather.sky_temperature().await.is_ok();
            // Note: star_fwhm/seeing is not part of the standard Alpaca observing conditions API
            let has_seeing = false;
            let has_temperature = weather.temperature().await.is_ok();
            let has_wind_direction = weather.wind_direction().await.is_ok();
            let has_wind_gust = weather.wind_gust().await.is_ok();
            let has_wind_speed = weather.wind_speed().await.is_ok();

            let caps = WeatherCapabilities {
                has_cloud_cover,
                has_dew_point,
                has_humidity,
                has_pressure,
                has_rain_rate,
                has_sky_brightness,
                has_sky_quality,
                has_sky_temperature,
                has_seeing,
                has_temperature,
                has_wind_direction,
                has_wind_gust,
                has_wind_speed,
                average_period: weather.average_period().await.ok(),
            };

            if !was_connected {
                weather.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::Weather(caps))
        }
        "safetymonitor" => {
            let safety = skotiq_alpaca::AlpacaSafetyMonitor::from_server(base_url, device_num);

            // see top-level docblock.
            let was_connected = safety.is_connected().await.unwrap_or(true);
            if !was_connected {
                safety
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            let caps = SafetyMonitorCapabilities {
                // Why: ISafetyMonitorV1.IsSafe is the entire raison-d'être of this
                // device. Defaulting to `false` ("not safe") on read failure is the
                // ONLY correct fallback — a comms error must NEVER be reported as
                // "safe to image". This is the conservative SafetyMonitor contract.
                is_safe: safety.is_safe().await.unwrap_or(false),
                safety_description: None, // Alpaca doesn't provide a description
            };

            if !was_connected {
                safety.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::SafetyMonitor(caps))
        }
        "switch" => {
            let switch = skotiq_alpaca::AlpacaSwitch::from_server(base_url, device_num);
            let was_connected = switch.is_connected().await.unwrap_or(true);
            if !was_connected {
                switch
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            // Why: ASCOM ISwitchV2.MaxSwitch is mandatory. Defaulting to 0 on
            // read failure means "no channels exposed" — the for-loop below then
            // returns an empty `switches` vec, which the UI shows as a switch
            // device with zero controllable outputs. User-visible, non-fatal.
            let max_switch = switch.max_switch().await.unwrap_or(0);
            let mut switches = Vec::new();

            for i in 0..max_switch {
                // Why: ISwitchV2.GetSwitchName(i) is mandatory but tolerating
                // failure with "Switch {i}" lets the user still discriminate
                // channels by index when a driver omits the name table.
                let name = switch
                    .get_switch_name(i)
                    .await
                    .unwrap_or_else(|_| format!("Switch {}", i));
                let description = switch.get_switch_description(i).await.unwrap_or_default(); // Why: ISwitchV2.GetSwitchDescription(i) — empty string OK; UI hides empty descriptions
                let min_value = switch.min_switch_value(i).await.unwrap_or(0.0); // Why: ISwitchV2.MinSwitchValue(i) — 0.0 matches the boolean-switch convention below
                let max_value = switch.max_switch_value(i).await.unwrap_or(1.0); // Why: ISwitchV2.MaxSwitchValue(i) — 1.0 pairs with 0.0 above to produce a boolean switch by default
                                                                                 // Alpaca doesn't provide switch step, default to 1.0
                let step = 1.0;
                let can_write = switch.can_write(i).await.unwrap_or(false); // Why: ISwitchV2.CanWrite(i) — read-only default forces user to verify before issuing writes
                let value = switch.get_switch_value(i).await.unwrap_or(0.0); // Why: ISwitchV2.GetSwitchValue(i) — 0.0 = "off" / lowest, the safest displayed state

                // Determine if this is a boolean switch
                // If min == 0 and max == 1, it's boolean
                let is_boolean = (min_value == 0.0 && max_value == 1.0) || (min_value == max_value);

                let switch_info = SwitchInfo {
                    index: i,
                    name,
                    description,
                    is_boolean,
                    min_value,
                    max_value,
                    step,
                    can_write,
                    value,
                };
                switches.push(switch_info);
            }

            let caps = SwitchCapabilities {
                switch_count: max_switch,
                switches,
            };

            if !was_connected {
                switch.disconnect().await.ok();
            }
            Ok(DeviceCapabilities::Switch(caps))
        }
        _ => Err(SkotiqError::not_supported(
            device_id,
            "get_capabilities",
        )),
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
