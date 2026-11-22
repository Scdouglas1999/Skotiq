//! R1B-1 focuser: a focuser driver that refuses an app's move because it is
//! moving answers as busy (`DeviceBusy` over the FFI, 409 on the host), not
//! as a hardware fault the host had to read the words of.

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
async fn a_focuser_that_says_it_is_moving_answers_the_app_busy() {
    let manager = crate::device_manager::get_device_manager();
    for (n, answer) in [
        "Move Failure",
        "Focuser is already moving",
        "device busy",
        "The focuser is busy",
    ]
    .into_iter()
    .enumerate()
    {
        let id = format!("native:test:focuser_busy_{n}");
        focuser_answering(manager, &id, answer).await;
        for result in [
            crate::api::devices::focuser::api_focuser_move_to(id.clone(), 2000).await,
            crate::api::devices::focuser::api_focuser_move_relative(id.clone(), 50).await,
        ] {
            assert!(
                matches!(result, Err(SkotiqError::DeviceBusy { .. })),
                "{answer}: {result:?}"
            );
        }
        manager.unregister_device(&id).await;
    }
}

/// The run's own moves keep the driver's failure: its device retry takes it
/// as transient, and the focuser stops moving.
#[tokio::test]
async fn the_runs_move_keeps_the_drivers_failure() {
    let manager = build_device_manager();
    let id = "native:test:focuser_run";
    focuser_answering(&manager, id, "Move Failure").await;
    let error = manager
        .focuser_move_abs(id, 2000)
        .await
        .expect_err("refused");
    assert!(matches!(error, DeviceOpError::Hardware { .. }), "{error:?}");
}

#[tokio::test]
async fn any_other_focuser_failure_stays_a_hardware_fault() {
    let manager = crate::device_manager::get_device_manager();
    let id = "native:test:focuser_fault";
    focuser_answering(manager, id, "motor stalled").await;
    let result = crate::api::devices::focuser::api_focuser_move_to(id.to_string(), 2000).await;
    assert!(
        matches!(result, Err(SkotiqError::OperationFailed(_))),
        "a stall is not a busy focuser: {result:?}"
    );
    manager.unregister_device(id).await;
}
