//! Reading and writing the mount's own site and clock.
//!
//! Two sources of truth exist the moment a mount is connected: the computer's
//! configured site/time and the mount's own. They are frequently different, and
//! neither is automatically right — a hand controller set once at the pier is
//! often better than a laptop that has never had its timezone corrected, and a
//! laptop with GPS is often better than a mount whose battery died. So this
//! module only ever moves values in the direction the operator asks for, and
//! [`DeviceManager::mount_site_capabilities`] says which directions the driver
//! can honour so the UI never offers one that will be refused.

use super::*;

/// Days between the OLE Automation epoch (1899-12-30) and the Unix epoch.
///
/// Only ASCOM speaks OLE dates, so on a non-Windows build nothing outside the
/// tests calls these. Kept compiled everywhere — and tested everywhere — so the
/// conversion cannot rot unnoticed on the platform that cannot exercise it.
#[cfg_attr(not(windows), allow(dead_code))]
const OLE_EPOCH_TO_UNIX_DAYS: f64 = 25_569.0;
#[cfg_attr(not(windows), allow(dead_code))]
const SECONDS_PER_DAY: f64 = 86_400.0;

#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn ole_to_unix_seconds(ole_days: f64) -> i64 {
    ((ole_days - OLE_EPOCH_TO_UNIX_DAYS) * SECONDS_PER_DAY).round() as i64
}

#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn unix_seconds_to_ole(unix_seconds: i64) -> f64 {
    unix_seconds as f64 / SECONDS_PER_DAY + OLE_EPOCH_TO_UNIX_DAYS
}

/// An Alpaca `UTCDate` value: ISO 8601 in UTC with a `Z` suffix.
pub(crate) fn alpaca_utc_date(unix_seconds: i64) -> Result<String, DeviceOpError> {
    chrono::DateTime::from_timestamp(unix_seconds, 0)
        .map(|utc| utc.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
        .ok_or_else(|| DeviceOpError::from(format!("{unix_seconds} is not a UTC time")))
}

impl DeviceManager {
    /// What this mount can actually do, so the reconciliation card offers only
    /// directions the driver supports.
    pub async fn mount_site_capabilities(
        &self,
        device_id: &str,
    ) -> Result<MountSiteCapabilities, DeviceOpError> {
        self.mount(device_id).await?.site_capabilities().await
    }

    pub async fn mount_get_site(&self, device_id: &str) -> Result<MountSite, DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.site().await
    }

    pub async fn mount_set_site(
        &self,
        device_id: &str,
        site: MountSite,
    ) -> Result<(), DeviceOpError> {
        if !(-90.0..=90.0).contains(&site.latitude_deg)
            || !(-180.0..=180.0).contains(&site.longitude_deg)
        {
            return Err(DeviceOpError::from(format!(
                "Refusing to write site {:.4},{:.4}: out of range",
                site.latitude_deg, site.longitude_deg
            )));
        }

        let mount = self.mount(device_id).await?;

        mount.set_site(site).await
    }

    pub async fn mount_get_time(&self, device_id: &str) -> Result<MountTimeInfo, DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.time().await
    }

    pub async fn mount_set_time(
        &self,
        device_id: &str,
        time: MountTimeInfo,
    ) -> Result<(), DeviceOpError> {
        if !(-14.0..=14.0).contains(&time.utc_offset_hours) {
            return Err(DeviceOpError::from(format!(
                "Refusing to write UTC offset {}: out of range",
                time.utc_offset_hours
            )));
        }

        let mount = self.mount(device_id).await?;

        mount.set_time(time).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_alpaca_utc_date_is_iso_8601_in_utc() {
        let unix = chrono::DateTime::parse_from_rfc3339("2026-09-09T12:00:05Z")
            .expect("parse")
            .timestamp();
        assert_eq!(
            alpaca_utc_date(unix).expect("in range"),
            "2026-09-09T12:00:05.000Z"
        );
    }

    #[test]
    fn ole_dates_round_trip_through_unix_seconds() {
        // 2026-09-09T12:00:00Z, checked against the OLE epoch of 1899-12-30.
        let unix = chrono::DateTime::parse_from_rfc3339("2026-09-09T12:00:00Z")
            .unwrap()
            .timestamp();
        let ole = unix_seconds_to_ole(unix);
        assert!(
            (ole_to_unix_seconds(ole) - unix).abs() <= 1,
            "OLE round trip drifted: {} -> {} -> {}",
            unix,
            ole,
            ole_to_unix_seconds(ole)
        );
    }

    #[test]
    fn the_ole_epoch_itself_maps_to_the_expected_unix_time() {
        // OLE day 25569.0 is exactly the Unix epoch.
        assert_eq!(ole_to_unix_seconds(OLE_EPOCH_TO_UNIX_DAYS), 0);
        assert!((unix_seconds_to_ole(0) - OLE_EPOCH_TO_UNIX_DAYS).abs() < 1e-9);
    }
}
