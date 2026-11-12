//! Alpaca Filter Wheel API implementation

use crate::AlpacaError;

/// Filter wheel status aggregate for parallel status query
#[derive(Debug, Clone)]
pub struct FilterWheelStatus {
    pub connected: bool,
    pub position: i32,
    pub is_moving: bool,
}

/// Filter wheel information including names and offsets
#[derive(Debug, Clone)]
pub struct FilterWheelInfo {
    pub names: Vec<String>,
    pub focus_offsets: Vec<i32>,
}

alpaca_device!(AlpacaFilterWheel, FilterWheel);

impl AlpacaFilterWheel {
    skotiq_device::ascom_filter_wheel_members!(alpaca_member);

    /// Check if filter wheel is currently moving
    /// Position returns -1 during movement, so we check for that
    pub async fn is_moving(&self) -> Result<bool, AlpacaError> {
        let pos = self.position().await?;
        Ok(pos == -1)
    }

    /// Get comprehensive filter wheel status in a single query
    pub async fn get_status(&self) -> Result<FilterWheelStatus, AlpacaError> {
        let (connected, position) = tokio::join!(self.is_connected(), self.position(),);

        let pos = position?;
        Ok(FilterWheelStatus {
            connected: connected?,
            position: pos,
            is_moving: pos == -1,
        })
    }

    /// Get filter wheel configuration in a single parallel query
    pub async fn get_filter_info(&self) -> Result<FilterWheelInfo, AlpacaError> {
        let (names, focus_offsets) = tokio::join!(self.names(), self.focus_offsets(),);

        Ok(FilterWheelInfo {
            names: names?,
            focus_offsets: focus_offsets?,
        })
    }

    pub async fn set_filter_by_name(&self, filter_name: &str) -> Result<(), AlpacaError> {
        let names = self.names().await?;
        for (idx, name) in names.iter().enumerate() {
            if name.eq_ignore_ascii_case(filter_name) {
                // Why: `idx` is a usize position into the
                // filter-name list returned by Alpaca; real filter wheels
                // ship with ≤10 slots (rarely up to 16). i32::try_from
                // surfaces an impossible-but-defined wire bug rather than
                // silently passing a negative position to set_position.
                let idx_i32 =
                    i32::try_from(idx).map_err(|_| AlpacaError::FilterIndexOutOfRange(idx))?;
                return self.set_position(idx_i32).await;
            }
        }
        Err(AlpacaError::FilterNotFound(filter_name.to_string()))
    }

    pub async fn current_filter_name(&self) -> Result<String, AlpacaError> {
        let pos = self.position().await?;
        if pos < 0 {
            return Err(AlpacaError::FilterWheelMoving);
        }
        let names = self.names().await?;
        // Why: `pos >= 0` is checked immediately above; i32
        // → usize widens on every supported Rust target. Out-of-bounds
        // returns None and surfaces as "Invalid position" — not a silent
        // panic.
        names
            .get(pos as usize)
            .cloned()
            .ok_or(AlpacaError::InvalidFilterPosition(pos))
    }

    pub async fn current_focus_offset(&self) -> Result<i32, AlpacaError> {
        let pos = self.position().await?;
        if pos < 0 {
            return Err(AlpacaError::FilterWheelMoving);
        }
        let offsets = self.focus_offsets().await?;
        // Why: same `pos >= 0` invariant as
        // `current_filter_name`; out-of-bounds gives an error string rather
        // than a panic.
        offsets
            .get(pos as usize)
            .copied()
            .ok_or(AlpacaError::InvalidFilterPosition(pos))
    }
}
