use super::*;

#[cfg(windows)]
pub(crate) fn capability_probe_should_own_connection(
    connection_state: Result<bool, String>,
) -> bool {
    matches!(connection_state, Ok(false))
}

#[cfg(windows)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AscomCapabilityDeviceType {
    Camera,
    Mount,
    Focuser,
    FilterWheel,
    Rotator,
    Dome,
    SafetyMonitor,
    Weather,
    Switch,
    CoverCalibrator,
}

#[cfg(windows)]
pub(crate) fn normalize_ascom_capability_device_type(
    value: &str,
) -> Option<AscomCapabilityDeviceType> {
    let normalized = value
        .trim()
        .to_ascii_lowercase()
        .replace([' ', '-', '_'], "");
    match normalized.as_str() {
        "camera" | "icamera" | "icamerav2" | "icamerav3" | "icamerav4" => {
            Some(AscomCapabilityDeviceType::Camera)
        }
        "telescope" | "mount" | "itelescope" | "itelescopev2" | "itelescopev3" => {
            Some(AscomCapabilityDeviceType::Mount)
        }
        "focuser" | "ifocuser" | "ifocuserv2" | "ifocuserv3" => {
            Some(AscomCapabilityDeviceType::Focuser)
        }
        "filterwheel" | "ifilterwheel" | "ifilterwheelv2" => {
            Some(AscomCapabilityDeviceType::FilterWheel)
        }
        "rotator" | "irotator" | "irotatorv2" | "irotatorv3" => {
            Some(AscomCapabilityDeviceType::Rotator)
        }
        "dome" | "idome" | "idomev2" => Some(AscomCapabilityDeviceType::Dome),
        "safetymonitor" | "isafetymonitor" | "isafetymonitorv1" => {
            Some(AscomCapabilityDeviceType::SafetyMonitor)
        }
        "observingconditions" | "weather" | "iobservingconditions" => {
            Some(AscomCapabilityDeviceType::Weather)
        }
        "switch" | "iswitch" | "iswitchv2" => Some(AscomCapabilityDeviceType::Switch),
        "covercalibrator" | "icovercalibrator" | "icovercalibratorv1" => {
            Some(AscomCapabilityDeviceType::CoverCalibrator)
        }
        _ => None,
    }
}

#[cfg(windows)]
pub(crate) fn ascom_registry_type_for_capabilities(
    device_type: AscomCapabilityDeviceType,
) -> skotiq_ascom::AscomDeviceType {
    match device_type {
        AscomCapabilityDeviceType::Camera => skotiq_ascom::AscomDeviceType::Camera,
        AscomCapabilityDeviceType::Mount => skotiq_ascom::AscomDeviceType::Telescope,
        AscomCapabilityDeviceType::Focuser => skotiq_ascom::AscomDeviceType::Focuser,
        AscomCapabilityDeviceType::FilterWheel => skotiq_ascom::AscomDeviceType::FilterWheel,
        AscomCapabilityDeviceType::Rotator => skotiq_ascom::AscomDeviceType::Rotator,
        AscomCapabilityDeviceType::Dome => skotiq_ascom::AscomDeviceType::Dome,
        AscomCapabilityDeviceType::SafetyMonitor => {
            skotiq_ascom::AscomDeviceType::SafetyMonitor
        }
        AscomCapabilityDeviceType::Weather => {
            skotiq_ascom::AscomDeviceType::ObservingConditions
        }
        AscomCapabilityDeviceType::Switch => skotiq_ascom::AscomDeviceType::Switch,
        AscomCapabilityDeviceType::CoverCalibrator => {
            skotiq_ascom::AscomDeviceType::CoverCalibrator
        }
    }
}

#[cfg(windows)]
pub(crate) fn ascom_capability_device_types() -> &'static [AscomCapabilityDeviceType] {
    &[
        AscomCapabilityDeviceType::Camera,
        AscomCapabilityDeviceType::Mount,
        AscomCapabilityDeviceType::Focuser,
        AscomCapabilityDeviceType::FilterWheel,
        AscomCapabilityDeviceType::Rotator,
        AscomCapabilityDeviceType::Dome,
        AscomCapabilityDeviceType::SafetyMonitor,
        AscomCapabilityDeviceType::Weather,
        AscomCapabilityDeviceType::Switch,
        AscomCapabilityDeviceType::CoverCalibrator,
    ]
}

