use super::{device_error, UnifiedDeviceOps};
use crate::device_manager::get_device_manager;
use crate::filter_matching::find_filter_match;
use async_trait::async_trait;
use skotiq_sequencer::{DeviceResult, FilterWheelOps};

#[async_trait]
impl FilterWheelOps for UnifiedDeviceOps {
    async fn filterwheel_set_position(&self, fw_id: &str, position: i32) -> DeviceResult<()> {
        // `DeviceManager::filter_wheel_set_position` publishes `FilterChanging`
        // and `FilterChanged`.
        get_device_manager()
            .filter_wheel_set_position(fw_id, position)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::FilterWheel))
    }

    async fn filterwheel_get_position(&self, fw_id: &str) -> DeviceResult<i32> {
        get_device_manager()
            .filter_wheel_get_position(fw_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::FilterWheel))
    }

    async fn filterwheel_get_names(&self, fw_id: &str) -> DeviceResult<Vec<String>> {
        let (_, names) = get_device_manager()
            .filter_wheel_get_config(fw_id)
            .await
            .map_err(device_error(skotiq_sequencer::DeviceKind::FilterWheel))?;
        Ok(names)
    }

    async fn filterwheel_set_filter_by_name(&self, fw_id: &str, name: &str) -> DeviceResult<i32> {
        let names = self.filterwheel_get_names(fw_id).await?;

        // Find the filter position by name (case-insensitive)
        let index = find_filter_match(&names, name)
            .ok_or_else(|| format!("Filter '{}' not found", name))?;

        // Pass Skotiq's canonical 0-based index for EVERY driver. The INDI
        // path (DeviceManager::filter_wheel_set_position -> IndiFilterWheel::
        // set_position) already takes a 0-based index and converts it to the
        // driver's native wire slot (0- or 1-based, auto-detected). The previous
        // INDI-only `index + 1` therefore double-counted the slot base, shifting
        // every filter by one and running the last filter off the end of the wheel.
        let position = index as i32;

        self.filterwheel_set_position(fw_id, position).await?;
        Ok(position)
    }
}
