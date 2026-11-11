//! ASCOM Rotator wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::AscomResult;
use crate::health::ConnectionHealth;

com_device!(
    /// ASCOM Rotator
    Rotator
);

impl<D: ComDispatch> Rotator<D> {
    skotiq_device::ascom_rotator_members!(com_member);

    // Batch property queries

    /// Get complete rotator status in a single batch operation
    pub fn get_full_status(&self) -> RotatorFullStatus {
        RotatorFullStatus {
            name: self.name().ok(),
            position: self.position().ok(),
            mechanical_position: self.mechanical_position().ok(),
            target_position: self.target_position().ok(),
            step_size: self.step_size().ok(),
            is_moving: self.is_moving().ok(),
            can_reverse: self.can_reverse().ok(),
            reverse: self.reverse().ok(),
        }
    }
}

/// Full rotator status
#[derive(Debug, Clone, Default)]
pub struct RotatorFullStatus {
    pub name: Option<String>,
    pub position: Option<f64>,
    pub mechanical_position: Option<f64>,
    pub target_position: Option<f64>,
    pub step_size: Option<f64>,
    pub is_moving: Option<bool>,
    pub can_reverse: Option<bool>,
    pub reverse: Option<bool>,
}

#[cfg(test)]
mod tests {
    use super::RotatorFullStatus;

    #[test]
    fn full_status_includes_v3_fields() {
        let status = RotatorFullStatus {
            name: Some("Field Rotator".into()),
            position: Some(45.0),
            mechanical_position: Some(44.5),
            target_position: Some(90.0),
            step_size: Some(0.1),
            is_moving: Some(true),
            can_reverse: Some(true),
            reverse: Some(false),
        };

        assert_eq!(status.name.as_deref(), Some("Field Rotator"));
        assert_eq!(status.target_position, Some(90.0));
        assert_eq!(status.step_size, Some(0.1));
        assert_eq!(status.can_reverse, Some(true));
        assert_eq!(status.reverse, Some(false));
    }
}
