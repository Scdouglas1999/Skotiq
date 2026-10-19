//! INDI Mount wrapper
//!
//! Provides high-level telescope mount control via INDI protocol.

use crate::client::IndiClient;
use crate::error::{IndiError, IndiResult};
use crate::protocol::coord_elements::*;
use crate::protocol::standard_properties::*;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;

/// INDI equatorial coordinate property used for reads, writes, and slew-busy detection.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EquatorialCoordProperty {
    J2000,
    OfDate,
}

impl EquatorialCoordProperty {
    fn as_str(self) -> &'static str {
        match self {
            Self::J2000 => EQUATORIAL_COORD,
            Self::OfDate => EQUATORIAL_EOD_COORD,
        }
    }
}

/// Pick the equatorial coordinate vector for reads, writes, and slew-busy checks.
///
/// INDI standard GOTO/sync examples use `EQUATORIAL_EOD_COORD` when present; J2000 is
/// used only when the driver does not define the of-date vector (audit ND-).
fn resolve_equatorial_coord_property(has_eod: bool, has_j2000: bool) -> EquatorialCoordProperty {
    if has_eod {
        EquatorialCoordProperty::OfDate
    } else if has_j2000 {
        EquatorialCoordProperty::J2000
    } else {
        EquatorialCoordProperty::OfDate
    }
}

/// Timed pulse-guide direction (INDI `TELESCOPE_TIMED_GUIDE_*`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IndiMountGuideDirection {
    North,
    South,
    East,
    West,
}

/// INDI Mount device wrapper
pub struct IndiMount {
    client: Arc<RwLock<IndiClient>>,
    device_name: String,
    /// Resolved on first coordinate operation; matches the property the driver exposes.
    equatorial_coord_property: RwLock<Option<EquatorialCoordProperty>>,
}

impl IndiMount {
    async fn current_on_coord_set_mode(
        client: &IndiClient,
        device_name: &str,
    ) -> Option<&'static str> {
        let slew = client.get_switch(device_name, ON_COORD_SET, "SLEW").await;
        let sync = client.get_switch(device_name, ON_COORD_SET, "SYNC").await;
        let track = client.get_switch(device_name, ON_COORD_SET, "TRACK").await;

