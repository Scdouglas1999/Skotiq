//! The rotator driver trait, and what the rotator supports, over its ASCOM
//! wrapper. Every call still goes to the wrapper's command channel and runs
//! on the STA worker. The dome, switch, weather station, safety monitor and
//! cover calibrator implement their traits in their own files.

use super::rotator::AscomRotatorWrapper;
use crate::device_capabilities::RotatorCapabilities;
use crate::device_manager::accessory::{
    ascom_mechanical_position, ascom_rotator_capabilities, AscomRotatorMembers, Rotator,
};
use crate::dispatch::DeviceOpError;
use crate::error::SkotiqError;
use async_trait::async_trait;
use skotiq_device::{AccessoryDriver, DriverError, RotatorDriver};

fn com(error: DeviceOpError) -> DriverError {
    error.into()
}

/// `$probe` is the wrapper's cheapest read, which the heartbeat sends.
macro_rules! ascom_accessory {
    ($wrapper:ty, $probe:ident) => {
        #[async_trait]
        impl AccessoryDriver for $wrapper {
            async fn disconnect(&self) -> Result<(), DriverError> {
                <$wrapper>::disconnect(self).await.map_err(com)
            }

            async fn heartbeat(&self) -> Result<(), DriverError> {
                <$wrapper>::$probe(self).await.map(|_| ()).map_err(com)
            }
        }
    };
}

ascom_accessory!(AscomRotatorWrapper, heartbeat);

#[async_trait]
impl RotatorDriver for AscomRotatorWrapper {
    async fn move_absolute(&self, position_deg: f64) -> Result<(), DriverError> {
        AscomRotatorWrapper::move_absolute(self, position_deg)
            .await
            .map_err(com)
    }

    async fn position(&self) -> Result<f64, DriverError> {
        AscomRotatorWrapper::position(self).await.map_err(com)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        AscomRotatorWrapper::is_moving(self).await.map_err(com)
    }

    async fn halt(&self) -> Result<(), DriverError> {
        AscomRotatorWrapper::halt(self).await.map_err(com)
    }

    async fn sync(&self, position_deg: f64) -> Result<(), DriverError> {
        AscomRotatorWrapper::sync(self, position_deg)
            .await
            .map_err(com)
    }

    async fn set_reverse(&self, reverse: bool) -> Result<(), DriverError> {
        AscomRotatorWrapper::set_reverse(self, reverse)
            .await
            .map_err(com)
    }
}

// What each wrapper supports, read through its own COM object on the STA
// worker. The `unwrap_or` defaults are what the ASCOM interface means when a
// driver does not implement an optional property: the feature is absent, the
// device is not in that state.

#[async_trait]
impl AscomRotatorMembers for AscomRotatorWrapper {
    async fn interface_version(&self) -> Result<i32, DriverError> {
        AscomRotatorWrapper::interface_version(self).await.map_err(com)
    }
    async fn can_reverse(&self) -> Result<bool, DriverError> {
        AscomRotatorWrapper::can_reverse(self).await.map_err(com)
    }
    async fn reverse(&self) -> Result<bool, DriverError> {
        AscomRotatorWrapper::reverse(self).await.map_err(com)
    }
    async fn step_size(&self) -> Result<f64, DriverError> {
        AscomRotatorWrapper::step_size(self).await.map_err(com)
    }
    async fn ascom_mechanical_position(&self) -> Result<f64, DriverError> {
        AscomRotatorWrapper::mechanical_position(self)
            .await
            .map_err(com)
    }
}

#[async_trait]
impl Rotator for AscomRotatorWrapper {
    async fn capabilities(&self, _device_id: &str) -> Result<RotatorCapabilities, SkotiqError> {
        Ok(ascom_rotator_capabilities(self).await)
    }

    async fn mechanical_position(&self) -> Result<f64, DriverError> {
        ascom_mechanical_position(self).await
    }
}
