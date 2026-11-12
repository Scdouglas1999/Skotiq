//! ASCOM Safety Monitor wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::AscomResult;

com_device!(SafetyMonitor);

impl<D: ComDispatch> SafetyMonitor<D> {
    skotiq_device::ascom_safety_monitor_members!(com_member);

    /// Get complete safety monitor status in a single batch operation
    pub fn get_full_status(&self) -> AscomResult<SafetyMonitorFullStatus> {
        SafetyMonitorFullStatus::from_is_safe_result(self.is_safe())
    }
}

#[derive(Debug, Clone, Default)]
pub struct SafetyMonitorFullStatus {
    pub is_safe: Option<bool>,
}

impl SafetyMonitorFullStatus {
    fn from_is_safe_result(is_safe: AscomResult<bool>) -> AscomResult<Self> {
        Ok(Self {
            is_safe: Some(is_safe?),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::SafetyMonitorFullStatus;
    use crate::com::Dispatch;
    use crate::error::AscomError;

    #[test]
    fn full_status_preserves_is_safe_value() {
        let status = SafetyMonitorFullStatus::from_is_safe_result(Ok(true))
            .expect("successful IsSafe query should build status");

        assert_eq!(status.is_safe, Some(true));
    }

    #[test]
    fn full_status_propagates_is_safe_error() {
        let err = SafetyMonitorFullStatus::from_is_safe_result(Err(AscomError::Invoke {
            dispatch: Dispatch::Get,
            member: "IsSafe".to_string(),
            cause: "ASCOM IsSafe COM failure".to_string(),
        }))
        .expect_err("IsSafe failures must not be swallowed into None")
        .to_string();

        assert!(
            err.contains("ASCOM IsSafe COM failure"),
            "full status should return the original driver error: {}",
            err
        );
    }
}