        if slew == Some(true) {
            Some("SLEW")
        } else if sync == Some(true) {
            Some("SYNC")
        } else if track.is_some() {
            Some("TRACK")
        } else {
            None
        }
    }

    async fn restore_on_coord_set_mode(
        client: &mut IndiClient,
        device_name: &str,
        previous_mode: Option<&'static str>,
    ) {
        if let Some(mode) = previous_mode {
            if let Err(error) = client
                .set_switch(device_name, ON_COORD_SET, mode, true)
                .await
            {
                tracing::warn!(
                    "Failed to restore ON_COORD_SET mode '{}' for {} after slew error: {}",
                    mode,
                    device_name,
                    error
                );
            }
        }
    }

    /// Create a new INDI mount wrapper
    pub fn new(client: Arc<RwLock<IndiClient>>, device_name: &str) -> Self {
        Self {
            client,
            device_name: device_name.to_string(),
            equatorial_coord_property: RwLock::new(None),
        }
    }

    async fn detect_equatorial_coord_property(
        client: &IndiClient,
        device_name: &str,
    ) -> (EquatorialCoordProperty, bool) {
        let has_eod = client
            .get_property_state(device_name, EQUATORIAL_EOD_COORD)
            .await
            .is_some();
        let has_j2000 = client
            .get_property_state(device_name, EQUATORIAL_COORD)
            .await
            .is_some();
        let prop = resolve_equatorial_coord_property(has_eod, has_j2000);
        (prop, has_eod || has_j2000)
    }

    /// Detect which equatorial coordinate vector this mount uses (J2000 vs of-date).
    ///
    /// Resolved via `get_property_state` on connect and on first use; reads, slews, syncs,
    /// and slew-busy checks all use the same property (audit ND-).
    async fn equatorial_coord_property(&self) -> EquatorialCoordProperty {
        if let Some(prop) = *self.equatorial_coord_property.read().await {
            return prop;
        }

        let client = self.client.read().await;
        let (prop, resolved) =
            Self::detect_equatorial_coord_property(&client, &self.device_name).await;
        if resolved {
            *self.equatorial_coord_property.write().await = Some(prop);
        }
        prop
    }

    /// Re-detect equatorial coordinate property after connect or property discovery.
    async fn refresh_equatorial_coord_property(&self) {
        let client = self.client.read().await;
        let (prop, resolved) =
            Self::detect_equatorial_coord_property(&client, &self.device_name).await;
        let mut cache = self.equatorial_coord_property.write().await;
        if resolved {
            *cache = Some(prop);
        } else {
            *cache = None;
        }
    }

    /// Get the device name
    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    /// Connect to the mount
    pub async fn connect(&self) -> IndiResult<()> {
        {
            let mut client = self.client.write().await;
            client.connect_device(&self.device_name).await?;
        }
        self.refresh_equatorial_coord_property().await;
        Ok(())
    }

    /// Disconnect from the mount
    pub async fn disconnect(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        let result = client.disconnect_device(&self.device_name).await;
        *self.equatorial_coord_property.write().await = None;
        result
    }

    /// Check if connected
    pub async fn is_connected(&self) -> bool {
        let client = self.client.read().await;
        client.is_device_connected(&self.device_name).await
    }

    /// Get current coordinates (RA in hours, Dec in degrees)
    pub async fn get_coordinates(&self) -> Result<(f64, f64), String> {
        let coord = self.equatorial_coord_property().await;
        let client = self.client.read().await;
        let prop = coord.as_str();

        let ra = client
            .get_number(&self.device_name, prop, RA)
            .await
            .ok_or_else(|| format!("RA not available on {}", prop))?;

        let dec = client
            .get_number(&self.device_name, prop, DEC)
            .await
            .ok_or_else(|| format!("Dec not available on {}", prop))?;

        Ok((ra, dec))
    }

    /// Slew to coordinates (RA in hours, Dec in degrees)
    ///
    /// Returns once the driver has answered the goto, not merely once it was
    /// sent: see [`Self::wait_for_goto_answer`].
    pub async fn slew_to_coordinates(&self, ra_hours: f64, dec_degrees: f64) -> IndiResult<()> {
        let coord = self.equatorial_coord_property().await;
        let mut client = self.client.write().await;
        let previous_mode = Self::current_on_coord_set_mode(&client, &self.device_name).await;
        let updated_before = client
            .get_property_last_update_ms(&self.device_name, coord.as_str())
            .await;
        let answer_timeout =
            Duration::from_secs(client.timeout_config().property_timeout_secs.max(1));

        // Set coordinate mode to SLEW
        client
            .set_switch(&self.device_name, ON_COORD_SET, "SLEW", true)
            .await?;

        // Set target coordinates
        if let Err(error) = client
            .set_numbers(
                &self.device_name,
                coord.as_str(),
                &[(RA, ra_hours), (DEC, dec_degrees)],
            )
            .await
        {
            Self::restore_on_coord_set_mode(&mut client, &self.device_name, previous_mode).await;
            return Err(error);
        }
        drop(client);

        self.wait_for_goto_answer(
            coord,
            updated_before,
            (ra_hours, dec_degrees),
            answer_timeout,
        )
        .await
    }

    /// Wait for the driver's answer to a goto.
    ///
    /// Sending the target only queues it; the cached coordinate state still
    /// says Ok at the old position until the driver's Busy comes back. The
    /// sequencer polls `is_slewing` the moment the goto returns and takes the
    /// first "not slewing" as arrival, so a goto that returned on send read as
    /// a slew that had already ended where it started, and was then failed as
    /// a position mismatch while the mount was still moving.
    ///
    /// Busy is the answer. Alert is the driver refusing the goto (a limit, a
    /// parked mount) and is returned as an error. An Ok update already at the
    /// target is a goto to where the mount is. Anything else — the periodic
    /// position updates a tracking mount sends — is not the answer. A driver
    /// that never answers within `timeout` is logged and let through, which is
    /// what this did before.
    async fn wait_for_goto_answer(
        &self,
        coord: EquatorialCoordProperty,
        updated_before: Option<u64>,
        (ra_hours, dec_degrees): (f64, f64),
        timeout: Duration,
    ) -> IndiResult<()> {
        const AT_TARGET_DEG: f64 = 1.0 / 60.0;
        let prop = coord.as_str();
        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            {
                let client = self.client.read().await;
                let updated = client
                    .get_property_last_update_ms(&self.device_name, prop)
                    .await;
                if updated > updated_before {
                    match client.get_property_state(&self.device_name, prop).await {
                        Some(crate::IndiPropertyState::Busy) => return Ok(()),
                        Some(crate::IndiPropertyState::Alert) => {
                            return Err(IndiError::DeviceAlert(format!(
                                "{} refused the goto to RA {:.4}h, Dec {:.4} deg ({} went to Alert)",
                                self.device_name, ra_hours, dec_degrees, prop
                            )));
                        }
                        _ => {
                            let ra = client.get_number(&self.device_name, prop, RA).await;
                            let dec = client.get_number(&self.device_name, prop, DEC).await;
                            if let (Some(ra), Some(dec)) = (ra, dec) {
                                let mut ra_diff_h = (ra - ra_hours) % 24.0;
                                if ra_diff_h > 12.0 {
                                    ra_diff_h -= 24.0;
                                } else if ra_diff_h < -12.0 {
                                    ra_diff_h += 24.0;
                                }
                                if (ra_diff_h * 15.0).abs() <= AT_TARGET_DEG
                                    && (dec - dec_degrees).abs() <= AT_TARGET_DEG
                                {
                                    return Ok(());
                                }
                            }
                        }
                    }
                }
            }
            if tokio::time::Instant::now() >= deadline {
                tracing::warn!(
                    "{} did not answer the goto within {:?}; slew completion may read the old \
                     position",
                    self.device_name,
                    timeout
                );
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }

    /// Slew to coordinates with timeout (RA in hours, Dec in degrees)
    pub async fn slew_to_coordinates_with_timeout(
        &self,
        ra_hours: f64,
        dec_degrees: f64,
        timeout: Option<Duration>,
    ) -> Result<(), String> {
        // Read config outside the closure - async-friendly
        let timeout_duration = if let Some(t) = timeout {
            t
        } else {
            let client = self.client.read().await;
            Duration::from_secs(client.timeout_config().mount_slew_timeout_secs)
        };

        let coord = self.equatorial_coord_property().await;
        let coord_prop = coord.as_str();

        // Start the slew
        {
            let mut client = self.client.write().await;
            let previous_mode = Self::current_on_coord_set_mode(&client, &self.device_name).await;
            client
                .set_switch(&self.device_name, ON_COORD_SET, "SLEW", true)
                .await?;
            if let Err(error) = client
                .set_numbers(
                    &self.device_name,
                    coord_prop,
                    &[(RA, ra_hours), (DEC, dec_degrees)],
                )
                .await
            {
                Self::restore_on_coord_set_mode(&mut client, &self.device_name, previous_mode)
                    .await;
                return Err(error.to_string());
            }
        }

        // Wait for slew to complete
        let client = self.client.read().await;
        client
            .wait_for_property_not_busy(&self.device_name, coord_prop, timeout_duration)
            .await
            .map_err(|e| {
                format!(
                    "Mount slew to RA={:.4}h, Dec={:.4}° failed: {}",
                    ra_hours, dec_degrees, e
                )
            })
    }

    /// Sync to coordinates (RA in hours, Dec in degrees)
    pub async fn sync_to_coordinates(&self, ra_hours: f64, dec_degrees: f64) -> IndiResult<()> {
        let coord = self.equatorial_coord_property().await;
        let mut client = self.client.write().await;

        // Set coordinate mode to SYNC
        client
            .set_switch(&self.device_name, ON_COORD_SET, "SYNC", true)
            .await?;

        // Set target coordinates
        client
            .set_numbers(
                &self.device_name,
                coord.as_str(),
                &[(RA, ra_hours), (DEC, dec_degrees)],
            )
            .await
    }

    /// Abort slew
    pub async fn abort_slew(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, TELESCOPE_ABORT_MOTION, "ABORT", true)
            .await
    }

    /// Park the mount
    pub async fn park(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, TELESCOPE_PARK, "PARK", true)
            .await
    }

    /// Unpark the mount
    pub async fn unpark(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, TELESCOPE_PARK, "UNPARK", true)
            .await
    }

    /// Check if parked.
    ///
    /// Returns:
    /// * `Ok(true)` — `TELESCOPE_PARK/PARK` is `On`.
    /// * `Ok(false)` — the property is defined but `PARK` is `Off`.
    /// * `Err(IndiError::PropertyNotFound)` — the driver has not (yet)
    ///   defined `TELESCOPE_PARK`. The UI must surface "unknown" rather than
    ///   "not parked"; a disconnected mount should never look
    ///   like "alive but stationary".
    pub async fn try_is_parked(&self) -> Result<bool, IndiError> {
        let client = self.client.read().await;
        match client
            .get_switch(&self.device_name, TELESCOPE_PARK, "PARK")
            .await
        {
            Some(v) => Ok(v),
            None => Err(IndiError::PropertyNotFound {
                device: self.device_name.clone(),
                property: TELESCOPE_PARK.to_string(),
            }),
        }
    }

    /// Set tracking state
    pub async fn set_tracking(&self, enabled: bool) -> IndiResult<()> {
        let mut client = self.client.write().await;
        if enabled {
            client
                .set_switch(&self.device_name, TELESCOPE_TRACK_STATE, "TRACK_ON", true)
                .await
        } else {
            client
                .set_switch(&self.device_name, TELESCOPE_TRACK_STATE, "TRACK_OFF", true)
                .await
        }
    }

    /// Check if tracking.
    ///
    /// Returns:
    /// * `Ok(true)` — `TELESCOPE_TRACK_STATE/TRACK_ON` is `On`.
    /// * `Ok(false)` — the property is defined but `TRACK_ON` is `Off`.
    /// * `Err(IndiError::PropertyNotFound)` — the driver has not (yet)
    ///   defined `TELESCOPE_TRACK_STATE`.
    pub async fn try_is_tracking(&self) -> Result<bool, IndiError> {
        let client = self.client.read().await;
        match client
            .get_switch(&self.device_name, TELESCOPE_TRACK_STATE, "TRACK_ON")
            .await
        {
            Some(v) => Ok(v),
            None => Err(IndiError::PropertyNotFound {
                device: self.device_name.clone(),
                property: TELESCOPE_TRACK_STATE.to_string(),
            }),
        }
    }

    /// Check if slewing.
    ///
    /// Returns:
    /// * `Ok(true)` — the mount's primary equatorial coordinate property is `Busy`.
    /// * `Ok(false)` — the property is defined and not `Busy`.
    /// * `Err(IndiError::PropertyNotFound)` — the property has not been
    ///   defined yet, so the mount may not be initialised. Per
    ///   this is distinct from "definitely not slewing".
    pub async fn try_is_slewing(&self) -> Result<bool, IndiError> {
        let coord = self.equatorial_coord_property().await;
        let prop = coord.as_str();
        let client = self.client.read().await;
        match client.get_property_state(&self.device_name, prop).await {
            // A FindHome is motion too. Drivers report it as TELESCOPE_HOME
            // Busy and need not touch the coordinate vector's state while it
            // runs, so a poller that only watched the coordinates would read
            // the mount as idle the moment the home started.
            Some(state) => Ok(state == crate::IndiPropertyState::Busy
                || client
                    .is_property_busy(&self.device_name, TELESCOPE_HOME)
                    .await),
            None => Err(IndiError::PropertyNotFound {
                device: self.device_name.clone(),
                property: prop.to_string(),
            }),
        }
    }

    /// Move north
    pub async fn move_north(&self, start: bool) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(
                &self.device_name,
                TELESCOPE_MOTION_NS,
                "MOTION_NORTH",
                start,
            )
            .await
    }

    /// Move south
    pub async fn move_south(&self, start: bool) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(
                &self.device_name,
                TELESCOPE_MOTION_NS,
                "MOTION_SOUTH",
                start,
            )
            .await
    }

    /// Move west
    pub async fn move_west(&self, start: bool) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, TELESCOPE_MOTION_WE, "MOTION_WEST", start)
            .await
    }

    /// Move east
    pub async fn move_east(&self, start: bool) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, TELESCOPE_MOTION_WE, "MOTION_EAST", start)
            .await
    }

    /// Pulse-guide for `duration_ms` using standard timed-guide number properties.
    pub async fn pulse_guide(
        &self,
        direction: IndiMountGuideDirection,
        duration_ms: u32,
    ) -> IndiResult<()> {
        let (property, element) = match direction {
            IndiMountGuideDirection::North => (TELESCOPE_TIMED_GUIDE_NS, "TIMED_GUIDE_N"),
            IndiMountGuideDirection::South => (TELESCOPE_TIMED_GUIDE_NS, "TIMED_GUIDE_S"),
            IndiMountGuideDirection::East => (TELESCOPE_TIMED_GUIDE_WE, "TIMED_GUIDE_E"),
            IndiMountGuideDirection::West => (TELESCOPE_TIMED_GUIDE_WE, "TIMED_GUIDE_W"),
        };
        let mut client = self.client.write().await;
        client
            .set_number(&self.device_name, property, element, f64::from(duration_ms))
            .await
    }

    /// Custom tracking rates in arcsec/s (`TELESCOPE_TRACK_RATE`).
    pub async fn set_tracking_rate(&self, ra_rate: f64, dec_rate: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_numbers(
                &self.device_name,
                TELESCOPE_TRACK_RATE,
                &[("TRACK_RATE_RA", ra_rate), ("TRACK_RATE_DE", dec_rate)],
            )
            .await
    }

    /// Select a predefined tracking mode (`TELESCOPE_TRACK_MODE`).
    pub async fn set_track_mode(&self, element: &str) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch_exclusive(&self.device_name, TELESCOPE_TRACK_MODE, element)
            .await
    }

    /// Active pier side element name from `TELESCOPE_PIER_SIDE`, if published.
    pub async fn get_pier_side(&self) -> Option<String> {
        let client = self.client.read().await;
        let prop = client
            .get_property(&self.device_name, TELESCOPE_PIER_SIDE)
            .await?;
        for element in &prop.elements {
            if client
                .get_switch(&self.device_name, TELESCOPE_PIER_SIDE, element)
                .await
                .unwrap_or(false)
            {
                return Some(element.clone());
            }
        }
        None
    }

    /// Set alignment mode when the driver exposes `TELESCOPE_ALIGNMENT_MODE`.
    pub async fn set_alignment_mode(&self, element: &str) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch_exclusive(&self.device_name, TELESCOPE_ALIGNMENT_MODE, element)
            .await
    }

    /// Set slew rate index using driver-advertised `TELESCOPE_SLEW_RATE` element names.
    ///
    /// Prefers standard INDI names (`SLEW_GUIDE`, `SLEW_CENTERING`, `SLEW_FIND`, `SLEW_MAX`)
    /// instead of hard-coded `1x`/`MAX` labels (audit ND-).
    pub async fn set_slew_rate(&self, rate: i32) -> IndiResult<()> {
        let mut client = self.client.write().await;
        let rate_clamped = rate.max(0);

        if let Some(prop) = client
            .get_property(&self.device_name, TELESCOPE_SLEW_RATE)
            .await
        {
            if let Some(element) = pick_slew_rate_element(rate_clamped, &prop.elements) {
                return client
                    .set_switch_exclusive(&self.device_name, TELESCOPE_SLEW_RATE, &element)
                    .await;
            }
        }

        let mode = format!("SLEW{rate_clamped}");
        client
            .set_switch(&self.device_name, "SLEWMODE", &mode, true)
            .await
    }

    /// Slew to horizontal coordinates (Alt/Az)
    ///
    /// INDI mounts that support HORIZONTAL_COORD can be slewed in alt/az mode
    /// by writing to the HORIZONTAL_COORD number property.
    pub async fn slew_to_alt_az(&self, altitude: f64, azimuth: f64) -> IndiResult<()> {
        let mut client = self.client.write().await;

        // Set target horizontal coordinates - the INDI driver handles the
        // coordinate transformation and slew internally
        client
            .set_numbers(
                &self.device_name,
                HORIZONTAL_COORD,
                &[(ALT, altitude), (AZ, azimuth)],
            )
            .await
    }

    /// Find mount home position
    ///
    /// Sets the TELESCOPE_HOME switch to "GO" which commands the mount to
    /// find its home position. Not all INDI mounts support this property.
    pub async fn find_home(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(&self.device_name, TELESCOPE_HOME, "GO", true)
            .await
    }

    /// Whether the driver can store the current position as its park
    /// position: it defines `TELESCOPE_PARK_OPTION.PARK_CURRENT`.
    pub async fn can_set_park(&self) -> bool {
        let client = self.client.read().await;
        client
            .get_switch(&self.device_name, TELESCOPE_PARK_OPTION, "PARK_CURRENT")
            .await
            .is_some()
    }

    /// Store the current position as the park position.
    ///
    /// `PARK_CURRENT` sets the driver's park position in memory; drivers that
    /// also define `PARK_WRITE_DATA` keep it only once it is written to their
    /// park data file, so that is sent too, or the new park position would be
    /// lost when the driver restarts.
    pub async fn set_park_to_current(&self) -> IndiResult<()> {
        let mut client = self.client.write().await;
        client
            .set_switch(
                &self.device_name,
                TELESCOPE_PARK_OPTION,
                "PARK_CURRENT",
                true,
            )
            .await?;
        if client
            .get_switch(&self.device_name, TELESCOPE_PARK_OPTION, "PARK_WRITE_DATA")
            .await
            .is_some()
        {
            client
                .set_switch(
                    &self.device_name,
                    TELESCOPE_PARK_OPTION,
                    "PARK_WRITE_DATA",
                    true,
                )
                .await?;
        }
        Ok(())
    }

    /// Get horizontal coordinates (Altitude, Azimuth)
    pub async fn get_horizontal_coordinates(&self) -> Result<(f64, f64), String> {
        let client = self.client.read().await;
        let alt = client
            .get_number(&self.device_name, HORIZONTAL_COORD, ALT)
            .await
            .ok_or_else(|| "Altitude not available".to_string())?;
        let az = client
            .get_number(&self.device_name, HORIZONTAL_COORD, AZ)
            .await
            .ok_or_else(|| "Azimuth not available".to_string())?;
        Ok((alt, az))
    }
}

