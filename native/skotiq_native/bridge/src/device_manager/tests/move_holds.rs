//! A wheel or rotator move holds its heartbeat off while the move call
//! runs, as the focuser's does. An ASCOM driver can block in the call on the
//! STA thread, and a status read queued behind it is not a failed poll.

use super::*;
use crate::device_capabilities::types::RotatorCapabilities;
use crate::device_manager::accessory::Rotator;
use crate::device_manager::handle::DeviceHandle;
use crate::device_manager::rig::filter_wheel::DriverFilterWheel;
use crate::error::SkotiqError;
use skotiq_device::{AccessoryDriver, DriverError, RotatorDriver};
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::Mutex as StdMutex;

type Active = Arc<StdMutex<HashSet<String>>>;

/// Records whether its device's heartbeat was held off during the move.
#[derive(Debug, Clone)]
struct Seen {
    id: String,
    active: Active,
    held: Arc<AtomicBool>,
}

impl Seen {
    fn new(manager: &DeviceManager, id: &str) -> Self {
        Self {
            id: id.to_string(),
            active: manager.active_operations.clone(),
            held: Arc::new(AtomicBool::new(false)),
        }
    }

    fn look(&self) {
        let held = self.active.lock().unwrap().contains(&self.id);
        self.held.store(held, Ordering::SeqCst);
    }
}

#[derive(Debug)]
struct Wheel {
    seen: Seen,
    slot: AtomicI32,
}

#[async_trait::async_trait]
impl skotiq_device::DeviceDriver for Wheel {
    fn id(&self) -> &str {
        &self.seen.id
    }
    fn name(&self) -> &str {
        "Wheel"
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
impl skotiq_device::FilterWheelDriver for Wheel {
    async fn move_to_position(&mut self, position: i32) -> Result<(), DriverError> {
        self.seen.look();
        self.slot.store(position, Ordering::SeqCst);
        Ok(())
    }
    async fn get_position(&self) -> Result<i32, DriverError> {
        Ok(self.slot.load(Ordering::SeqCst))
    }
    async fn is_moving(&self) -> Result<bool, DriverError> {
        Ok(false)
    }
    async fn get_filter_count(&self) -> i32 {
        5
    }
    async fn get_filter_names(&self) -> Result<Vec<String>, DriverError> {
        Ok(Vec::new())
    }
    async fn set_filter_name(&mut self, _position: i32, _name: String) -> Result<(), DriverError> {
        Ok(())
    }
}

struct Turner {
    seen: Seen,
}

#[async_trait::async_trait]
impl AccessoryDriver for Turner {
    async fn disconnect(&self) -> Result<(), DriverError> {
        Ok(())
    }
    async fn heartbeat(&self) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl RotatorDriver for Turner {
    async fn move_absolute(&self, _position_deg: f64) -> Result<(), DriverError> {
        self.seen.look();
        Ok(())
    }
    async fn position(&self) -> Result<f64, DriverError> {
        Ok(90.0)
    }
    async fn is_moving(&self) -> Result<bool, DriverError> {
        Ok(false)
    }
    async fn halt(&self) -> Result<(), DriverError> {
        Ok(())
    }
    async fn sync(&self, _position_deg: f64) -> Result<(), DriverError> {
        Ok(())
    }
    async fn set_reverse(&self, _reverse: bool) -> Result<(), DriverError> {
        Ok(())
    }
}

#[async_trait::async_trait]
impl Rotator for Turner {
    async fn capabilities(&self, _device_id: &str) -> Result<RotatorCapabilities, SkotiqError> {
        Err(SkotiqError::Internal("test rotator".to_string()))
    }
    async fn mechanical_position(&self) -> Result<f64, DriverError> {
        Ok(90.0)
    }
}

fn info(id: &str, device_type: DeviceType) -> DeviceInfo {
    DeviceInfo {
        id: id.to_string(),
        name: id.to_string(),
        device_type,
        driver_type: DriverType::Native,
        description: String::new(),
        driver_version: String::new(),
        serial_number: None,
        unique_id: None,
        display_name: id.to_string(),
    }
}

#[tokio::test]
async fn a_wheel_move_holds_its_heartbeat_off_during_the_move_call() {
    let manager = build_device_manager();
    let id = "native:test:wheel";
    let seen = Seen::new(&manager, id);
    manager
        .register_connected_device(info(id, DeviceType::FilterWheel))
        .await;
    manager.handles.insert(
        id,
        DeviceHandle::FilterWheel(Arc::new(DriverFilterWheel::vendor(
            id,
            Box::new(Wheel {
                seen: seen.clone(),
                slot: AtomicI32::new(0),
            }),
        ))),
    );
    manager
        .filter_wheel_set_position(id, 2)
        .await
        .expect("move");
    assert!(seen.held.load(Ordering::SeqCst));
    assert!(!manager.is_operation_active(id));
}

#[tokio::test]
async fn a_rotator_move_holds_its_heartbeat_off_during_the_move_call() {
    let manager = build_device_manager();
    let id = "alpaca:test:rotator";
    let seen = Seen::new(&manager, id);
    manager
        .register_connected_device(info(id, DeviceType::Rotator))
        .await;
    manager.handles.insert(
        id,
        DeviceHandle::Rotator(Arc::new(Turner { seen: seen.clone() })),
    );
    manager.rotator_move_absolute(id, 90.0).await.expect("move");
    assert!(seen.held.load(Ordering::SeqCst));
    assert!(!manager.is_operation_active(id));
}
