use super::*;

pub(crate) fn indi_sensor_type_is_color(sensor_type: &str) -> bool {
    let normalized = sensor_type.to_ascii_lowercase();
    normalized.contains("color")
        || normalized.contains("colour")
        || normalized.contains("bayer")
        || normalized.contains("cfa")
        || normalized.contains("rgb")
        || normalized.contains("osc")
}

pub(crate) fn indi_readout_mode_label(mode: &skotiq_indi::IndiReadoutMode) -> String {
    if mode.label.is_empty() {
        mode.element.clone()
    } else {
        mode.label.clone()
    }
}

/// Get capabilities for an INDI device
///
/// INDI devices report capabilities through their property definitions.
/// This function queries the INDI server to discover what properties
/// (and thus capabilities) a device supports.
pub(crate) async fn get_indi_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    use skotiq_indi::{IndiCamera, IndiClient, IndiFilterWheel, IndiFocuser, IndiPermission};

    let parsed = parse_device_id_cached(device_id)?;
    let (host, port, device_name) = match &parsed.connection_info {
        crate::device_id::ConnectionInfo::Indi {
            host,
            port,
            device_name,
        } => (host.clone(), *port, device_name.clone()),
        _ => {
            return Err(SkotiqError::invalid_device_id(
                device_id,
                "Not an INDI device",
            ))
        }
    };

    let server_key = format!("{}:{}", host, port);
    let client = {
        let mgr = crate::api::get_device_manager();
        if let Some(client) = mgr.indi_clients.read().await.get(&server_key).cloned() {
            client
        } else {
            let mut clients = mgr.indi_clients.write().await;
            if let Some(client) = clients.get(&server_key).cloned() {
                client
            } else {
                let mut new_client = IndiClient::new(&host, Some(port));
                new_client
                    .connect()
                    .await
                    .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
                let client = Arc::new(RwLock::new(new_client));
                clients.insert(server_key.clone(), Arc::clone(&client));
                client
            }
        }
    };

    // INDI servers publish capability-bearing property definitions
    // asynchronously after connect; reuse an existing populated client when
    // present, otherwise wait briefly for the newly pooled client to hydrate.
    let start = std::time::Instant::now();
    let properties = loop {
        let properties = {
            let locked_client = client.read().await;
            locked_client.get_properties(&device_name).await
        };
        if !properties.is_empty() || start.elapsed() >= std::time::Duration::from_secs(1) {
            break properties;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    };

    // Determine device type based on standard INDI property names
    let has_ccd_props = properties
        .iter()
        .any(|p| p.name.starts_with("CCD_") || p.name == "CCD_EXPOSURE");
    let has_telescope_props = properties
        .iter()
        .any(|p| p.name.starts_with("EQUATORIAL_") || p.name == "TELESCOPE_MOTION_NS");
    let has_focuser_props = properties
        .iter()
        .any(|p| p.name.starts_with("FOCUS_") || p.name == "ABS_FOCUS_POSITION");
    let has_filter_props = properties
        .iter()
        .any(|p| p.name.starts_with("FILTER_") || p.name == "FILTER_SLOT");
    // Mirrors the rotator detection in indi/src/discovery.rs (ABS_ROTATOR_ANGLE
    // is the absolute-position rotator; ROTATOR_ANGLE is the legacy/raw form).
    let has_rotator_props = properties
        .iter()
        .any(|p| p.name == "ABS_ROTATOR_ANGLE" || p.name == "ROTATOR_ANGLE");
    // Mirrors the dome detection in indi/src/discovery.rs (a dome publishes at
    // least one of shutter control, azimuth motion, or absolute position).
    let has_dome_props = properties.iter().any(|p| {
        p.name == "DOME_SHUTTER" || p.name == "DOME_MOTION" || p.name == "ABS_DOME_POSITION"
    });

    // Build capabilities based on discovered properties
    if has_ccd_props {
        // Check for specific CCD capabilities
        let can_abort = properties.iter().any(|p| p.name == "CCD_ABORT_EXPOSURE");
        let has_cooler = properties
            .iter()
            .any(|p| p.name == "CCD_COOLER" || p.name == "CCD_TEMPERATURE");
        let has_binning = properties.iter().any(|p| p.name == "CCD_BINNING");
        let has_subframe = properties.iter().any(|p| p.name == "CCD_FRAME");
        let has_gain = properties
            .iter()
            .any(|p| p.name == "CCD_GAIN" || p.name == "CCD_CONTROLS");
        let has_offset = properties.iter().any(|p| p.name == "CCD_OFFSET");

        let camera = IndiCamera::new(Arc::clone(&client), &device_name);
        let gain_range = camera.get_gain_range().await;
        let sensor_type = camera.get_sensor_type().await;
        let bayer_pattern = camera.get_bayer_pattern().await;
        let readout_modes = camera.get_readout_modes().await;
        let max_bin_x = camera.try_get_max_bin_x().await.ok().flatten().unwrap_or(0);
        let max_bin_y = camera.try_get_max_bin_y().await.ok().flatten().unwrap_or(0);
        let bit_depth = camera
            .get_bits_per_pixel()
            .await
            .and_then(|v| u32::try_from(v).ok())
            .unwrap_or(0);
        let sensor_type_is_color = sensor_type
            .as_deref()
            .map(indi_sensor_type_is_color)
            .unwrap_or(false);
        let is_color = bayer_pattern.is_some() || sensor_type_is_color;
        let readout_mode_names: Vec<String> =
            readout_modes.iter().map(indi_readout_mode_label).collect();

        // Why: INDI exposes the achievable regulated-cooling range via the
        // CCD_TEMPERATURE number property's min/max limits (the same source the
        // driver clamps the setpoint to). Absent property/limits → None ("range
        // unknown"), never a fabricated clamp.
        let (cooler_min_temp_c, cooler_max_temp_c) = {
            let locked_client = client.read().await;
            let limits = locked_client
                .get_number_limits(&device_name, "CCD_TEMPERATURE", "CCD_TEMPERATURE_VALUE")
                .await;
            (
                limits.as_ref().and_then(|l| l.min),
                limits.as_ref().and_then(|l| l.max),
            )
        };

        Ok(DeviceCapabilities::Camera(CameraCapabilities {
            can_abort_exposure: can_abort,
            can_set_ccd_temperature: has_cooler,
            can_set_cooler: has_cooler,
            can_bin: has_binning,
            max_bin_x,
            max_bin_y,
            can_asymmetric_bin: max_bin_x != max_bin_y,
            can_set_gain: has_gain,
            gain_min: gain_range.map(|(min, _)| min),
            gain_max: gain_range.map(|(_, max)| max),
            can_set_offset: has_offset,
            can_subframe: has_subframe,
            max_width: camera
                .get_sensor_width()
                .await
                .and_then(|v| u32::try_from(v).ok())
                .unwrap_or(0),
            max_height: camera
                .get_sensor_height()
                .await
                .and_then(|v| u32::try_from(v).ok())
                .unwrap_or(0),
            bit_depth,
            pixel_size_x: camera.get_pixel_size_x().await,
            pixel_size_y: camera.get_pixel_size_y().await,
            is_color,
            bayer_pattern: bayer_pattern.map(|p| p.pattern),
            sensor_type,
            has_fast_readout: readout_mode_names.len() > 1,
            readout_modes: readout_mode_names,
            cooler_min_temp_c,
            cooler_max_temp_c,
            ..Default::default()
        }))
    } else if has_telescope_props {
        let has_equatorial = properties.iter().any(|p| p.name.starts_with("EQUATORIAL_"));
        let supports_alt_az = properties.iter().any(|p| p.name == "HORIZONTAL_COORD");
        let can_park = properties.iter().any(|p| p.name == "TELESCOPE_PARK");
        let can_sync = properties.iter().any(|p| p.name == "ON_COORD_SET");
        let can_guide = properties
            .iter()
            .any(|p| p.name.starts_with("TELESCOPE_TIMED_GUIDE_"));
        let can_track = properties.iter().any(|p| p.name == "TELESCOPE_TRACK_STATE");
        let can_get_side_of_pier = properties.iter().any(|p| p.name == "TELESCOPE_PIER_SIDE");
        let can_set_tracking_rate = properties
            .iter()
            .any(|p| p.name == "TELESCOPE_TRACK_RATE" || p.name == "TELESCOPE_TRACK_MODE");
        let mut supported_tracking_rates = Vec::new();
        if properties.iter().any(|p| p.name == "TELESCOPE_TRACK_MODE") {
            supported_tracking_rates.extend([
                TrackingRate::Sidereal,
                TrackingRate::Lunar,
                TrackingRate::Solar,
                TrackingRate::King,
            ]);
        }
        let can_move_ns = properties.iter().any(|p| p.name == "TELESCOPE_MOTION_NS");
        let can_move_we = properties.iter().any(|p| p.name == "TELESCOPE_MOTION_WE");
        let max_slew_rate =
            if let Some(slew_rate) = properties.iter().find(|p| p.name == "TELESCOPE_SLEW_RATE") {
                let locked_client = client.read().await;
                let mut max_rate: Option<f64> = None;
                for element in &slew_rate.elements {
                    if let Some(max) = locked_client
                        .get_number_limits(&device_name, "TELESCOPE_SLEW_RATE", element)
                        .await
                        .and_then(|limits| limits.max)
                    {
                        max_rate = Some(max_rate.map_or(max, |current| current.max(max)));
                    }
                }
                max_rate
            } else {
                None
            };

        // Why: INDI publishes the achievable pulse-guide duration range as the
        // min/max number limits of the TELESCOPE_TIMED_GUIDE_NS (TIMED_GUIDE_N/S)
        // and TELESCOPE_TIMED_GUIDE_WE (TIMED_GUIDE_W/E) properties. We take the
        // smallest reported min and largest reported max across all four elements
        // — the union of both axes — so the UI never offers a pulse outside what
        // any axis accepts. Absent properties/limits → None ("range unknown"),
        // never a fabricated clamp. Mirrors the max_slew_rate element-scan above.
        let (min_pulse_guide_ms, max_pulse_guide_ms) = {
            const TIMED_GUIDE_PROPS: [&str; 2] =
                ["TELESCOPE_TIMED_GUIDE_NS", "TELESCOPE_TIMED_GUIDE_WE"];
            let mut min_pulse: Option<f64> = None;
            let mut max_pulse: Option<f64> = None;
            let locked_client = client.read().await;
            for prop_name in TIMED_GUIDE_PROPS {
                let Some(prop) = properties.iter().find(|p| p.name == prop_name) else {
                    continue;
                };
                for element in &prop.elements {
                    let Some(limits) = locked_client
                        .get_number_limits(&device_name, prop_name, element)
                        .await
                    else {
                        continue;
                    };
                    if let Some(min) = limits.min {
                        min_pulse = Some(min_pulse.map_or(min, |current| current.min(min)));
                    }
                    if let Some(max) = limits.max {
                        max_pulse = Some(max_pulse.map_or(max, |current| current.max(max)));
                    }
                }
            }
            (min_pulse, max_pulse)
        };

        Ok(DeviceCapabilities::Mount(MountCapabilities {
            can_slew: has_equatorial || supports_alt_az,
            can_slew_async: has_equatorial || supports_alt_az,
            can_sync,
            can_park,
            can_unpark: can_park,
            // `IndiMount::set_park_to_current` drives PARK_CURRENT.
            can_set_park: properties.iter().any(|p| {
                p.name == "TELESCOPE_PARK_OPTION" && p.elements.iter().any(|e| e == "PARK_CURRENT")
            }),
            can_pulse_guide: can_guide,
            can_get_side_of_pier,
            can_set_tracking: can_track,
            can_set_tracking_rate,
            supported_tracking_rates,
            is_equatorial: has_equatorial,
            supports_alt_az,
            can_find_home: properties.iter().any(|p| p.name == "TELESCOPE_HOME"),
            can_abort_slew: properties
                .iter()
                .any(|p| p.name == "TELESCOPE_ABORT_MOTION"),
            max_slew_rate,
            can_move_axis: can_move_ns || can_move_we,
            axis_count: u32::from(can_move_ns) + u32::from(can_move_we),
            min_pulse_guide_ms,
            max_pulse_guide_ms,
            ..Default::default()
        }))
    } else if has_focuser_props {
        let is_absolute = properties.iter().any(|p| p.name == "ABS_FOCUS_POSITION");
        let has_temp_comp = properties
            .iter()
            .any(|p| p.name == "FOCUS_TEMPERATURE_COMP" || p.name == "FOCUS_TEMP_COMP");
        let can_halt = properties.iter().any(|p| p.name == "FOCUS_ABORT_MOTION");
        let focuser = IndiFocuser::new(Arc::clone(&client), &device_name);
        let max_position = focuser.get_max_step().await.unwrap_or(0);

        Ok(DeviceCapabilities::Focuser(FocuserCapabilities {
            max_position,
            max_increment: max_position,
            step_size: focuser.get_step_size().await,
            absolute: is_absolute,
            temp_comp_available: has_temp_comp,
            temp_comp: focuser.is_temp_comp_enabled().await.unwrap_or(false),
            temperature: focuser.get_temperature().await.ok(),
            is_moving: focuser.is_moving().await,
            position: focuser.get_position().await.ok(),
            can_halt,
            ..Default::default()
        }))
    } else if has_filter_props {
        let filter_wheel = IndiFilterWheel::new(Arc::clone(&client), &device_name);
        let filter_names = filter_wheel.get_names().await.unwrap_or_default();
        let slot_limits = {
            let locked_client = client.read().await;
            locked_client
                .get_number_limits(&device_name, "FILTER_SLOT", "FILTER_SLOT_VALUE")
                .await
        };
        let position_count = slot_limits
            .and_then(|limits| match (limits.min, limits.max) {
                (Some(min), Some(max)) if max >= min => {
                    // Why: INDI filter slots are a small
                    // physical count; after finite/range validation, f64 to
                    // i32 conversion is bounded and represents a whole count.
                    Some((max - min + 1.0).round() as i32)
                }
                _ => None,
            })
            .or_else(|| i32::try_from(filter_names.len()).ok())
            .unwrap_or(0);
        let can_set_filter_names = properties
            .iter()
            .find(|p| p.name == "FILTER_NAME")
            .map(|p| {
                matches!(
                    p.perm,
                    IndiPermission::WriteOnly | IndiPermission::ReadWrite
                )
            })
            .unwrap_or(false);

        Ok(DeviceCapabilities::FilterWheel(FilterWheelCapabilities {
            position_count,
            current_position: filter_wheel.get_position().await.ok(),
            filter_names,
            focus_offsets: Vec::new(),
            is_moving: filter_wheel.is_moving().await,
            can_set_filter_names,
            can_set_focus_offsets: false,
        }))
    } else if has_rotator_props {
        // INDI rotator. Capabilities are derived from which standard properties
        // the driver published (see indi/src/rotator.rs + protocol.rs for the
        // property/element names). `has_*` flags below are presence checks, so a
        // missing property honestly maps to "capability absent" (false) — no
        // fabricated capability.
        let has_abs_angle = properties.iter().any(|p| p.name == "ABS_ROTATOR_ANGLE");
        let can_reverse = properties.iter().any(|p| p.name == "ROTATOR_REVERSE");
        let can_halt = properties.iter().any(|p| p.name == "ROTATOR_ABORT_MOTION");
        let can_sync = properties.iter().any(|p| p.name == "SYNC_ROTATOR_ANGLE");

        // The absolute rotator exposes its angle under ABS_ROTATOR_ANGLE/ANGLE;
        // legacy drivers use ROTATOR_ANGLE/ANGLE. Read whichever the driver
        // actually published so the position and its limits come from the same
        // property.
        let angle_property = if has_abs_angle {
            "ABS_ROTATOR_ANGLE"
        } else {
            "ROTATOR_ANGLE"
        };

        let (position, min_angle_deg, max_angle_deg) = {
            let locked_client = client.read().await;
            let position = locked_client
                .get_number(&device_name, angle_property, "ANGLE")
                .await;
            // Why: INDI publishes the mechanical angle range as the ANGLE
            // element's min/max number limits. Absent property/limits → None
            // ("range unknown"), never a fabricated 0–360 clamp.
            let limits = locked_client
                .get_number_limits(&device_name, angle_property, "ANGLE")
                .await;
            (
                position,
                limits.as_ref().and_then(|l| l.min),
                limits.as_ref().and_then(|l| l.max),
            )
        };

        let caps = RotatorCapabilities {
            can_reverse,
            // Why: INDI does not report the current reverse state via a
            // capability snapshot here; the rotator state provider polls
            // ROTATOR_REVERSE live. `false` is the safe display default.
            reverse: false,
            // Why: INDI rotators expose absolute angle in degrees but no
            // per-step resolution property; None = "step size unknown".
            step_size: None,
            // Why: motion state is transient and re-polled by the rotator state
            // provider; a capability snapshot defaults to "stationary".
            is_moving: false,
            // INDI reports a single angle; mechanical and sky position coincide
            // until a SYNC_ROTATOR_ANGLE offset is applied (tracked live by the
            // state provider, not in this static snapshot).
            mechanical_position: position,
            position,
            can_move_absolute: has_abs_angle,
            can_halt,
            can_sync,
            min_angle_deg,
            max_angle_deg,
        };

        Ok(DeviceCapabilities::Rotator(caps))
    } else if has_dome_props {
        // INDI dome. Capabilities are presence checks over the standard dome
        // properties (see indi/src/dome.rs for the property/element names the
        // ops actually drive). A missing property honestly maps to "capability
        // absent" (false) — no fabricated capability. Before this branch existed,
        // every INDI dome fell through to the `not_supported` arm below, which
        // the Dart dome handler surfaced as 501 for open/close/park/home even
        // though the native ops are fully implemented.
        let can_set_shutter = properties.iter().any(|p| p.name == "DOME_SHUTTER");
        let can_set_azimuth = properties.iter().any(|p| p.name == "ABS_DOME_POSITION");
        // Home and park are both driven via DOME_GOTO (DOME_HOME / DOME_PARK
        // elements); unpark additionally uses the DOME_PARK switch vector.
        let has_goto = properties.iter().any(|p| p.name == "DOME_GOTO");
        let can_find_home = has_goto;
        let can_park = has_goto || properties.iter().any(|p| p.name == "DOME_PARK");
        let can_abort = properties.iter().any(|p| p.name == "DOME_ABORT_MOTION");
        let can_slave = properties.iter().any(|p| p.name == "DOME_AUTOSYNC");

        // Live snapshot values (re-polled by the dome state provider on a timer;
        // absent/failed reads fall back to safe defaults).
        let locked_client = client.read().await;
        let azimuth = locked_client
            .get_number(&device_name, "ABS_DOME_POSITION", "DOME_ABSOLUTE_POSITION")
            .await;
        let shutter_open = locked_client
            .get_switch(&device_name, "DOME_SHUTTER", "SHUTTER_OPEN")
            .await;
        let shutter_close = locked_client
            .get_switch(&device_name, "DOME_SHUTTER", "SHUTTER_CLOSE")
            .await;
        let shutter_busy = locked_client
            .is_property_busy(&device_name, "DOME_SHUTTER")
            .await;
        let shutter_status = match (shutter_open, shutter_close, shutter_busy) {
            (Some(true), Some(false), true) => Some(ShutterStatus::Opening),
            (Some(false), Some(true), true) => Some(ShutterStatus::Closing),
            (Some(true), Some(false), false) => Some(ShutterStatus::Open),
            (Some(false), Some(true), false) => Some(ShutterStatus::Closed),
            _ => None,
        };
        let at_home = locked_client
            .get_switch(&device_name, "DOME_GOTO", "DOME_HOME")
            .await
            .unwrap_or(false);
        let at_park = locked_client
            .get_switch(&device_name, "DOME_PARK", "PARK")
            .await
            .unwrap_or(false)
            || locked_client
                .get_switch(&device_name, "DOME_GOTO", "DOME_PARK")
                .await
                .unwrap_or(false);
        let slewing = locked_client
            .is_property_busy(&device_name, "ABS_DOME_POSITION")
            .await
            || shutter_busy;
        let slaved = locked_client
            .get_switch(&device_name, "DOME_AUTOSYNC", "DOME_AUTOSYNC_ENABLE")
            .await
            .unwrap_or(false);
        drop(locked_client);

        Ok(DeviceCapabilities::Dome(DomeCapabilities {
            can_set_azimuth,
            can_park,
            can_find_home,
            can_set_shutter,
            // INDI has no standard sync-azimuth property (unlike ASCOM SyncToAzimuth).
            can_sync_azimuth: false,
            azimuth,
            slewing,
            at_home,
            at_park,
            shutter_status,
            can_slave,
            slaved,
            can_abort,
        }))
    } else {
        // Unknown device type - return minimal capabilities
        Err(SkotiqError::not_supported(
            device_id,
            "Could not determine INDI device type from properties",
        ))
    }
}