/// Map a logical slew-rate index to a driver element name.
fn pick_slew_rate_element(rate: i32, elements: &[String]) -> Option<String> {
    if elements.is_empty() {
        return None;
    }

    let idx = usize::try_from(rate.max(0)).unwrap_or(0);
    const STANDARD: [&str; 4] = ["SLEW_GUIDE", "SLEW_CENTERING", "SLEW_FIND", "SLEW_MAX"];

    if let Some(name) = STANDARD.get(idx) {
        if elements.iter().any(|e| e == name) {
            return Some((*name).to_string());
        }
    }
    for name in STANDARD.iter().skip(idx) {
        if elements.iter().any(|e| e == name) {
            return Some((*name).to_string());
        }
    }

    const LEGACY: [&str; 8] = ["1x", "2x", "4x", "8x", "16x", "32x", "64x", "MAX"];
    if let Some(name) = LEGACY.get(idx) {
        if elements.iter().any(|e| e == name) {
            return Some((*name).to_string());
        }
    }

    elements
        .get(idx)
        .cloned()
        .or_else(|| elements.last().cloned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::IndiClient;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[test]
    fn pick_slew_rate_element_prefers_standard_names() {
        let elements = vec![
            "SLEW_GUIDE".to_string(),
            "SLEW_CENTERING".to_string(),
            "SLEW_FIND".to_string(),
            "SLEW_MAX".to_string(),
        ];
        assert_eq!(
            pick_slew_rate_element(2, &elements).as_deref(),
            Some("SLEW_FIND")
        );
    }

    #[test]
    fn pick_slew_rate_element_falls_back_to_legacy_multiplier_labels() {
        let elements = vec!["1x".to_string(), "4x".to_string(), "MAX".to_string()];
        assert_eq!(pick_slew_rate_element(0, &elements).as_deref(), Some("1x"));
        assert_eq!(pick_slew_rate_element(1, &elements).as_deref(), Some("4x"));
        assert_eq!(pick_slew_rate_element(7, &elements).as_deref(), Some("MAX"));
    }

    #[test]
    fn resolve_equatorial_coord_property_prefers_eod_when_both_defined() {
        assert_eq!(
            resolve_equatorial_coord_property(true, true),
            EquatorialCoordProperty::OfDate
        );
    }

    #[test]
    fn resolve_equatorial_coord_property_uses_j2000_when_only_j2000() {
        assert_eq!(
            resolve_equatorial_coord_property(false, true),
            EquatorialCoordProperty::J2000
        );
    }

    #[test]
    fn resolve_equatorial_coord_property_uses_eod_when_only_eod() {
        assert_eq!(
            resolve_equatorial_coord_property(true, false),
            EquatorialCoordProperty::OfDate
        );
    }

    async fn wait_for_captured_property(
        captured: &Arc<tokio::sync::Mutex<Option<String>>>,
    ) -> String {
        let deadline = tokio::time::Instant::now() + std::time::Duration::from_millis(500);
        loop {
            if let Some(property) = captured.lock().await.clone() {
                return property;
            }
            assert!(
                tokio::time::Instant::now() < deadline,
                "timed out waiting for mount slew newNumberVector"
            );
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
    }

    #[test]
    fn resolve_equatorial_coord_property_defaults_to_eod_when_neither_defined() {
        assert_eq!(
            resolve_equatorial_coord_property(false, false),
            EquatorialCoordProperty::OfDate
        );
    }

    fn extract_new_number_vector_property(request: &str) -> Option<String> {
        let marker = "newNumberVector";
        let start = request.find(marker)?;
        let chunk = &request[start..];
        let name_key = "name=\"";
        let name_start = chunk.find(name_key)? + name_key.len();
        let name_end = chunk[name_start..].find('"')? + name_start;
        Some(chunk[name_start..name_end].to_string())
    }

    async fn mount_from_fake_server(
        payload: impl AsRef<[u8]>,
        wait_property: &str,
    ) -> (
        IndiMount,
        tokio::task::JoinHandle<()>,
        Arc<tokio::sync::Mutex<Option<String>>>,
    ) {
        let slew_property = Arc::new(tokio::sync::Mutex::new(None));
        let captured = slew_property.clone();
        let payload_bytes = payload.as_ref().to_vec();

        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fake INDI mount server");
        let port = listener.local_addr().expect("read listener address").port();

        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept INDI client");
            let mut buf = [0_u8; 8192];
            let mut received = String::new();
            let _ = socket
                .read(&mut buf)
                .await
                .expect("read initial getProperties");
            socket
                .write_all(&payload_bytes)
                .await
                .expect("write fake mount payload");
            loop {
                match socket.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        received.push_str(&String::from_utf8_lossy(&buf[..n]));
                        if let Some(property) = extract_new_number_vector_property(&received) {
                            *captured.lock().await = Some(property);
                        }
                    }
                }
            }
        });

        let timeout_config = crate::IndiTimeoutConfig {
            connection_timeout_secs: 1,
            // This server never answers the goto; don't wait long for it.
            property_timeout_secs: 1,
            ..Default::default()
        };
        let mut client = IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);
        client.connect().await.expect("connect fake INDI client");

        let deadline = tokio::time::Instant::now() + std::time::Duration::from_secs(2);
        while client.get_property("Mount", wait_property).await.is_none() {
            assert!(
                tokio::time::Instant::now() < deadline,
                "fake INDI property {wait_property} was not parsed in time"
            );
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }

        let mount = IndiMount::new(Arc::new(RwLock::new(client)), "Mount");
        (mount, server, slew_property)
    }

    const MOUNT_BASE_PROPERTIES: &str = r#"
