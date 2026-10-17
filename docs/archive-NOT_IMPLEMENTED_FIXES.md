> **ARCHIVED 2026-06-09** — this document is stale. A full audit of the native device layer (mount/focuser/filter-wheel/rotator/dome/weather/safety/camera ops × ASCOM/Alpaca/INDI/Native/Simulator) found all imaging-critical operations implemented; no "Not implemented for driver type" stubs remain on the production path.

# Fix Summary: "Not Implemented for Driver Type" Errors

## Status: 2 of 40+ Fixed

### COMPLETED:
1. ✅ `mount_slew` - Added INDI, Alpaca, and Simulator support
2. ✅ `mount_move_axis` - Added INDI (with directional mapping), Alpaca, Native graceful error, and Simulator support

### TO FIX:

## Mount Operations (10 functions)

### 3. mount_sync (Line ~2034)
**Add after Native case:**
```rust
DriverType::Alpaca => {
    let mounts = self.alpaca_mounts.read().await;
    if let Some(mount) = mounts.get(device_id) {
        return mount.sync_to_coordinates(ra, dec).await;
    }
    Err(format!("Alpaca mount {} not connected", device_id))
}
DriverType::Indi => {
    let parts: Vec<&str> = device_id.split(':').collect();
    if parts.len() >= 4 {
        let server_key = format!("{}:{}", parts[1], parts[2]);
        let device_name = parts[3..].join(":");
        let clients = self.indi_clients.read().await;
        if let Some(client) = clients.get(&server_key) {
            let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
            return mount.sync_to_coordinates(ra, dec).await;
        }
        return Err(format!("INDI client not connected for {}", server_key));
    }
    Err(format!("Invalid INDI device ID format: {}", device_id))
}
DriverType::Simulator => {
    tracing::info!("mount_sync: Simulator syncing to RA={}, Dec={}", ra, dec);
    Ok(())
}
```

### 4. mount_park (Line ~2068)
Check if Alpaca/INDI have park methods, add similar pattern.
Alpaca: `mount.park().await`
INDI: Check if IndiMount has park method

### 5. mount_unpark (Line ~2096)
Same as park

### 6. mount_get_coordinates (Line ~2124)
Alpaca: `mount.right_ascension().await` and `mount.declination().await`
INDI: `mount.get_coordinates().await`

### 7. mount_abort (Line ~2152)
Alpaca: `mount.abort_slew().await`
INDI: `mount.abort_slew().await` or similar

### 8. mount_set_tracking (Line ~2180)
Alpaca: `mount.set_tracking(enabled).await`
INDI: Check INDI mount API

### 9. mount_pulse_guide (Line ~2208)
Alpaca: `mount.pulse_guide(axis, duration_ms).await`
INDI: Check if supported

### 10. mount_get_status (Line ~2244)
Build MountStatus from Alpaca/INDI properties

### 11. mount_set_tracking_rate (Line ~2337)
ASCOM only - add graceful errors for others

### 12. mount_get_tracking_rate (Line ~2358)
ASCOM only - add graceful errors for others

## Focuser Operations (7 functions)

### 13-19. focuser_move_abs, focuser_move_rel, focuser_halt, focuser_get_position, focuser_is_moving, focuser_get_temp, focuser_get_details
**Pattern:** Check if Alpaca/INDI focuser APIs exist
- Alpaca: Already has AlpacaFocuser type - add to self.alpaca_focusers HashMap
- INDI: Check if IndiFocuser exists in indi crate

## Filter Wheel Operations (4 functions)

### 20-22. filter_wheel_move, filter_wheel_get_position, filter_wheel_is_moving
Already partially implemented for INDI and Alpaca - just need to replace remaining "Not implemented"

### 23. filter_wheel_get_config (Line ~2718)
Already has INDI and Alpaca - just fix catch-all

## Rotator Operations (4 functions)

### 24-27. rotator_get_position, rotator_move_absolute, rotator_halt, rotator_is_moving
Already has Alpaca and INDI - just need to replace "Not implemented" catch-alls

## Dome Operations (8 functions)

### 28-35. dome_open_shutter, dome_close_shutter, dome_slew_to_azimuth, dome_get_azimuth, dome_get_shutter_status, dome_park, dome_is_slewing, dome_get_status
Already has Alpaca and INDI - replace "Not implemented" with proper fallbacks

## Weather Operations (1 function)

### 36. weather_get_conditions
Already has Alpaca and INDI - fix catch-all

## Safety Monitor (1 function)

### 37. safety_monitor_is_safe
Has Alpaca - add graceful fallback for others

## Camera Operations (1 function - cooler)

### 38. camera_set_cooler (Line ~1948)
Already has all driver types - just replace catch-all with:
```rust
DriverType::Alpaca | DriverType::Indi => {
    // Already handled above
    Ok(())
}
```

## CRITICAL PATTERNS:

### For INDI Mount Operations:
```rust
DriverType::Indi => {
    let parts: Vec<&str> = device_id.split(':').collect();
    if parts.len() >= 4 {
        let server_key = format!("{}:{}", parts[1], parts[2]);
        let device_name = parts[3..].join(":");
        let clients = self.indi_clients.read().await;
        if let Some(client) = clients.get(&server_key) {
            let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
            return mount.METHOD_NAME().await;
        }
        return Err(format!("INDI client not connected for {}", server_key));
    }
    Err(format!("Invalid INDI device ID format: {}", device_id))
}
```

### For Alpaca Mount Operations:
```rust
DriverType::Alpaca => {
    let mounts = self.alpaca_mounts.read().await;
    if let Some(mount) = mounts.get(device_id) {
        return mount.METHOD_NAME().await;
    }
    Err(format!("Alpaca mount {} not connected", device_id))
}
```

### For Graceful Fallbacks:
```rust
DriverType::Simulator => {
    tracing::info!("FUNCTION_NAME: Simulator - operation accepted");
    Ok(DEFAULT_VALUE)
}
DriverType::Native => {
    tracing::warn!("FUNCTION_NAME: Native SDK does not support this operation");
    Err("Native SDK does not support this operation".to_string())
}
```

## Next Steps:
1. Apply these fixes systematically going through each function
2. For each function, check the corresponding Alpaca/INDI API to confirm method names
3. Add Simulator support where appropriate
4. Test compilation after each major section
