//! An INDI focuser and an INDI filter wheel as drivers.
//!
//! Both are a name on their server's shared connection, so a value made for
//! one call is the same device as any other.

use crate::protocol::names::*;
use crate::{IndiError, IndiFilterWheel, IndiFocuser, IndiPermission};
use async_trait::async_trait;
use skotiq_device::{DeviceDriver, DriverError, FilterWheelDriver, FocuserDriver, Vendor};

/// A failed operation in the driver's own words. Whoever shows it reads its
/// kind from the INDI error inside.
fn own(error: IndiError) -> DriverError {
    DriverError::Backend(Box::new(error))
}

macro_rules! indi_device_driver {
    ($device:ty, $label:literal) => {
        impl std::fmt::Debug for $device {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.debug_tuple($label).field(&self.device_name()).finish()
            }
        }

        #[async_trait]
        impl DeviceDriver for $device {
            fn id(&self) -> &str {
                self.device_name()
            }

            fn name(&self) -> &str {
                self.device_name()
            }

            fn vendor(&self) -> Vendor {
                Vendor::Indi
            }

            /// A value of this type is a device that was connected; its
            /// `heartbeat` asks the server whether it still is.
            fn is_connected(&self) -> bool {
                true
            }

            async fn connect(&mut self) -> Result<(), DriverError> {
                <$device>::connect(self).await.map_err(own)
            }

            async fn disconnect(&mut self) -> Result<(), DriverError> {
                <$device>::disconnect(self).await.map_err(own)
            }
        }
    };
}

indi_device_driver!(IndiFocuser, "IndiFocuser");
indi_device_driver!(IndiFilterWheel, "IndiFilterWheel");

impl IndiFocuser {
    async fn has_property(&self, property: &str) -> bool {
        self.client()
            .read()
            .await
            .has_property(self.device_name(), property)
            .await
    }
}

#[async_trait]
impl FocuserDriver for IndiFocuser {
    async fn heartbeat(&self) -> Result<bool, DriverError> {
        self.check().await.map_err(own)
    }

    async fn is_absolute(&self) -> bool {
        self.has_property(ABS_FOCUS_POSITION).await
    }

    async fn temp_comp(&self) -> Option<bool> {
        self.is_temp_comp_enabled().await
    }

    async fn move_to(&mut self, position: i32) -> Result<(), DriverError> {
        IndiFocuser::move_to(self, position).await.map_err(own)
    }

    async fn move_relative(&mut self, steps: i32) -> Result<(), DriverError> {
        IndiFocuser::move_relative(self, steps).await.map_err(own)
    }

    async fn get_position(&self) -> Result<i32, DriverError> {
        IndiFocuser::get_position(self).await.map_err(own)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        Ok(IndiFocuser::is_moving(self).await)
    }

    async fn can_halt(&self) -> bool {
        self.has_property(FOCUS_ABORT_MOTION).await
    }

    async fn halt(&mut self) -> Result<(), DriverError> {
        self.abort_motion().await.map_err(own)
    }

    /// A focuser that advertises a temperature sensor and fails the read has
    /// a problem; one without the property has no sensor.
    async fn get_temperature(&self) -> Result<Option<f64>, DriverError> {
        match IndiFocuser::get_temperature(self).await {
            Ok(temperature) => Ok(Some(temperature)),
            Err(e) if self.has_property(FOCUS_TEMPERATURE).await => Err(DriverError::Backend(
                format!(
                    "INDI focuser {} advertises a temperature sensor but the read failed: {}",
                    self.device_name(),
                    e
                )
                .into(),
            )),
            Err(_) => Ok(None),
        }
    }

    /// 0 for a focuser that does not publish `FOCUS_MAX`.
    async fn get_max_position(&self) -> i32 {
        self.get_max_step().await.unwrap_or(0)
    }

    /// 0.0 for a focuser that does not publish a step size.
    async fn get_step_size(&self) -> f64 {
        IndiFocuser::get_step_size(self).await.unwrap_or(0.0)
    }
}

#[async_trait]
impl FilterWheelDriver for IndiFilterWheel {
    async fn heartbeat(&self) -> Result<bool, DriverError> {
        self.check().await.map_err(own)
    }

    /// Whether the driver lets a client write `FILTER_NAME`.
    async fn can_set_filter_names(&self) -> bool {
        self.client()
            .read()
            .await
            .get_properties(self.device_name())
            .await
            .iter()
            .find(|p| p.name == FILTER_NAME)
            .is_some_and(|p| {
                matches!(
                    p.perm,
                    IndiPermission::WriteOnly | IndiPermission::ReadWrite
                )
            })
    }

    /// Returns once the wheel is at the slot.
    async fn move_to_position(&mut self, position: i32) -> Result<(), DriverError> {
        IndiFilterWheel::move_to_position(self, position)
            .await
            .map_err(own)
    }

    async fn get_position(&self) -> Result<i32, DriverError> {
        IndiFilterWheel::get_position(self).await.map_err(own)
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        Ok(IndiFilterWheel::is_moving(self).await)
    }

    /// The `FILTER_SLOT` range when the driver publishes one, otherwise the
    /// number of names.
    async fn get_filter_count(&self) -> i32 {
        let limits = self
            .client()
            .read()
            .await
            .get_number_limits(self.device_name(), FILTER_SLOT, FILTER_SLOT_VALUE)
            .await;
        let by_range = limits.and_then(|limits| match (limits.min, limits.max) {
            // A whole number of slots, so the cast is exact.
            (Some(min), Some(max)) if max > min => Some((max - min + 1.0).round() as i32),
            _ => None,
        });
        match by_range {
            Some(count) => count,
            None => {
                let names = self.get_names().await.unwrap_or_default();
                i32::try_from(names.len()).unwrap_or(0)
            }
        }
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, DriverError> {
        self.get_names().await.map_err(own)
    }

    /// Skotiq does not write an INDI wheel's filter names.
    async fn set_filter_name(&mut self, _position: i32, _name: String) -> Result<(), DriverError> {
        Err(DriverError::NotSupported)
    }
}
