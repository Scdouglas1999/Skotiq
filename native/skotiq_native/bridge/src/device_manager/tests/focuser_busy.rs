//! R1B-1 focuser: a focuser driver that refuses a move because it is moving
//! answers as busy (`DeviceBusy` over the FFI, 409 on the host), not as a
//! hardware fault the host had to read the words of.

use super::*;
use crate::device_manager::handle::DeviceHandle;
use crate::device_manager::rig::focuser::DriverFocuser;
use crate::dispatch::error::DeviceOpError;
use crate::error::SkotiqError;
use skotiq_device::DriverError;

#[derive(Debug)]
struct RefusingFocuser {
    id: String,
    answer: &'static str,
}

#[async_trait::async_trait]
impl skotiq_device::DeviceDriver for RefusingFocuser {
    fn id(&self) -> &str {
        &self.id
    }
    fn name(&self) -> &str {
        "Focuser"
    }
    fn vendor(&self) -> skotiq_device::Vendor {
        skotiq_device::Vendor::Zwo
    }
    fn is_connected(&self) -> bool {
        true
    }
    async fn connect(&mut self) -> Result<(), DriverError> {
        Ok(())
    }
    async fn disconnect(&mut self) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl skotiq_device::FocuserDriver for RefusingFocuser {
    async fn move_to(&mut self, _position: i32) -> Result<(), DriverError> {
        Err(DriverError::SdkError(self.answer.to_string()))
    }
    async fn move_relative(&mut self, _steps: i32) -> Result<(), DriverError> {
        Err(DriverError::SdkError(self.answer.to_string()))
    }
    async fn get_position(&self) -> Result<i32, DriverError> {
        Ok(1000)
    }
    async fn is_moving(&self) -> Result<bool, DriverError> {
        Ok(false)
    }
    async fn halt(&mut self) -> Result<(), DriverError> {
        Ok(())
    }
    async fn get_temperature(&self) -> Result<Option<f64>, DriverError> {
        Ok(None)
    }
    async fn get_max_position(&self) -> i32 {
        10_000
    }
    async fn get_step_size(&self) -> f64 {
        1.0
    }
}

async fn focuser_answering(manager: &DeviceManager, id: &str, answer: &'static str) {
    manager
        .register_connected_device(DeviceInfo {
            id: id.to_string(),
            name: id.to_string(),
            device_type: DeviceType::Focuser,
            driver_type: DriverType::Native,
            description: String::new(),
            driver_version: String::new(),
            serial_number: None,
            unique_id: None,
            display_name: id.to_string(),
        })
        .await;
    manager.handles.insert(
        id,
        DeviceHandle::Focuser(Arc::new(DriverFocuser::vendor(
            id,
            Box::new(RefusingFocuser {
                id: id.to_string(),
                answer,
            }),
        ))),
    );
}

#[tokio::test]
async fn a_focuser_that_says_it_is_moving_answers_busy() {
    let manager = build_device_manager();
    let id = "native:test:focuser";
    for answer in [
        "Move Failure",
        "Focuser is already moving",
        "device busy",
        "The focuser is busy",
    ] {
        focuser_answering(&manager, id, answer).await;
        for result in [
            manager.focuser_move_abs(id, 2000).await,
            manager.focuser_move_rel(id, 50).await,
        ] {
            let error = result.expect_err(answer);
            assert!(
                matches!(error, DeviceOpError::InvalidState { .. }),
                "{answer}: {error:?}"
            );
            assert!(
                matches!(SkotiqError::from(error), SkotiqError::DeviceBusy { .. }),
                "{answer}"
            );
        }
    }
}

#[tokio::test]
async fn any_other_focuser_failure_stays_a_hardware_fault() {
    let manager = build_device_manager();
    let id = "native:test:focuser_fault";
    focuser_answering(&manager, id, "motor stalled").await;
    let error = manager.focuser_move_abs(id, 2000).await.expect_err("fails");
    assert!(
        matches!(SkotiqError::from(error), SkotiqError::OperationFailed(_)),
        "a stall is not a busy focuser"
    );
}
