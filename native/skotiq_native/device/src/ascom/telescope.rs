//! `ITelescope` rules both transports share.

use crate::DriverError;
use std::time::Duration;
use tokio::time::Instant;

/// How long past its nominal end a guide pulse may still read as running
/// before the wait for it gives up.
const PULSE_END_GRACE: Duration = Duration::from_secs(2);
const PULSE_END_POLL: Duration = Duration::from_millis(50);

/// Waits until a guide pulse the driver accepted at `started` is over.
///
/// An ITelescopeV4 driver returns from `PulseGuide` at once and reports the
/// pulse through `IsPulseGuiding`; older drivers often return when the pulse
/// ends. Either way the caller gets control back once the mount has stopped
/// correcting, so the next pulse or guide frame does not overlap this one
/// (NINA's direct guider waits the same way). A driver that cannot report
/// `IsPulseGuiding` is taken to be done when the pulse's length has passed.
///
/// A pulse still reported after the grace period is a
/// [`DriverError::Timeout`] whose text is the whole sentence.
pub async fn wait_for_pulse_end<F, Fut, E>(
    started: Instant,
    duration_ms: u32,
    mut is_pulse_guiding: F,
) -> Result<(), DriverError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<bool, E>>,
{
    let nominal_end = started + Duration::from_millis(u64::from(duration_ms));
    tokio::time::sleep_until(nominal_end).await;
    let deadline = nominal_end + PULSE_END_GRACE;
    loop {
        match is_pulse_guiding().await {
            Ok(false) => return Ok(()),
            Ok(true) if Instant::now() >= deadline => {
                return Err(DriverError::Timeout(format!(
                    "the mount still reports a guide pulse {:.1} s after a {} ms pulse \
                     should have ended",
                    PULSE_END_GRACE.as_secs_f64(),
                    duration_ms
                )))
            }
            Ok(true) => tokio::time::sleep(PULSE_END_POLL).await,
            Err(_) => return Ok(()),
        }
    }
}

/// An ASCOM `UTCDate` value as Alpaca carries it: ISO 8601 in UTC with a
/// `Z` suffix.
pub fn utc_date(unix_seconds: i64) -> Result<String, DriverError> {
    chrono::DateTime::from_timestamp(unix_seconds, 0)
        .map(|utc| utc.to_rfc3339_opts(chrono::SecondsFormat::Millis, true))
        .ok_or_else(|| DriverError::InvalidParameter(format!("{unix_seconds} is not a UTC time")))
}

/// Seconds since the Unix epoch of an ASCOM `UTCDate` value.
pub fn unix_seconds_of_utc_date(iso: &str) -> Result<i64, DriverError> {
    chrono::DateTime::parse_from_rfc3339(iso)
        .map(|d| d.timestamp())
        .or_else(|_| {
            chrono::NaiveDateTime::parse_from_str(iso, "%Y-%m-%dT%H:%M:%S%.f")
                .map(|d| d.and_utc().timestamp())
        })
        .map_err(|e| DriverError::Unknown(format!("Unparseable Alpaca utcdate {iso:?}: {e}")))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_utc_date_is_iso_8601_in_utc_and_reads_back() {
        let unix = 1_794_452_400;
        let iso = utc_date(unix).expect("in range");
        assert_eq!(iso, "2026-11-12T03:00:00.000Z");
        assert_eq!(unix_seconds_of_utc_date(&iso).expect("parse"), unix);
        assert_eq!(
            unix_seconds_of_utc_date("2026-11-12T03:00:00.0000000").expect("no zone"),
            unix
        );
        assert!(utc_date(i64::MAX).is_err());
    }
}
