//! How an ASCOM dome (`IDomeV3`) is read, the same over COM and Alpaca.
//!
//! The `Can*` properties and `Slewing` are mandatory. `Azimuth`, `Altitude`,
//! `AtHome`, `AtPark`, `ShutterStatus` and `Slaved` raise
//! `PropertyNotImplemented` on a dome without that part (a roll-off roof has
//! no azimuth, a dome without a park position no `AtPark`), so a member that
//! is not implemented reads as absent and any other failure fails the read.

use super::{optional, ShutterStatus};
use crate::{DomeState, DriverError};
use async_trait::async_trait;

/// The `IDomeV3` properties a status read uses, in the transport's own calls.
#[async_trait]
pub trait DomeMembers: Send + Sync {
    async fn azimuth(&self) -> Result<f64, DriverError>;
    async fn altitude(&self) -> Result<f64, DriverError>;
    async fn at_home(&self) -> Result<bool, DriverError>;
    async fn at_park(&self) -> Result<bool, DriverError>;
    async fn shutter_status(&self) -> Result<ShutterStatus, DriverError>;
    async fn slewing(&self) -> Result<bool, DriverError>;
    async fn slaved(&self) -> Result<bool, DriverError>;
    async fn can_find_home(&self) -> Result<bool, DriverError>;
    async fn can_park(&self) -> Result<bool, DriverError>;
    async fn can_set_altitude(&self) -> Result<bool, DriverError>;
    async fn can_set_azimuth(&self) -> Result<bool, DriverError>;
    async fn can_set_shutter(&self) -> Result<bool, DriverError>;
    async fn can_slave(&self) -> Result<bool, DriverError>;
    async fn can_sync_azimuth(&self) -> Result<bool, DriverError>;
}

/// One read of everything a dome reports.
#[derive(Debug, Clone, PartialEq)]
pub struct DomeReport {
    /// What [`crate::DomeDriver::status`] answers. Its azimuth is 0 when the
    /// dome has none (`azimuth` below is `None`).
    pub state: DomeState,
    /// Degrees, north through east; `None` for a dome that cannot turn.
    pub azimuth: Option<f64>,
    pub can_find_home: bool,
    pub can_park: bool,
    pub can_sync_azimuth: bool,
}

/// Reads every property once. A `Can*` the driver wrongly leaves
/// unimplemented reads as `false`.
pub async fn report(dome: &dyn DomeMembers) -> Result<DomeReport, DriverError> {
    let capability = |read: Result<bool, DriverError>| -> Result<bool, DriverError> {
        Ok(optional(read)?.unwrap_or(false))
    };
    let can_find_home = capability(dome.can_find_home().await)?;
    let can_park = capability(dome.can_park().await)?;
    let can_set_altitude = capability(dome.can_set_altitude().await)?;
    let can_set_azimuth = capability(dome.can_set_azimuth().await)?;
    let can_set_shutter = capability(dome.can_set_shutter().await)?;
    let can_slave = capability(dome.can_slave().await)?;
    let can_sync_azimuth = capability(dome.can_sync_azimuth().await)?;
    let azimuth = optional(dome.azimuth().await)?;
    let state = DomeState {
        azimuth: azimuth.unwrap_or(0.0),
        altitude: optional(dome.altitude().await)?,
        shutter: optional(dome.shutter_status().await)?,
        slewing: dome.slewing().await?,
        at_home: optional(dome.at_home().await)?.unwrap_or(false),
        at_park: optional(dome.at_park().await)?.unwrap_or(false),
        can_set_altitude,
        can_set_azimuth,
        can_set_shutter,
        can_slave,
        slaved: optional(dome.slaved().await)?.unwrap_or(false),
    };
    Ok(DomeReport {
        state,
        azimuth,
        can_find_home,
        can_park,
        can_sync_azimuth,
    })
}

