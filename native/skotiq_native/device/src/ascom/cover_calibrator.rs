//! How an ASCOM cover calibrator (`ICoverCalibratorV2`) is read and when one
//! of its moves has finished, the same over COM and Alpaca.
//!
//! `CoverState` and `CalibratorState` are mandatory and report a part the
//! device lacks as `NotPresent`. `Brightness` and `MaxBrightness` are not
//! implemented on a device without a calibrator.

use super::{optional, CalibratorStatus, CoverStatus};
use crate::{CoverCalibratorDriver, CoverCalibratorState, DriverError};

/// What [`CoverCalibratorDriver::status`] answers for an ASCOM device.
pub async fn state(
    device: &dyn CoverCalibratorDriver,
) -> Result<CoverCalibratorState, DriverError> {
    let cover = device.cover_status().await?;
    let calibrator = device.calibrator_status().await?;
    let (brightness, max_brightness) = if calibrator == CalibratorStatus::NotPresent {
        (0, 0)
    } else {
        (
            optional(device.brightness().await)?.unwrap_or(0),
            optional(device.max_brightness().await)?.unwrap_or(0),
        )
    };
    Ok(CoverCalibratorState {
        cover,
        calibrator,
        brightness,
        max_brightness,
    })
}

/// Where a wait for a cover or calibrator to reach a state stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Settle {
    /// The device is still on its way; poll again.
    Waiting,
    /// The move is over: the device reports the state asked for, or reports
    /// `Unknown`, which ASCOM reserves for hardware that cannot tell its
    /// state and tells clients to carry on as normal.
    Done,
    /// The device reports `Error`.
    Failed,
}

impl Settle {
    fn of(reported: i32, target: i32, unknown: i32, error: i32) -> Settle {
        if reported == target || reported == unknown {
            Settle::Done
        } else if reported == error {
            Settle::Failed
        } else {
            Settle::Waiting
        }
    }

    /// After `OpenCover` or `CloseCover`, waiting for `target`.
    pub fn cover(reported: CoverStatus, target: CoverStatus) -> Settle {
        Settle::of(
            reported as i32,
            target as i32,
            CoverStatus::Unknown as i32,
            CoverStatus::Error as i32,
        )
    }

    /// After `CalibratorOn` (`Ready`) or `CalibratorOff` (`Off`).
    pub fn calibrator(reported: CalibratorStatus, target: CalibratorStatus) -> Settle {
        Settle::of(
            reported as i32,
            target as i32,
            CalibratorStatus::Unknown as i32,
            CalibratorStatus::Error as i32,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_calibrator_that_cannot_tell_its_state_is_taken_as_on() {
        use CalibratorStatus::*;
        assert_eq!(Settle::calibrator(Ready, Ready), Settle::Done);
        assert_eq!(Settle::calibrator(Unknown, Ready), Settle::Done);
        assert_eq!(Settle::calibrator(NotReady, Ready), Settle::Waiting);
        assert_eq!(Settle::calibrator(Off, Ready), Settle::Waiting);
        assert_eq!(Settle::calibrator(Error, Ready), Settle::Failed);
        assert_eq!(Settle::calibrator(Off, Off), Settle::Done);
    }

    #[test]
    fn a_cover_is_done_when_it_arrives() {
        use CoverStatus::*;
        assert_eq!(Settle::cover(Open, Open), Settle::Done);
        assert_eq!(Settle::cover(Moving, Open), Settle::Waiting);
        assert_eq!(Settle::cover(Closed, Open), Settle::Waiting);
        assert_eq!(Settle::cover(Unknown, Closed), Settle::Done);
        assert_eq!(Settle::cover(Error, Closed), Settle::Failed);
    }
}
