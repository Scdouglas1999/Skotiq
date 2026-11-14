//! The heartbeat's liveness probe of a native mount.

use super::*;
use crate::device::DriverType;
use skotiq_device::{
    DeviceDriver, DriverError, GuideDirection, MountDriver, PierSide, TrackingRate, Vendor,
};

/// A serial mount whose link has gone quiet. Like the LX200 driver on Meade,
/// Gemini and generic firmware, it answers the tracking state from what it
/// last sent, without asking the mount; only a coordinate read reaches the
/// wire.
#[derive(Debug)]
struct SerialMount {
    link_alive: bool,
}

impl SerialMount {
    fn wire(&self) -> Result<(), DriverError> {
        if self.link_alive {
            Ok(())
        } else {
            Err(DriverError::Timeout(
                "LX200 command response timed out".to_string(),
            ))
        }
    }
}

#[async_trait::async_trait]
impl DeviceDriver for SerialMount {
    fn id(&self) -> &str {
        "native:meade:test"
    }
    fn name(&self) -> &str {
        "Meade LX200"
    }
    fn vendor(&self) -> Vendor {
        Vendor::Meade
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
impl MountDriver for SerialMount {
    async fn slew_to_coordinates(&mut self, _ra: f64, _dec: f64) -> Result<(), DriverError> {
        self.wire()
    }
    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError> {
        self.wire().map(|_| (5.5, 20.0))
    }
    async fn sync_to_coordinates(&mut self, _ra: f64, _dec: f64) -> Result<(), DriverError> {
        self.wire()
    }
    async fn park(&mut self) -> Result<(), DriverError> {
        self.wire()
    }
    async fn unpark(&mut self) -> Result<(), DriverError> {
        self.wire()
    }
    async fn is_slewing(&self) -> Result<bool, DriverError> {
        Ok(false)
    }
    async fn is_parked(&self) -> Result<bool, DriverError> {
        Err(DriverError::NotSupported)
    }
    async fn pulse_guide(
        &mut self,
        _direction: GuideDirection,
        _duration_ms: u32,
    ) -> Result<(), DriverError> {
        self.wire()
    }
    async fn abort_slew(&mut self) -> Result<(), DriverError> {
        self.wire()
    }
    async fn set_tracking(&mut self, _enabled: bool) -> Result<(), DriverError> {
        self.wire()
    }
    async fn get_tracking(&self) -> Result<bool, DriverError> {
        Ok(true)
    }
    async fn set_tracking_rate(&mut self, _rate: TrackingRate) -> Result<(), DriverError> {
        self.wire()
    }
    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError> {
        Ok(TrackingRate::Sidereal)
    }
    async fn can_slew(&self) -> bool {
        true
    }
    async fn can_sync(&self) -> bool {
        true
    }
    async fn can_pulse_guide(&self) -> bool {
        true
    }
    async fn tracking_rates(&self) -> Vec<TrackingRate> {
        vec![TrackingRate::Sidereal]
    }
    async fn get_side_of_pier(&self) -> Result<PierSide, DriverError> {
        Ok(PierSide::Unknown)
    }
    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError> {
        self.wire().map(|_| (45.0, 180.0))
    }
    async fn get_sidereal_time(&self) -> Result<f64, DriverError> {
        self.wire().map(|_| 3.0)
    }
}

async fn manager_with(device_id: &str, mount: SerialMount) -> Arc<DeviceManager> {
    let manager = Arc::new(build_device_manager());
    manager
        .register_device(
            DeviceInfo {
                id: device_id.to_string(),
                name: "Meade LX200".to_string(),
                device_type: DeviceType::Mount,
                driver_type: DriverType::Native,
                description: "Native serial mount".to_string(),
                driver_version: "1.0".to_string(),
                serial_number: None,
                unique_id: None,
                display_name: "Meade LX200".to_string(),
            },
            false,
        )
        .await;
    manager.hold_vendor_mount(device_id, Box::new(mount));
    manager
}

/// The probe used to be `get_tracking`, which a Meade-protocol mount answers
/// from memory: an unplugged or powered-off mount passed every heartbeat and
/// was never reported lost.
#[tokio::test]
async fn a_mount_that_stopped_answering_fails_the_probe() {
    let device_id = "native:meade:test_gone";
    let manager = manager_with(device_id, SerialMount { link_alive: false }).await;
    let result = manager
        .perform_health_check(device_id, &DeviceType::Mount, &DriverType::Native)
        .await;
    assert!(
        matches!(&result, Err(e) if e.contains("timed out")),
        "{result:?}"
    );
}

#[tokio::test]
async fn a_mount_that_answers_is_healthy() {
    let device_id = "native:meade:test_ok";
    let manager = manager_with(device_id, SerialMount { link_alive: true }).await;
    let healthy = manager
        .perform_health_check(device_id, &DeviceType::Mount, &DriverType::Native)
        .await;
    assert_eq!(healthy, Ok(true));
}
