//! Waiting for a device to take a command.

use crate::client::IndiClient;
use crate::error::{IndiError, IndiResult};
use crate::protocol::names::*;
use std::time::Duration;
use tokio::sync::RwLock;

/// How an Ok update shows a device already where the command sends it.
pub(crate) enum AtTarget {
    /// The mount's coordinates in the command's property are within an
    /// arcminute of these.
    Coordinates { ra_hours: f64, dec_degrees: f64 },
    /// The focuser's absolute position is this; `None` takes any Ok update
    /// as the answer.
    FocuserPosition(Option<i32>),
}

impl AtTarget {
    async fn reached(&self, client: &IndiClient, device: &str, property: &str) -> bool {
        match *self {
            Self::Coordinates {
                ra_hours,
                dec_degrees,
            } => {
                const AT_TARGET_DEG: f64 = 1.0 / 60.0;
                let ra = client.get_number(device, property, RA).await;
                let dec = client.get_number(device, property, DEC).await;
                let (Some(ra), Some(dec)) = (ra, dec) else {
                    return false;
                };
                let mut ra_diff_h = (ra - ra_hours) % 24.0;
                if ra_diff_h > 12.0 {
                    ra_diff_h -= 24.0;
                } else if ra_diff_h < -12.0 {
                    ra_diff_h += 24.0;
                }
                (ra_diff_h * 15.0).abs() <= AT_TARGET_DEG
                    && (dec - dec_degrees).abs() <= AT_TARGET_DEG
            }
            Self::FocuserPosition(None) => true,
            Self::FocuserPosition(Some(target)) => client
                .get_number(device, ABS_FOCUS_POSITION, FOCUS_ABSOLUTE_POSITION)
                .await
                .is_some_and(|p| (p - f64::from(target)).abs() < 0.5),
        }
    }
}

/// A command just sent on `property`, which was last updated at
/// `updated_before`.
pub(crate) struct Sent<'a> {
    pub(crate) property: &'a str,
    pub(crate) updated_before: Option<u64>,
    pub(crate) at_target: AtTarget,
}

/// Wait until `device` takes the command `sent`: an update after it that is
/// Busy, or an Ok one already at the target. Alert is the driver refusing
/// the command and is returned as `refused`. Any other update (a tracking
/// mount's periodic position) is not the answer. A driver that never
/// answers within `timeout` is logged as `late` and let through.
pub(crate) async fn wait_for_answer(
    client: &RwLock<IndiClient>,
    device: &str,
    sent: Sent<'_>,
    timeout: Duration,
    refused: impl FnOnce() -> String,
    late: impl FnOnce() -> String,
) -> IndiResult<()> {
    let Sent {
        property,
        updated_before,
        at_target,
    } = sent;
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        {
            let client = client.read().await;
            let updated = client.get_property_last_update_ms(device, property).await;
            if updated > updated_before {
                match client.get_property_state(device, property).await {
                    Some(crate::IndiPropertyState::Busy) => return Ok(()),
                    Some(crate::IndiPropertyState::Alert) => {
                        return Err(IndiError::DeviceAlert(refused()));
                    }
                    _ => {
                        if at_target.reached(&client, device, property).await {
                            return Ok(());
                        }
                    }
                }
            }
        }
        if tokio::time::Instant::now() >= deadline {
            tracing::warn!("{}", late());
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
}
