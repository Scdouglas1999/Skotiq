use super::*;

/// Telescope pointing sampled from the mount at save time, for the FITS
/// `RA`/`DEC`/`OBJCTRA`/`OBJCTDEC` (and, via the altitude, `AIRMASS`) cards.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MountPointing {
    /// Right ascension the mount reports it is on, in hours.
    pub ra_hours: f64,
    /// Declination the mount reports it is on, in degrees.
    pub dec_degrees: f64,
    /// Altitude above the horizon in degrees. `None` when the observer
    /// location is unknown, in which case the writer omits `AIRMASS`.
    pub altitude_deg: Option<f64>,
}

/// Altitude above the horizon of `ra_hours`/`dec_degrees` as seen from
/// `lat`/`lon` at `when`.
///
/// Free-standing (and taking an explicit instant) so the AIRMASS fallback below
/// is testable without a clock or a device: the trait method
/// `UnifiedDeviceOps::calculate_altitude` is this function at `Utc::now()`.
pub(crate) fn altitude_degrees(
    ra_hours: f64,
    dec_degrees: f64,
    lat: f64,
    lon: f64,
    when: chrono::DateTime<chrono::Utc>,
) -> f64 {
    let lst = local_sidereal_time(julian_day(&when), lon);
    let ha_rad = ((lst - ra_hours) * 15.0_f64).to_radians();
    let dec_rad = dec_degrees.to_radians();
    let lat_rad = lat.to_radians();
    let sin_alt = lat_rad.sin() * dec_rad.sin() + lat_rad.cos() * dec_rad.cos() * ha_rad.cos();
    sin_alt.asin().to_degrees()
}

/// Fill in the altitude for a frame whose context already carries the mount's
/// coordinates but not the geometry derived from them.
///
/// Why this exists: the sequencer only derives alt/az when its own
/// `ExecutionContext` was seeded with a site, while the FITS writer's site comes
/// from app settings. A run started before the location reached the executor —
/// or a standalone burst that never carried one — therefore has pointing but no
/// altitude, and AIRMASS silently disappears from the header even though the app
/// knows exactly where the observer is. AIRMASS is not cosmetic: extinction
/// correction in any photometry workflow needs it, and it cannot be recovered
/// later from a file that never recorded the site.
///
/// This is NOT a second mount read. The coordinates are the context's own — only
/// the derived altitude is added — so the header and the `captured_images` row
/// still describe one instant.
///
/// `None` when there is nothing to add: the context already has the altitude, it
/// has no pointing to derive one from, or no site is configured anywhere (in
/// which case the writer omits AIRMASS rather than computing it from a guess).
pub(crate) fn context_altitude_pointing(
    frame_ctx: &skotiq_sequencer::scheduling::FrameContext,
    observer: Option<(f64, f64)>,
    when: chrono::DateTime<chrono::Utc>,
) -> Option<MountPointing> {
    if frame_ctx.mount_altitude_deg.is_some() {
        return None;
    }
    let (ra_hours, dec_degrees) = frame_ctx.mount_ra_hours.zip(frame_ctx.mount_dec_degrees)?;
    let (lat, lon) = observer?;
    Some(MountPointing {
        ra_hours,
        dec_degrees,
        altitude_deg: Some(altitude_degrees(ra_hours, dec_degrees, lat, lon, when)),
    })
}

/// The label the app already knows a connected camera by, for FITS `INSTRUME`.
///
/// Prefers `display_name` over `name` because `display_name` is
/// `"<name> (<serial>)"` whenever the driver reports a serial, and on a rig
/// carrying two of the same model the serial is the only part of the string
/// that tells the frames apart. Falls back to `name`, and to `None` when the
/// id names nothing connected — the writer then omits the keyword.
///
/// Only the DRIVER's answer is used. Nothing here derives an instrument from
/// the device id: `native:zwo:1` is an enumeration index that re-orders across
/// a replug, so stamping it into an archival keyword would label frames with
/// something that means a different camera tomorrow.
pub(crate) async fn connected_camera_label(camera_id: &str) -> Option<String> {
    api_get_connected_devices()
        .await
        .into_iter()
        .find(|d| d.id == camera_id && d.device_type == DeviceType::Camera)
        .and_then(|d| {
            let display = d.display_name.trim();
            let label = if display.is_empty() {
                d.name.trim()
            } else {
                display
            };
            if label.is_empty() {
                None
            } else {
                Some(label.to_string())
            }
        })
}
