use super::*;

#[async_trait]
impl DomeOps for UnifiedDeviceOps {
    /// The sequencer's dome/cover role slots are never populated (see
    /// `DomeOps::active_dome_id`), so answer with whatever is connected —
    /// the same first-connected lookup `resolve_safety_device_id` uses.
    async fn active_dome_id(&self) -> Option<String> {
        get_device_manager()
            .first_connected_device_id(DeviceType::Dome)
            .await
    }

    async fn dome_open(&self, dome_id: &str) -> DeviceResult<()> {
        tracing::info!("Opening dome shutter {}", dome_id);

        get_device_manager()
            .dome_open_shutter(dome_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Dome))
    }

    async fn dome_close(&self, dome_id: &str) -> DeviceResult<()> {
        tracing::info!("Closing dome shutter {}", dome_id);

        get_device_manager()
            .dome_close_shutter(dome_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Dome))
    }

    async fn dome_park(&self, dome_id: &str) -> DeviceResult<()> {
        tracing::info!("Parking dome {}", dome_id);

        get_device_manager()
            .dome_park(dome_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Dome))
    }

    async fn dome_get_shutter_status(&self, dome_id: &str) -> DeviceResult<String> {
        let status = get_device_manager()
            .dome_get_shutter_status(dome_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::Dome))?;

        // Convert i32 status to string
        // ASCOM ShutterStatus: 0=Open, 1=Closed, 2=Opening, 3=Closing, 4=Error
        Ok(match status {
            0 => "Open".to_string(),
            1 => "Closed".to_string(),
            2 => "Opening".to_string(),
            3 => "Closing".to_string(),
            _ => "Error".to_string(),
        })
    }
}
