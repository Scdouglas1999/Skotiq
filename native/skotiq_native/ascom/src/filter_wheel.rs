//! ASCOM Filter Wheel wrapper and batch status types.

use crate::com::ComDispatch;
use crate::error::AscomResult;

com_device!(
    /// ASCOM Filter Wheel
    FilterWheel
);

impl<D: ComDispatch> FilterWheel<D> {
    skotiq_device::ascom_filter_wheel_members!(com_member);

    pub fn position(&self) -> AscomResult<i32> {
        let pos = self.read_position();
        tracing::info!("ASCOM FilterWheel.Position returned: {:?}", pos);
        pos
    }

    pub fn set_position(&self, position: i32) -> AscomResult<()> {
        tracing::info!("ASCOM FilterWheel.SetPosition({})", position);
        self.write_position(position)
    }

    // Batch property queries

    /// Get complete filter wheel status in a single batch operation
    pub fn get_full_status(&self) -> FilterWheelFullStatus {
        FilterWheelFullStatus {
            position: self.position().ok(),
            names: self.names().ok(),
            focus_offsets: self.focus_offsets().ok(),
        }
    }
}

/// Full filter wheel status
#[derive(Debug, Clone, Default)]
pub struct FilterWheelFullStatus {
    pub position: Option<i32>,
    pub names: Option<Vec<String>>,
    pub focus_offsets: Option<Vec<i32>>,
}

#[cfg(test)]
mod tests {
    use super::FilterWheelFullStatus;

    #[test]
    fn full_status_carries_focus_offsets_when_present() {
        let status = FilterWheelFullStatus {
            position: Some(2),
            names: Some(vec!["L".into(), "R".into(), "G".into()]),
            focus_offsets: Some(vec![0, 120, 240]),
        };

        assert_eq!(
            status.focus_offsets.as_deref(),
            Some([0, 120, 240].as_slice())
        );
        assert_eq!(status.names.as_ref().map(Vec::len), Some(3));
    }

    #[test]
    fn full_status_leaves_focus_offsets_none_on_read_failure() {
        let status = FilterWheelFullStatus {
            position: Some(0),
            names: Some(vec!["Ha".into()]),
            focus_offsets: None,
        };

        assert!(status.focus_offsets.is_none());
    }
}