#[cfg(windows)]
pub(crate) fn classify_ascom_capability_device_type(
    prog_id: &str,
) -> Result<AscomCapabilityDeviceType, String> {
    let _ = skotiq_ascom::init_com();
    if let Ok(device) = skotiq_ascom::AscomDeviceConnection::new(prog_id) {
        if let Ok(device_type) = device.get_string_property("DeviceType") {
            if let Some(device_type) = normalize_ascom_capability_device_type(&device_type) {
                return Ok(device_type);
            }
        }
    }

    for device_type in ascom_capability_device_types() {
        let registry_type = ascom_registry_type_for_capabilities(*device_type);
        if skotiq_ascom::discover_devices(registry_type)
            .iter()
            .any(|device| device.prog_id.eq_ignore_ascii_case(prog_id))
        {
            return Ok(*device_type);
        }
    }

    Err(format!(
        "Could not determine ASCOM device type for ProgID '{}': DeviceType property was unavailable and the ProgID was not found in ASCOM driver registry",
        prog_id
    ))
}

/// Get capabilities for an ASCOM device (Windows only)
///
/// # Silent-fallback contract
///
/// ASCOM drivers raise `PropertyNotImplementedException` (HRESULT `0x80040400`)
/// when asked for an optional property they don't implement. The COM wrappers
/// in `skotiq_ascom` translate that to `Err`. Each `unwrap_or(false / 0)`
/// below therefore preserves the documented ASCOM "feature absent" semantics —
/// the per-site `// Why:` annotations cite the specific COM property each
/// fallback represents. Forwarding these errors as `?` would prevent the
/// connection dialog from ever populating for partially-conforming drivers.
#[cfg(windows)]
pub(crate) async fn get_ascom_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    use crate::ascom_wrapper::camera::AscomCameraWrapper;
    use crate::ascom_wrapper::mount::AscomMountWrapper;

    let parsed = parse_device_id_cached(device_id)?;
    let prog_id = match &parsed.connection_info {
        crate::device_id::ConnectionInfo::Ascom { prog_id } => prog_id.clone(),
        _ => {
            return Err(SkotiqError::invalid_device_id(
                device_id,
                "Not an ASCOM device",
            ))
        }
    };

    let device_type = classify_ascom_capability_device_type(&prog_id)
        .map_err(|e| SkotiqError::not_supported(device_id, &e))?;

    if device_type == AscomCapabilityDeviceType::Camera {
        // A second COM object for the same ProgID is not an independent
        // capability probe. Many ASCOM local servers share Connected state, so
        // disconnecting that probe also disconnects (or wedges) the live
        // camera. Query the DeviceManager's registered wrapper whenever the
        // camera is already connected.
        let live_wrapper = {
            let manager = crate::api::get_device_manager();
            manager.ascom_cameras.read().await.get(device_id).cloned()
        };
        let ascom_caps = if let Some(wrapper) = live_wrapper {
            wrapper
                .read()
                .await
                .get_capabilities()
                .await
                .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?
        } else {
            let mut wrapper = AscomCameraWrapper::new(prog_id.clone())
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            wrapper
                .connect()
                .await
                .map_err(|e| SkotiqError::connection_failed(device_id, format!("{:?}", e)))?;
            let capabilities = wrapper
                .get_capabilities()
                .await
                .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?;
            let _ = wrapper.disconnect().await;
            capabilities
        };

        Ok(DeviceCapabilities::Camera(CameraCapabilities {
            max_width: ascom_caps.max_width,
            max_height: ascom_caps.max_height,
            bit_depth: ascom_caps.bit_depth,
            has_shutter: ascom_caps.has_shutter,
            can_set_ccd_temperature: ascom_caps.can_set_ccd_temperature,
            can_set_cooler: ascom_caps.can_set_ccd_temperature, // ASCOM doesn't distinguish
            can_get_cooler_power: ascom_caps.can_get_cooler_power,
            can_bin: ascom_caps.can_bin,
            max_bin_x: ascom_caps.max_bin_x,
            max_bin_y: ascom_caps.max_bin_y,
            can_abort_exposure: ascom_caps.can_abort_exposure,
            can_stop_exposure: ascom_caps.can_stop_exposure,
            pixel_size_x: ascom_caps.pixel_size_x,
            pixel_size_y: ascom_caps.pixel_size_y,
            is_color: ascom_caps.is_color,
            bayer_pattern: ascom_caps.bayer_pattern,
            sensor_type: ascom_caps.sensor_name,
            readout_modes: ascom_caps.readout_modes,
            // Why: ASCOM ICameraV3 exposes SetCCDTemperature (the setpoint) but no
            // property bounding the achievable range, so the wrapper cannot report
            // one. None = "range unknown"; the UI shows the setpoint field unclamped.
            cooler_min_temp_c: None,
            cooler_max_temp_c: None,
            ..Default::default()
        }))
    } else if device_type == AscomCapabilityDeviceType::Mount {
        let live_wrapper = {
            let manager = crate::api::get_device_manager();
            manager.ascom_mounts.read().await.get(device_id).cloned()
        };
        let ascom_caps = if let Some(wrapper) = live_wrapper {
            wrapper
                .read()
                .await
                .get_capabilities()
                .await
                .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?
        } else {
            let mut wrapper = AscomMountWrapper::new(prog_id.clone())
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            wrapper
                .connect()
                .await
                .map_err(|e| SkotiqError::connection_failed(device_id, format!("{:?}", e)))?;
            let capabilities = wrapper
                .get_capabilities()
                .await
                .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?;
            let _ = wrapper.disconnect().await;
            capabilities
        };

        Ok(DeviceCapabilities::Mount(MountCapabilities {
            can_slew: ascom_caps.can_slew,
            can_slew_async: ascom_caps.can_slew_async,
            can_sync: ascom_caps.can_sync,
            can_park: ascom_caps.can_park,
            can_unpark: ascom_caps.can_unpark,
            can_set_park: ascom_caps.can_set_park,
            can_pulse_guide: ascom_caps.can_pulse_guide,
            can_set_tracking: ascom_caps.can_set_tracking,
            can_find_home: ascom_caps.can_find_home,
            can_move_axis: ascom_caps.can_move_axis_primary || ascom_caps.can_move_axis_secondary,
            is_equatorial: ascom_caps.is_equatorial,
            axis_count: if ascom_caps.can_move_axis_secondary {
                2
            } else {
                1
            },
            // Why: ASCOM ITelescopeV3.PulseGuide accepts any non-negative duration
            // and the spec defines no min/max guide-pulse property, so the wrapper
            // cannot report a range. None = "range unknown" (no artificial clamp).
            min_pulse_guide_ms: None,
            max_pulse_guide_ms: None,
            ..Default::default()
        }))
    } else if device_type == AscomCapabilityDeviceType::Focuser {
        // As with cameras, mounts and filter wheels, prefer the live registered
        // wrapper. A throwaway COM object for the same ProgID is not an
        // independent client: ASCOM local servers commonly share `Connected`
        // state, so a probe that connects or disconnects its own object mutates
        // the live session. The "we don't have a wrapper yet" comment that used
        // to justify the throwaway here was stale — `DeviceManager` has held
        // `ascom_focusers` (populated on connect, see
        // `device_manager::connection`) for as long as the other typed maps.
        let live_wrapper = {
            let manager = crate::api::get_device_manager();
            manager.ascom_focusers.read().await.get(device_id).cloned()
        };
        let readings = if let Some(wrapper) = live_wrapper {
            wrapper
                .read()
                .await
                .capability_readings()
                .await
                .map_err(|e| SkotiqError::hardware_error(device_id, format!("{:?}", e)))?
        } else {
            // Nothing registered: this is a pre-connect probe (equipment dialog
            // inspecting a device the user has not connected), so owning a
            // short-lived connection is legitimate.
            use skotiq_ascom::{init_com, AscomFocuser};

            // Initialize COM on this thread if needed
            let _ = init_com();

            let mut focuser = AscomFocuser::new(&prog_id)
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;

            let should_disconnect = capability_probe_should_own_connection(focuser.is_connected());
            if should_disconnect {
                focuser
                    .connect()
                    .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
            }

            let caps = focuser.get_capabilities();
            // Live state must be read while the probe still owns the connection.
            // Leaving these at `Default::default()` makes this endpoint report
            // `isMoving: false`, `position: null` and `temperature: null` even
            // while the focuser is demonstrably moving — observed on the rig as
            // three consecutive samples reading
            // `isMoving: false` while `/api/equipment/focuser/status` reported
            // `moving: true` and a position stepping 46560 -> 44880 -> 43240.
            let live = focuser.get_full_status();
            if should_disconnect {
                let _ = focuser.disconnect();
            }

            AscomFocuserReadings {
                max_step: caps.max_step,
                max_increment: caps.max_increment,
                step_size: caps.step_size,
                absolute: caps.absolute,
                temp_comp_available: caps.temp_comp_available,
                temp_comp: live.temp_comp,
                temperature: live.temperature,
                position: live.position,
                is_moving: live.is_moving,
            }
        };

        Ok(DeviceCapabilities::Focuser(
            focuser_capabilities_from_ascom(readings),
        ))
    } else if device_type == AscomCapabilityDeviceType::FilterWheel {
        // As with cameras and mounts, prefer the live registered wrapper. A
        // throwaway COM object can share and then tear down the live driver's
        // connection when its probe disconnects.
        let live_wrapper = {
            let manager = crate::api::get_device_manager();
            manager
                .ascom_filter_wheels
                .read()
                .await
                .get(device_id)
                .cloned()
        };
        if let Some(wrapper) = live_wrapper {
            let wrapper = wrapper.read().await;
            // A FAILED names read must not masquerade as "this wheel has zero
            // filters". `unwrap_or_default()` here turned any read error into an
            // empty list and hence `position_count: 0`, which is
            // indistinguishable from a genuinely empty wheel — the scheduler
            // then rejects every filtered target ("required filter not in
            // wheel") and the UI shows no filters. ASCOM `Names` is one of the
            // reads that intermittently throws 0x80020009 in headless mode, so
            // surface the failure instead of fabricating a 0-slot wheel.
            let names = wrapper
                .get_filter_names()
                .await
                .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
            // An EMPTY names list is legitimate (a wheel that exposes no custom
            // names) — fall back to the driver-reported slot count so the wheel
            // still advertises its real number of positions.
            let slot_count = wrapper.get_filter_count();
            let position = wrapper.get_position().await.ok();
            return Ok(DeviceCapabilities::FilterWheel(FilterWheelCapabilities {
                position_count: if names.is_empty() {
                    slot_count
                } else {
                    i32::try_from(names.len()).unwrap_or(i32::MAX)
                },
                current_position: position,
                filter_names: names,
                focus_offsets: Vec::new(),
                can_set_focus_offsets: false,
                ..Default::default()
            }));
        }

        // No managed connection exists, so an owned, temporary probe is safe.
        use skotiq_ascom::{init_com, AscomFilterWheel};

        let _ = init_com();

        let mut fw = AscomFilterWheel::new(&prog_id)
            .map_err(|e| SkotiqError::connection_failed(device_id, e))?;

        let should_disconnect = capability_probe_should_own_connection(fw.is_connected());
        if should_disconnect {
            fw.connect()
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
        }

        // Why: ASCOM IFilterWheelV2.Names is mandatory but tolerated. On
        // PropertyNotImplemented we expose an empty filter list — UI shows a
        // 0-position wheel and the user reconfigures the driver. Better than
        // failing the entire equipment-profile load on one bad accessor.
        //
        // This is the cold probe taken during profile load / first discovery,
        // where aborting the whole load is worse — but the failure must be
        // logged, because a reported 0-position wheel is indistinguishable from
        // a real empty one and makes the scheduler reject every filtered target
        // ("required filter not in wheel"). The live-wrapper branch above
        // propagates instead, because that one runs during normal operation
        // where a retry is the right answer.
        let names = match fw.names() {
            Ok(n) => n,
            Err(e) => {
                tracing::warn!(
                    "ASCOM filter wheel {}: Names read failed during capability probe \
                     ({}); reporting a 0-position wheel so profile load can continue. \
                     Filtered targets will be rejected until this wheel is re-read \
                     (rescan) — this is a DRIVER/connection fault, not an empty wheel.",
                    device_id,
                    e
                );
                Vec::new()
            }
        };
        let focus_offsets = match fw.focus_offsets() {
            Ok(o) => o,
            Err(e) => {
                tracing::warn!(
                    "ASCOM filter wheel {}: FocusOffsets read failed ({}); per-filter \
                     focus compensation will be skipped for this wheel.",
                    device_id,
                    e
                );
                Vec::new()
            }
        };
        let position = fw.position().ok();
        if should_disconnect {
            let _ = fw.disconnect();
        }

        Ok(DeviceCapabilities::FilterWheel(FilterWheelCapabilities {
            position_count: i32::try_from(names.len()).unwrap_or(i32::MAX),
            current_position: position,
            filter_names: names,
            focus_offsets,
            can_set_focus_offsets: false,
            ..Default::default()
        }))
    } else if device_type == AscomCapabilityDeviceType::Rotator {
        // Query rotator capabilities via ASCOM COM
        use skotiq_ascom::{init_com, AscomRotator};

        let _ = init_com();

        let mut rotator = AscomRotator::new(&prog_id)
            .map_err(|e| SkotiqError::connection_failed(device_id, e))?;

        let should_disconnect = capability_probe_should_own_connection(rotator.is_connected());
        if should_disconnect {
            rotator
                .connect()
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
        }

        let caps = RotatorCapabilities {
            // Why: ASCOM IRotator.InterfaceVersion — if missing, assume the
            // V1 baseline (version 0 < 3) which lacks CanReverse. This is
            // strictly conservative: CanReverse=true on a V1 driver would
            // be a UI bug (the driver throws on Reverse property access).
            can_reverse: rotator.interface_version().unwrap_or(0) >= 3,
            reverse: false,  // Must query if can_reverse is true
            step_size: None, // ASCOM rotators don't expose step size directly
            is_moving: rotator.is_moving().unwrap_or(false), // Why: IRotatorV3.IsMoving — "stationary" default; the polling loop will correct it on the next tick
            mechanical_position: rotator.mechanical_position().ok(),
            position: rotator.position().ok(),
            can_move_absolute: true, // All ASCOM rotators support MoveAbsolute
            can_halt: true,          // All ASCOM rotators support Halt
            // Why: Same interface-version contract as can_reverse above —
            // assume V1 (no Sync) when InterfaceVersion is unreadable.
            can_sync: rotator.interface_version().unwrap_or(0) >= 3,
            // Why: ASCOM IRotatorV3 has NO min/max angle property — the mechanical
            // range is implicit (positions wrap within 0–360 per spec). None =
            // "range unknown / unbounded by contract".
            min_angle_deg: None,
            max_angle_deg: None,
        };

        if should_disconnect {
            let _ = rotator.disconnect();
        }
        Ok(DeviceCapabilities::Rotator(caps))
    } else if device_type == AscomCapabilityDeviceType::Dome {
        // Query dome capabilities via ASCOM COM
        use skotiq_ascom::{init_com, AscomDome};

        let _ = init_com();

        let mut dome = AscomDome::new(&prog_id)
            .map_err(|e| SkotiqError::connection_failed(device_id, e))?;

        let should_disconnect = capability_probe_should_own_connection(dome.is_connected());
        if should_disconnect {
            dome.connect()
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
        }

        // Map ASCOM ShutterStatus integer to our ShutterStatus enum
        let shutter_status = dome.shutter_status().ok().map(|s| match s {
            0 => ShutterStatus::Open,
            1 => ShutterStatus::Closed,
            2 => ShutterStatus::Opening,
            3 => ShutterStatus::Closing,
            _ => ShutterStatus::Unknown,
        });

        let caps = DomeCapabilities {
            // Why: ASCOM IDomeV2 does not expose CanSetAzimuth directly. We
            // probe by attempting SlewToAzimuth(0); success means CanSetAzimuth.
            // On failure, fall back to whether Azimuth is readable — a dome
            // that reports its azimuth but rejects slew is still usable in
            // read-only roles (slaving by another scope's tracking).
            can_set_azimuth: dome
                .slew_to_azimuth(0.0)
                .is_ok()
                .then_some(true)
                .unwrap_or(dome.azimuth().is_ok()),
            can_park: dome.at_park().is_ok(),
            can_find_home: false, // ASCOM Dome doesn't expose CanFindHome directly; conservative
            can_set_shutter: shutter_status.is_some(),
            can_sync_azimuth: false, // ASCOM Dome SyncToAzimuth availability is driver-specific
            azimuth: dome.azimuth().ok(),
            slewing: dome.slewing().unwrap_or(false), // Why: IDomeV2.Slewing — "not slewing" is the safe initial state; polled afterwards
            at_home: false,
            at_park: dome.at_park().unwrap_or(false), // Why: IDomeV2.AtPark — assume "not parked" if unreadable so the user is prompted to park manually
            shutter_status,
            can_slave: false, // Conservative default
            slaved: false,
            can_abort: true, // All ASCOM domes support AbortSlew
        };

        if should_disconnect {
            let _ = dome.disconnect();
        }
        Ok(DeviceCapabilities::Dome(caps))
    } else if device_type == AscomCapabilityDeviceType::SafetyMonitor {
        // Query safety monitor capabilities via ASCOM COM
        use skotiq_ascom::{init_com, AscomSafetyMonitor};

        let _ = init_com();

        let mut safety = AscomSafetyMonitor::new(&prog_id)
            .map_err(|e| SkotiqError::connection_failed(device_id, e))?;

        let should_disconnect = capability_probe_should_own_connection(safety.is_connected());
        if should_disconnect {
            safety
                .connect()
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
        }

        let caps = SafetyMonitorCapabilities {
            // Why: ASCOM ISafetyMonitorV1.IsSafe — the entire purpose of this
            // device class. Defaulting to `false` ("not safe") on read failure
            // is mandatory: a COM error must NEVER be coerced into "safe to
            // image". This matches the ASCOM specification's fail-closed
            // safety contract.
            is_safe: safety.is_safe().unwrap_or(false),
            safety_description: safety.driver_info().ok(),
        };

        if should_disconnect {
            let _ = safety.disconnect();
        }
        Ok(DeviceCapabilities::SafetyMonitor(caps))
    } else if device_type == AscomCapabilityDeviceType::Weather {
        // Query observing conditions capabilities via ASCOM COM
        use skotiq_ascom::{init_com, AscomObservingConditions};

        let _ = init_com();

        let mut weather = AscomObservingConditions::new(&prog_id)
            .map_err(|e| SkotiqError::connection_failed(device_id, e))?;

        let should_disconnect = capability_probe_should_own_connection(weather.is_connected());
        if should_disconnect {
            weather
                .connect()
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
        }

        // Probe each sensor -- ASCOM throws PropertyNotImplementedException for unavailable sensors
        let caps = WeatherCapabilities {
            has_cloud_cover: weather.cloud_cover().is_ok(),
            has_dew_point: weather.dew_point().is_ok(),
            has_humidity: weather.humidity().is_ok(),
            has_pressure: weather.pressure().is_ok(),
            has_rain_rate: weather.rain_rate().is_ok(),
            has_sky_brightness: weather.sky_brightness().is_ok(),
            has_sky_quality: weather.sky_quality().is_ok(),
            has_sky_temperature: weather.sky_temperature().is_ok(),
            has_seeing: weather.star_fwhm().is_ok(),
            has_temperature: weather.temperature().is_ok(),
            has_wind_direction: weather.wind_direction().is_ok(),
            has_wind_gust: weather.wind_gust().is_ok(),
            has_wind_speed: weather.wind_speed().is_ok(),
            average_period: None, // ASCOM ObservingConditions doesn't expose AveragePeriod as a standard property
        };

        if should_disconnect {
            let _ = weather.disconnect();
        }
        Ok(DeviceCapabilities::Weather(caps))
    } else if device_type == AscomCapabilityDeviceType::Switch {
        // Query switch capabilities via ASCOM COM
        use skotiq_ascom::{init_com, AscomSwitch};

        let _ = init_com();

        let mut switch = AscomSwitch::new(&prog_id)
            .map_err(|e| SkotiqError::connection_failed(device_id, e))?;

        let should_disconnect = capability_probe_should_own_connection(switch.is_connected());
        if should_disconnect {
            switch
                .connect()
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
        }

        // Why: ASCOM ISwitchV2.MaxSwitch — 0 fallback means "no channels
        // advertised" so the loop produces an empty switches list; user sees
        // a switch device with no controllable outputs and reconfigures.
        let max_switch = switch.max_switch().unwrap_or(0);
        let mut switches = Vec::new();

        for i in 0..max_switch {
            // Why: ISwitchV2.GetSwitchName(i) — "Switch {i}" fallback lets the
            // user still discriminate channels by index when the driver omits
            // the name array.
            let name = switch
                .get_switch_name(i)
                .unwrap_or_else(|_| format!("Switch {}", i));
            let description = switch.get_switch_description(i).unwrap_or_default(); // Why: ISwitchV2.GetSwitchDescription(i) — empty OK; UI hides empty descriptions
            let min_value = switch.min_switch_value(i).unwrap_or(0.0); // Why: ISwitchV2.MinSwitchValue(i) — pairs with max=1.0 to form a boolean switch by default
            let max_value = switch.max_switch_value(i).unwrap_or(1.0); // Why: ISwitchV2.MaxSwitchValue(i) — see min_value
            let step = 1.0; // ASCOM ISwitchV2 doesn't expose SwitchStep
            let can_write = switch.can_write(i).unwrap_or(false); // Why: ISwitchV2.CanWrite(i) — read-only default forces user verification before issuing writes
            let value = switch.get_switch_value(i).unwrap_or(0.0); // Why: ISwitchV2.GetSwitchValue(i) — 0.0 = "off"/lowest, the safest displayed state
            let is_boolean = (min_value == 0.0 && max_value == 1.0) || (min_value == max_value);

            switches.push(SwitchInfo {
                index: i,
                name,
                description,
                is_boolean,
                min_value,
                max_value,
                step,
                can_write,
                value,
            });
        }

        let caps = SwitchCapabilities {
            switch_count: max_switch,
            switches,
        };

        if should_disconnect {
            let _ = switch.disconnect();
        }
        Ok(DeviceCapabilities::Switch(caps))
    } else if device_type == AscomCapabilityDeviceType::CoverCalibrator {
        // Query cover calibrator capabilities via ASCOM COM
        use skotiq_ascom::{init_com, AscomCoverCalibrator};

        let _ = init_com();

        let mut cc = AscomCoverCalibrator::new(&prog_id)
            .map_err(|e| SkotiqError::connection_failed(device_id, e))?;

        let should_disconnect = capability_probe_should_own_connection(cc.is_connected());
        if should_disconnect {
            cc.connect()
                .map_err(|e| SkotiqError::connection_failed(device_id, e))?;
        }

        // ASCOM CoverState: 0=NotPresent, 1=Closed, 2=Moving, 3=Open, 4=Unknown, 5=Error
        let cover_state = cc.cover_state().ok().map(|s| match s {
            0 => CoverState::NotPresent,
            1 => CoverState::Closed,
            2 => CoverState::Moving,
            3 => CoverState::Open,
            4 => CoverState::Unknown,
            5 => CoverState::Error,
            _ => CoverState::Unknown,
        });

        // ASCOM CalibratorState: 0=NotPresent, 1=Off, 2=NotReady, 3=Ready, 4=Unknown, 5=Error
        let calibrator_state = cc.calibrator_state().ok().map(|s| match s {
            0 => CalibratorState::NotPresent,
            1 => CalibratorState::Off,
            2 => CalibratorState::NotReady,
            3 => CalibratorState::Ready,
            4 => CalibratorState::Unknown,
            5 => CalibratorState::Error,
            _ => CalibratorState::Unknown,
        });

        let caps = CoverCalibratorCapabilities {
            // Why: ASCOM ICoverCalibratorV1.MaxBrightness is mandatory only
            // when a calibrator is present; cover-only devices throw
            // PropertyNotImplemented. 0 means "no brightness levels" which
            // disables the brightness slider — correct for cover-only setups.
            max_brightness: cc.max_brightness().unwrap_or(0),
            cover_present: cover_state.map_or(false, |s| s != CoverState::NotPresent),
            calibrator_present: calibrator_state
                .map_or(false, |s| s != CalibratorState::NotPresent),
            cover_state,
            calibrator_state,
            brightness: cc.brightness().ok(),
        };

        if should_disconnect {
            let _ = cc.disconnect();
        }
        Ok(DeviceCapabilities::CoverCalibrator(caps))
    } else {
        Err(SkotiqError::not_supported(
            device_id,
            "Unknown ASCOM device type",
        ))
    }
}

#[cfg(not(windows))]
pub(crate) async fn get_ascom_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    Err(SkotiqError::not_supported(
        device_id,
        "ASCOM is only available on Windows",
    ))
}