<defSwitchVector device="Mount" name="CONNECTION" state="Idle" perm="rw">
  <defSwitch name="CONNECT"/>
  <defSwitch name="DISCONNECT"/>
</defSwitchVector>
<setSwitchVector device="Mount" name="CONNECTION" state="Ok">
  <oneSwitch name="CONNECT">Off</oneSwitch>
  <oneSwitch name="DISCONNECT">On</oneSwitch>
</setSwitchVector>
<defSwitchVector device="Mount" name="ON_COORD_SET" state="Idle" perm="rw">
  <defSwitch name="TRACK"/>
  <defSwitch name="SLEW"/>
  <defSwitch name="SYNC"/>
</defSwitchVector>
<setSwitchVector device="Mount" name="ON_COORD_SET" state="Ok">
  <oneSwitch name="TRACK">On</oneSwitch>
  <oneSwitch name="SLEW">Off</oneSwitch>
  <oneSwitch name="SYNC">Off</oneSwitch>
</setSwitchVector>
"#;

    #[tokio::test]
    async fn slew_writes_j2000_when_driver_only_defines_equatorial_coord() {
        let payload = format!(
            "{MOUNT_BASE_PROPERTIES}
<defNumberVector device=\"Mount\" name=\"EQUATORIAL_COORD\" state=\"Idle\" perm=\"rw\">
  <defNumber name=\"RA\" min=\"0\" max=\"24\">10.0</defNumber>
  <defNumber name=\"DEC\" min=\"-90\" max=\"90\">45.0</defNumber>
</defNumberVector>
"
        );
        let (mount, server, captured) =
            mount_from_fake_server(payload.as_bytes(), EQUATORIAL_COORD).await;

        mount.connect().await.expect("connect mount on fake server");
        mount
            .slew_to_coordinates(11.0, 46.0)
            .await
            .expect("slew on fake server");

        assert_eq!(
            wait_for_captured_property(&captured).await.as_str(),
            EQUATORIAL_COORD
        );

        drop(mount);
        server.await.expect("fake server should finish");
    }

    #[tokio::test]
    async fn slew_writes_eod_when_driver_only_defines_equatorial_eod_coord() {
        let payload = format!(
            "{MOUNT_BASE_PROPERTIES}
<defNumberVector device=\"Mount\" name=\"EQUATORIAL_EOD_COORD\" state=\"Idle\" perm=\"rw\">
  <defNumber name=\"RA\" min=\"0\" max=\"24\">10.0</defNumber>
  <defNumber name=\"DEC\" min=\"-90\" max=\"90\">45.0</defNumber>
</defNumberVector>
"
        );
        let (mount, server, captured) =
            mount_from_fake_server(payload.as_bytes(), EQUATORIAL_EOD_COORD).await;

        mount.connect().await.expect("connect mount on fake server");
        mount
            .slew_to_coordinates(11.0, 46.0)
            .await
            .expect("slew on fake server");

        assert_eq!(
            wait_for_captured_property(&captured).await.as_str(),
            EQUATORIAL_EOD_COORD
        );

        drop(mount);
        server.await.expect("fake server should finish");
    }

    #[tokio::test]
    async fn slew_and_read_use_eod_when_driver_defines_both_coord_vectors() {
        let payload = format!(
            "{MOUNT_BASE_PROPERTIES}
<defNumberVector device=\"Mount\" name=\"EQUATORIAL_COORD\" state=\"Idle\" perm=\"rw\">
  <defNumber name=\"RA\" min=\"0\" max=\"24\">10.0</defNumber>
  <defNumber name=\"DEC\" min=\"-90\" max=\"90\">45.0</defNumber>
</defNumberVector>
<setNumberVector device=\"Mount\" name=\"EQUATORIAL_COORD\" state=\"Ok\">
  <oneNumber name=\"RA\">10.0</oneNumber>
  <oneNumber name=\"DEC\">45.0</oneNumber>
</setNumberVector>
<defNumberVector device=\"Mount\" name=\"EQUATORIAL_EOD_COORD\" state=\"Idle\" perm=\"rw\">
  <defNumber name=\"RA\" min=\"0\" max=\"24\">12.0</defNumber>
  <defNumber name=\"DEC\" min=\"-90\" max=\"90\">50.0</defNumber>
</defNumberVector>
<setNumberVector device=\"Mount\" name=\"EQUATORIAL_EOD_COORD\" state=\"Ok\">
  <oneNumber name=\"RA\">12.0</oneNumber>
  <oneNumber name=\"DEC\">50.0</oneNumber>
</setNumberVector>
"
        );
        let (mount, server, captured) =
            mount_from_fake_server(payload.as_bytes(), EQUATORIAL_EOD_COORD).await;

        mount.connect().await.expect("connect mount on fake server");

        let (ra, dec) = mount
            .get_coordinates()
            .await
            .expect("read coordinates from fake server");
        assert!((ra - 12.0).abs() < f64::EPSILON);
        assert!((dec - 50.0).abs() < f64::EPSILON);

        mount
            .slew_to_coordinates(11.0, 46.0)
            .await
            .expect("slew on fake server");
        assert_eq!(
            wait_for_captured_property(&captured).await.as_str(),
            EQUATORIAL_EOD_COORD
        );

        drop(mount);
        server.await.expect("fake server should finish");
    }

    /// A fake server that answers the goto the way a real driver does: some
    /// time after the command arrives, with `reply` (a set*Vector).
    async fn mount_with_delayed_goto_reply(
        reply: String,
        reply_delay: Duration,
    ) -> (IndiMount, tokio::task::JoinHandle<()>) {
        let payload = format!(
            "{MOUNT_BASE_PROPERTIES}
<defNumberVector device=\"Mount\" name=\"EQUATORIAL_EOD_COORD\" state=\"Idle\" perm=\"rw\">
  <defNumber name=\"RA\" min=\"0\" max=\"24\">10.0</defNumber>
  <defNumber name=\"DEC\" min=\"-90\" max=\"90\">45.0</defNumber>
</defNumberVector>
<setNumberVector device=\"Mount\" name=\"EQUATORIAL_EOD_COORD\" state=\"Ok\">
  <oneNumber name=\"RA\">10.0</oneNumber>
  <oneNumber name=\"DEC\">45.0</oneNumber>
</setNumberVector>
"
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind fake INDI mount server");
        let port = listener.local_addr().expect("read listener address").port();
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept INDI client");
            let mut buf = [0_u8; 8192];
            let _ = socket.read(&mut buf).await;
            socket
                .write_all(payload.as_bytes())
                .await
                .expect("write fake mount payload");
            let mut received = String::new();
            let mut replied = false;
            loop {
                match socket.read(&mut buf).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        received.push_str(&String::from_utf8_lossy(&buf[..n]));
                        if !replied && received.contains("newNumberVector") {
                            replied = true;
                            tokio::time::sleep(reply_delay).await;
                            let _ = socket.write_all(reply.as_bytes()).await;
                        }
                    }
                }
            }
        });

        let timeout_config = crate::IndiTimeoutConfig {
            connection_timeout_secs: 1,
            ..Default::default()
        };
        let mut client = IndiClient::with_timeout_config("127.0.0.1", Some(port), timeout_config);
        client.connect().await.expect("connect fake INDI client");
        let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
        while client
            .get_property("Mount", EQUATORIAL_EOD_COORD)
            .await
            .is_none()
        {
            assert!(tokio::time::Instant::now() < deadline);
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        (
            IndiMount::new(Arc::new(RwLock::new(client)), "Mount"),
            server,
        )
    }

    /// The sequencer polls `is_slewing` the moment the goto call returns and
    /// takes the first "not slewing" as arrival. A goto that returns before
    /// the driver has said Busy therefore reads as a slew that already ended,
    /// at the old coordinates.
    #[tokio::test]
    async fn a_goto_returns_only_once_the_driver_reports_the_slew() {
        let (mount, server) = mount_with_delayed_goto_reply(
            "<setNumberVector device=\"Mount\" name=\"EQUATORIAL_EOD_COORD\" state=\"Busy\">\
               <oneNumber name=\"RA\">10.2</oneNumber>\
               <oneNumber name=\"DEC\">45.3</oneNumber>\
             </setNumberVector>"
                .to_string(),
            Duration::from_millis(300),
        )
        .await;
        mount.connect().await.expect("connect mount on fake server");

        mount
            .slew_to_coordinates(11.0, 46.0)
            .await
            .expect("slew on fake server");

        assert!(
            mount.try_is_slewing().await.expect("coordinate state"),
            "the goto returned while the mount still read as idle at its old position"
        );

        drop(mount);
        server.abort();
    }

    /// A driver that refuses a goto (below a limit, parked) answers Alert.
    /// That is the slew failing, and must be reported as such rather than as
    /// a slew that finished somewhere unexpected.
    #[tokio::test]
    async fn a_goto_the_driver_refuses_is_an_error() {
        let (mount, server) = mount_with_delayed_goto_reply(
            "<setNumberVector device=\"Mount\" name=\"EQUATORIAL_EOD_COORD\" state=\"Alert\" \
               message=\"Target is below the horizon limit\">\
               <oneNumber name=\"RA\">10.0</oneNumber>\
               <oneNumber name=\"DEC\">45.0</oneNumber>\
             </setNumberVector>"
                .to_string(),
            Duration::from_millis(100),
        )
        .await;
        mount.connect().await.expect("connect mount on fake server");

        let result = mount.slew_to_coordinates(11.0, 46.0).await;
        assert!(result.is_err(), "a refused goto returned {:?}", result);

        drop(mount);
        server.abort();
    }

    #[tokio::test]
    async fn test_mount_creation() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let mount = IndiMount::new(client, "TestMount");
        assert_eq!(mount.device_name(), "TestMount");
    }

    #[tokio::test]
    async fn test_slew_with_timeout_error_message() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let mount = IndiMount::new(client, "TestMount");

        // This will fail since we're not connected
        let result = mount
            .slew_to_coordinates_with_timeout(10.5, 45.0, Some(Duration::from_millis(100)))
            .await;

        assert!(result.is_err());
        if let Err(e) = result {
            // Error should mention either the coordinates or that we're not connected
            assert!(e.contains("RA=10.5") || e.to_lowercase().contains("not connected"));
        }
    }

    #[tokio::test]
    async fn test_mount_timeout_uses_config() {
        let config = crate::IndiTimeoutConfig {
            mount_slew_timeout_secs: 600, // Custom timeout
            ..Default::default()
        };

        let client = Arc::new(RwLock::new(IndiClient::with_timeout_config(
            "localhost",
            Some(7624),
            config,
        )));
        let _mount = IndiMount::new(client.clone(), "TestMount");

        // Verify the timeout config is accessible
        let timeout_secs = {
            let c = client.read().await;
            c.timeout_config().mount_slew_timeout_secs
        };
        assert_eq!(timeout_secs, 600);
    }

    /// When TELESCOPE_PARK is undefined, try_is_parked must return
    /// PropertyNotFound (not Ok(false)) so the UI can render "unknown".
    #[tokio::test]
    async fn try_is_parked_errors_when_undefined() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let mount = IndiMount::new(client, "TestMount");
        let result = mount.try_is_parked().await;
        assert!(matches!(result, Err(IndiError::PropertyNotFound { .. })));
    }

    /// Same contract for try_is_tracking.
    #[tokio::test]
    async fn try_is_tracking_errors_when_undefined() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let mount = IndiMount::new(client, "TestMount");
        let result = mount.try_is_tracking().await;
        assert!(matches!(result, Err(IndiError::PropertyNotFound { .. })));
    }

    async fn slewing_while_home_is(home_state: &str) -> bool {
        let payload = format!(
            "{MOUNT_BASE_PROPERTIES}
<defNumberVector device=\"Mount\" name=\"EQUATORIAL_EOD_COORD\" state=\"Ok\" perm=\"rw\">
  <defNumber name=\"RA\" min=\"0\" max=\"24\">10.0</defNumber>
  <defNumber name=\"DEC\" min=\"-90\" max=\"90\">45.0</defNumber>
</defNumberVector>
<defSwitchVector device=\"Mount\" name=\"TELESCOPE_HOME\" state=\"{home_state}\" perm=\"rw\" rule=\"AtMostOne\">
  <defSwitch name=\"FIND\">Off</defSwitch>
  <defSwitch name=\"SET\">Off</defSwitch>
  <defSwitch name=\"GO\">Off</defSwitch>
</defSwitchVector>
"
        );
        let (mount, server, _) = mount_from_fake_server(payload.as_bytes(), TELESCOPE_HOME).await;
        let slewing = mount.try_is_slewing().await.expect("read slewing");
        drop(mount);
        server.await.expect("fake server should finish");
        slewing
    }

    /// A home in progress is motion: the mount reads as slewing while
    /// TELESCOPE_HOME is Busy even though the coordinate vector is idle.
    #[tokio::test]
    async fn a_home_in_progress_reads_as_slewing() {
        assert!(slewing_while_home_is("Busy").await);
        assert!(!slewing_while_home_is("Ok").await);
    }

    async fn can_set_park_with(park_option: &str) -> bool {
        let payload = format!(
            "{MOUNT_BASE_PROPERTIES}
<defSwitchVector device=\"Mount\" name=\"TELESCOPE_PARK_OPTION\" state=\"Idle\" perm=\"rw\" rule=\"AtMostOne\">
{park_option}
</defSwitchVector>
"
        );
        let (mount, server, _) =
            mount_from_fake_server(payload.as_bytes(), TELESCOPE_PARK_OPTION).await;
        let can = mount.can_set_park().await;
        drop(mount);
        server.await.expect("fake server should finish");
        can
    }

    /// Set park is offered only when the driver defines PARK_CURRENT.
    #[tokio::test]
    async fn set_park_needs_the_park_current_option() {
        assert!(
            can_set_park_with("  <defSwitch name=\"PARK_CURRENT\">Off</defSwitch>\n  <defSwitch name=\"PARK_WRITE_DATA\">Off</defSwitch>")
                .await
        );
        assert!(!can_set_park_with("  <defSwitch name=\"PARK_DEFAULT\">Off</defSwitch>").await);
    }

    /// Same contract for try_is_slewing.
    #[tokio::test]
    async fn try_is_slewing_errors_when_undefined() {
        let client = Arc::new(RwLock::new(IndiClient::new("localhost", Some(7624))));
        let mount = IndiMount::new(client, "TestMount");
        let result = mount.try_is_slewing().await;
        assert!(matches!(result, Err(IndiError::PropertyNotFound { .. })));
    }
}
