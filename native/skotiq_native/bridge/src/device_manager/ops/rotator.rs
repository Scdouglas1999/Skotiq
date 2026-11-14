//! Rotator operations.

use crate::device::DeviceType;
use crate::device_manager::handle::device_error;
use crate::device_manager::ops::state_events::property;
use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::event::equipment::EquipmentEvent;

impl DeviceManager {
    // Rotator commands publish their state change (see `state_events`).

    /// Move the rotator by `delta` degrees from its current sky angle, wrapped
    /// into 0..360.
    pub async fn rotator_move_relative(
        &self,
        device_id: &str,
        delta: f64,
    ) -> Result<(), DeviceOpError> {
        let current = self.rotator_get_position(device_id).await?;
        self.rotator_move_absolute(device_id, (current + delta).rem_euclid(360.0))
            .await
    }

    /// Move rotator to absolute sky position (degrees) and wait until it is
    /// at rest, publishing `RotatorMoveStarted` and then
    /// `RotatorMoveCompleted` with the angle read back (the target when it
    /// cannot be read). An IRotatorV4 driver returns from `MoveAbsolute` as the
    /// move starts and reports `IsMoving` until it ends.
    pub async fn rotator_move_absolute(
        &self,
        device_id: &str,
        position: f64,
    ) -> Result<(), DeviceOpError> {
        if self.registered_driver_type(device_id).await.is_none() {
            return Err(DeviceOpError::device_not_found(device_id));
        }
        let _command = self.command_activity.begin(device_id);
        self.publish_state_event(EquipmentEvent::RotatorMoveStarted {
            device_id: device_id.to_string(),
            target_angle: position,
        });
        let result = match self
            .rotator_move_absolute_dispatch(device_id, position)
            .await
        {
            Ok(()) => self.wait_rotator_at_rest(device_id).await,
            Err(e) => Err(e),
        };
        self.publish_rotator_move_end(device_id, result.is_ok().then_some(position))
            .await;
        result
    }

    /// Halt the rotator and publish where it stopped.
    pub async fn rotator_halt(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let _command = self.command_activity.begin(device_id);
        let result = self.rotator_halt_dispatch(device_id).await;
        if result.is_ok() {
            self.publish_rotator_move_end(device_id, None).await;
        }
        result
    }

    /// Sync the reported sky angle without moving, publishing the new angle.
    pub async fn rotator_sync(&self, device_id: &str, position: f64) -> Result<(), DeviceOpError> {
        let _command = self.command_activity.begin(device_id);
        self.rotator_sync_dispatch(device_id, position).await?;
        let angle = self
            .rotator_get_position(device_id)
            .await
            .unwrap_or(position);
        self.command_activity
            .record(device_id, super::backstop::Reading::Rotator(angle));
        self.publish_property_changed(
            DeviceType::Rotator,
            device_id,
            property::ROTATOR_POSITION,
            angle.to_string(),
        );
        Ok(())
    }

    /// Set the reverse flag, publishing the new value.
    pub async fn rotator_set_reverse(
        &self,
        device_id: &str,
        reverse: bool,
    ) -> Result<(), DeviceOpError> {
        self.rotator_set_reverse_dispatch(device_id, reverse)
            .await?;
        self.publish_property_changed(
            DeviceType::Rotator,
            device_id,
            property::ROTATOR_REVERSE,
            reverse.to_string(),
        );
        Ok(())
    }

    /// `RotatorMoveCompleted` with the angle read back, or `fallback`; also
    /// after a failed move, so no UI is left showing the rotator as moving.
    async fn publish_rotator_move_end(&self, device_id: &str, fallback: Option<f64>) {
        let reached = self.rotator_get_position(device_id).await.ok().or(fallback);
        if let Some(angle) = reached {
            self.publish_state_event(EquipmentEvent::RotatorMoveCompleted {
                device_id: device_id.to_string(),
                angle,
            });
        }
    }
}

impl DeviceManager {
    /// Read the rotator's sky angle in degrees. The outcome feeds the device's
    /// read health (see [`crate::device_manager::read_health`]).
    pub async fn rotator_get_position(&self, device_id: &str) -> Result<f64, DeviceOpError> {
        let result = async {
            self.rotator(device_id)
                .await?
                .position()
                .await
                .map_err(|e| device_error(device_id, e))
        }
        .await;
        self.note_status_read(device_id, &result);
        result
    }

    /// Degrees the mechanism is at, before any sync offset.
    pub async fn rotator_get_mechanical_position(
        &self,
        device_id: &str,
    ) -> Result<f64, DeviceOpError> {
        self.rotator(device_id)
            .await?
            .mechanical_position()
            .await
            .map_err(|e| device_error(device_id, e))
    }

    /// Polls `IsMoving` until the rotator stops; a halt ends the wait too.
    async fn wait_rotator_at_rest(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let limit = crate::timeout_ops::Timeouts::rotator_move();
        let deadline = tokio::time::Instant::now() + limit;
        while self.rotator_is_moving(device_id).await? {
            if tokio::time::Instant::now() >= deadline {
                return Err(DeviceOpError::Timeout {
                    device_id: Some(device_id.to_string()),
                    detail: format!("Rotator {device_id} is still moving after {limit:?}"),
                });
            }
            tokio::time::sleep(std::time::Duration::from_millis(200)).await;
        }
        Ok(())
    }

    pub async fn rotator_is_moving(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        self.rotator(device_id)
            .await?
            .is_moving()
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn rotator_move_absolute_dispatch(
        &self,
        device_id: &str,
        position: f64,
    ) -> Result<(), DeviceOpError> {
        self.rotator(device_id)
            .await?
            .move_absolute(position)
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn rotator_halt_dispatch(&self, device_id: &str) -> Result<(), DeviceOpError> {
        self.rotator(device_id)
            .await?
            .halt()
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn rotator_sync_dispatch(
        &self,
        device_id: &str,
        position: f64,
    ) -> Result<(), DeviceOpError> {
        self.rotator(device_id)
            .await?
            .sync(position)
            .await
            .map_err(|e| device_error(device_id, e))
    }

    async fn rotator_set_reverse_dispatch(
        &self,
        device_id: &str,
        reverse: bool,
    ) -> Result<(), DeviceOpError> {
        self.rotator(device_id)
            .await?
            .set_reverse(reverse)
            .await
            .map_err(|e| device_error(device_id, e))
    }
}
