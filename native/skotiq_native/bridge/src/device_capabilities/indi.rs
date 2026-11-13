use super::*;
use skotiq_indi::names as indi;

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

/// Capabilities of an INDI camera or mount that has no handle, read through
/// its server's shared connection.
pub(crate) async fn get_indi_capabilities(
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
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

    let client = crate::device_manager::get_device_manager()
        .indi_server(&host, port)
        .await
        .map_err(|e| SkotiqError::connection_failed(device_id, e.to_string()))?;
    indi_capabilities(&client, &device_name, device_id).await
}

/// What the INDI camera or mount `device_name` supports, from the property
/// definitions its server published on `client`.
pub(crate) async fn indi_capabilities(
    client: &Arc<tokio::sync::RwLock<skotiq_indi::IndiClient>>,
    device_name: &str,
    device_id: &str,
) -> Result<DeviceCapabilities, SkotiqError> {
    use skotiq_device::DeviceKind;
    use skotiq_indi::IndiCamera;

    // INDI servers publish capability-bearing property definitions
    // asynchronously after connect; reuse an existing populated client when
    // present, otherwise wait briefly for the newly pooled client to hydrate.
    let start = std::time::Instant::now();
    let description = loop {
        let description = client.read().await.describe_device(&device_name).await;
        if !description.properties.is_empty()
            || start.elapsed() >= std::time::Duration::from_secs(1)
        {
            break description;
        }
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    };
    let kind = description.kind();
    let properties = description.properties;

    // Build capabilities based on discovered properties
    if kind == Some(DeviceKind::Camera) {
        let can_abort = properties
            .iter()
            .any(|p| p.name == indi::CCD_ABORT_EXPOSURE);
        let has_cooler = properties
            .iter()
            .any(|p| p.name == indi::CCD_COOLER || p.name == indi::CCD_TEMPERATURE);
        let has_binning = properties.iter().any(|p| p.name == indi::CCD_BINNING);
        let has_subframe = properties.iter().any(|p| p.name == indi::CCD_FRAME);
        let has_gain = properties
            .iter()
            .any(|p| p.name == indi::CCD_GAIN || p.name == indi::CCD_CONTROLS);
        let has_offset = properties.iter().any(|p| p.name == indi::CCD_OFFSET);

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
                .get_number_limits(
                    &device_name,
                    indi::CCD_TEMPERATURE,
                    indi::CCD_TEMPERATURE_VALUE,
                )
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
    } else if kind == Some(DeviceKind::Mount) {
        let has_equatorial = properties.iter().any(|p| p.name.starts_with("EQUATORIAL_"));
        let supports_alt_az = properties.iter().any(|p| p.name == indi::HORIZONTAL_COORD);
        let can_park = properties.iter().any(|p| p.name == indi::TELESCOPE_PARK);
        let can_sync = properties.iter().any(|p| p.name == indi::ON_COORD_SET);
        let can_guide = properties
            .iter()
            .any(|p| p.name.starts_with("TELESCOPE_TIMED_GUIDE_"));
        let can_track = properties
            .iter()
            .any(|p| p.name == indi::TELESCOPE_TRACK_STATE);
        let can_get_side_of_pier = properties
            .iter()
            .any(|p| p.name == indi::TELESCOPE_PIER_SIDE);
        let can_set_tracking_rate = properties
            .iter()
            .any(|p| p.name == indi::TELESCOPE_TRACK_RATE || p.name == indi::TELESCOPE_TRACK_MODE);
        let mut supported_tracking_rates = Vec::new();
        if properties
            .iter()
            .any(|p| p.name == indi::TELESCOPE_TRACK_MODE)
        {
            supported_tracking_rates.extend([
                TrackingRate::Sidereal,
                TrackingRate::Lunar,
                TrackingRate::Solar,
                TrackingRate::King,
            ]);
        }
        let can_move_ns = properties
            .iter()
            .any(|p| p.name == indi::TELESCOPE_MOTION_NS);
        let can_move_we = properties
            .iter()
            .any(|p| p.name == indi::TELESCOPE_MOTION_WE);
        let max_slew_rate = if let Some(slew_rate) = properties
            .iter()
            .find(|p| p.name == indi::TELESCOPE_SLEW_RATE)
        {
            let locked_client = client.read().await;
            let mut max_rate: Option<f64> = None;
            for element in &slew_rate.elements {
                if let Some(max) = locked_client
                    .get_number_limits(&device_name, indi::TELESCOPE_SLEW_RATE, element)
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
            const TIMED_GUIDE_PROPS: [&str; 2] = [
                indi::TELESCOPE_TIMED_GUIDE_NS,
                indi::TELESCOPE_TIMED_GUIDE_WE,
            ];
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
                p.name == indi::TELESCOPE_PARK_OPTION
                    && p.elements.iter().any(|e| e == indi::PARK_CURRENT)
            }),
            can_pulse_guide: can_guide,
            can_get_side_of_pier,
            can_set_tracking: can_track,
            can_set_tracking_rate,
            supported_tracking_rates,
            is_equatorial: has_equatorial,
            supports_alt_az,
            can_find_home: properties.iter().any(|p| p.name == indi::TELESCOPE_HOME),
            can_abort_slew: properties
                .iter()
                .any(|p| p.name == indi::TELESCOPE_ABORT_MOTION),
            max_slew_rate,
            can_move_axis: can_move_ns || can_move_we,
            axis_count: u32::from(can_move_ns) + u32::from(can_move_we),
            min_pulse_guide_ms,
            max_pulse_guide_ms,
            ..Default::default()
        }))
    } else {
        // A focuser, wheel, rotator or dome answers through its handle once
        // connected (`read_capabilities`); an id that reaches here was never
        // registered.
        Err(SkotiqError::not_supported(
            device_id,
            "Could not determine INDI device type from properties",
        ))
    }
}