/// The azimuth `SlewToAzimuth` is sent: ASCOM accepts 0 up to but not
/// including 360 and refuses anything else, so a heading such as -10 or 370
/// (a mount's azimuth after a wrap) is put on the circle first.
pub fn slew_azimuth(azimuth_deg: f64) -> Result<f64, DriverError> {
    if !azimuth_deg.is_finite() {
        return Err(DriverError::InvalidParameter(format!(
            "Dome azimuth {azimuth_deg} is not a number of degrees"
        )));
    }
    let on_circle = azimuth_deg.rem_euclid(360.0);
    // rem_euclid of a tiny negative number rounds to 360.0.
    Ok(if on_circle >= 360.0 { 0.0 } else { on_circle })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A roll-off roof as the ASCOM simulator presents one: no azimuth, no
    /// altitude, no home, not slaved, with a shutter and a park position.
    struct RollOffRoof;

    #[async_trait]
    impl DomeMembers for RollOffRoof {
        async fn azimuth(&self) -> Result<f64, DriverError> {
            Err(DriverError::NotSupported)
        }
        async fn altitude(&self) -> Result<f64, DriverError> {
            Err(DriverError::NotSupported)
        }
        async fn at_home(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotSupported)
        }
        async fn at_park(&self) -> Result<bool, DriverError> {
            Ok(true)
        }
        async fn shutter_status(&self) -> Result<ShutterStatus, DriverError> {
            Ok(ShutterStatus::Closed)
        }
        async fn slewing(&self) -> Result<bool, DriverError> {
            Ok(false)
        }
        async fn slaved(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotSupported)
        }
        async fn can_find_home(&self) -> Result<bool, DriverError> {
            Ok(false)
        }
        async fn can_park(&self) -> Result<bool, DriverError> {
            Ok(true)
        }
        async fn can_set_altitude(&self) -> Result<bool, DriverError> {
            Ok(false)
        }
        async fn can_set_azimuth(&self) -> Result<bool, DriverError> {
            Ok(false)
        }
        async fn can_set_shutter(&self) -> Result<bool, DriverError> {
            Ok(true)
        }
        async fn can_slave(&self) -> Result<bool, DriverError> {
            Ok(false)
        }
        async fn can_sync_azimuth(&self) -> Result<bool, DriverError> {
            Ok(false)
        }
    }

    #[tokio::test]
    async fn a_roll_off_roof_reads_without_the_parts_it_lacks() {
        let report = report(&RollOffRoof).await.expect("roof status");
        assert_eq!(report.azimuth, None);
        assert_eq!(report.state.altitude, None);
        assert_eq!(report.state.shutter, Some(ShutterStatus::Closed));
        assert!(report.state.at_park);
        assert!(!report.state.at_home && !report.state.slaved);
        assert!(!report.state.can_set_azimuth && report.can_park && !report.can_find_home);
    }

    struct Unreachable;

    #[async_trait]
    impl DomeMembers for Unreachable {
        async fn azimuth(&self) -> Result<f64, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn altitude(&self) -> Result<f64, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn at_home(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn at_park(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn shutter_status(&self) -> Result<ShutterStatus, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn slewing(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn slaved(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn can_find_home(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn can_park(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn can_set_altitude(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn can_set_azimuth(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn can_set_shutter(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn can_slave(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
        async fn can_sync_azimuth(&self) -> Result<bool, DriverError> {
            Err(DriverError::NotConnected)
        }
    }

    #[tokio::test]
    async fn a_dome_that_does_not_answer_fails_the_read() {
        assert!(matches!(
            report(&Unreachable).await,
            Err(DriverError::NotConnected)
        ));
    }

    #[test]
    fn slew_azimuths_are_put_on_the_circle() {
        assert_eq!(slew_azimuth(370.0).unwrap(), 10.0);
        assert_eq!(slew_azimuth(-10.0).unwrap(), 350.0);
        assert_eq!(slew_azimuth(360.0).unwrap(), 0.0);
        assert_eq!(slew_azimuth(-1e-20).unwrap(), 0.0);
        assert_eq!(slew_azimuth(123.5).unwrap(), 123.5);
        assert!(slew_azimuth(f64::NAN).is_err());
    }
}
