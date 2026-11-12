use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::device_capabilities::AscomFocuserReadings;
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomFocuser;
use skotiq_device::Vendor;
use skotiq_device::{DeviceDriver, DriverError, FocuserDriver};
use std::fmt::Debug;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use tokio::sync::{mpsc, oneshot};

/// Connection result with device properties that can only be read after connection
#[derive(Debug)]
struct FocuserConnectInfo {
    max_position: i32,
    step_size: f64,
}

#[derive(Debug)]
enum AscomFocuserCommand {
    Connect(oneshot::Sender<Result<FocuserConnectInfo, DriverError>>),
    Disconnect(oneshot::Sender<Result<(), DriverError>>),
    MoveTo(i32, oneshot::Sender<Result<(), DriverError>>),
    MoveRelative(i32, oneshot::Sender<Result<(), DriverError>>),
    GetPosition(oneshot::Sender<Result<i32, DriverError>>),
    IsMoving(oneshot::Sender<Result<bool, DriverError>>),
    Halt(oneshot::Sender<Result<(), DriverError>>),
    GetTemperature(oneshot::Sender<Result<Option<f64>, DriverError>>),
    GetMaxPosition(oneshot::Sender<Result<i32, DriverError>>),
    GetStepSize(oneshot::Sender<Result<f64, DriverError>>),
    GetAbsolute(oneshot::Sender<Result<bool, DriverError>>),
    Heartbeat(oneshot::Sender<Result<(), DriverError>>),
    /// Every property `/api/equipment/focuser/capabilities` needs, read in ONE
    /// STA round-trip on the live COM object.
    GetCapabilityReadings(oneshot::Sender<Result<AscomFocuserReadings, DriverError>>),
    // Version query commands
}

pub struct AscomFocuserWrapper {
    id: String,
    name: String,
    sender: mpsc::Sender<AscomFocuserCommand>,
    // Cache static values - these are fetched AFTER connection, not during init
    // Use interior mutability since we update them in the async connect() method
    max_position: std::sync::atomic::AtomicI32,
    step_size: std::sync::atomic::AtomicU64, // Store f64 bits as u64
    connected: AtomicBool,
}

impl Debug for AscomFocuserWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AscomFocuserWrapper")
            .field("id", &self.id)
            .field("name", &self.name)
            .finish()
    }
}

impl AscomFocuserWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper, exactly as the legacy init-channel did. We do
        // NOT fetch max_position/step_size here — they can only be read reliably
        // AFTER the device is connected, in the Connect handler.
        register_device(move || {
            let mut focuser = match AscomFocuser::new(&prog_id_clone) {
                Ok(f) => f,
                Err(e) => {
                    return Err(format!("Failed to create ASCOM focuser: {}", e));
                }
            };

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let cmd = match rx.try_recv() {
                    Ok(cmd) => cmd,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM teardown ordering — the typed `AscomFocuser`
                        // (and its IDispatch) is released when this closure is
                        // dropped, still on the STA worker thread that owns the
                        // apartment. The apartment persists for the process
                        // lifetime, so COM is NOT uninitialized here.
                        return PumpOutcome::Finished;
                    }
                };
                match cmd {
                    AscomFocuserCommand::Connect(reply) => {
                        // Connect first, then fetch properties that require connection
                        let result = focuser
                            .connect()
                            .map_err(super::ascom_error)
                            .and_then(|()| {
                                // Fetch static properties AFTER connection
                                // Why: `max_step` and `step_size` are
                                // optional ASCOM IFocuserV2 properties. Older drivers
                                // (e.g. Pegasus Astro USB Focus v2 firmware <1.4) lack
                                // them; logging + returning 0 lets the connection
                                // succeed and surfaces the missing capability to the
                                // UI as "Range: 0". The user's focuser-settings dialog
                                // then prompts for manual entry. Connection itself
                                // already succeeded above, so failing here would mask
                                // a working focuser as broken.
                                let max_step = focuser
                                    .max_step()
                                    .map_err(|e| {
                                        tracing::warn!(
                                            "Failed to get focuser max_step after connect: {}",
                                            e
                                        );
                                        e.to_string()
                                    })
                                    .unwrap_or(0);
                                // Why: see max_step block above
                                // — same fallback policy for the optional IFocuserV2
                                // `StepSize` property. 0.0 maps to "unknown step
                                // size" in the focuser-settings UI.
                                let step_size = focuser
                                    .step_size()
                                    .map_err(|e| {
                                        tracing::warn!(
                                            "Failed to get focuser step_size after connect: {}",
                                            e
                                        );
                                        e.to_string()
                                    })
                                    .unwrap_or(0.0);

                                Ok(FocuserConnectInfo {
                                    max_position: max_step,
                                    step_size,
                                })
                            });
                        let _ = reply.send(result);
                    }
                    AscomFocuserCommand::Disconnect(reply) => {
                        let _ = reply.send(focuser.disconnect().map_err(super::ascom_error));
                    }
                    AscomFocuserCommand::MoveTo(pos, reply) => {
                        let _ = reply.send(focuser.move_to(pos).map_err(super::ascom_error));
                    }
                    AscomFocuserCommand::MoveRelative(steps, reply) => {
                        // ASCOM doesn't have move_relative, so we need current pos + steps
                        // But we can't easily do that atomically here without potentially blocking.
                        // Actually we can: get pos, add steps, move to.
                        let res = (|| -> Result<(), DriverError> {
                            let current = focuser.position().map_err(super::ascom_error)?;
                            focuser.move_to(current + steps).map_err(super::ascom_error)
                        })();
                        let _ = reply.send(res);
                    }
                    AscomFocuserCommand::GetPosition(reply) => {
                        let _ = reply.send(focuser.position().map_err(super::ascom_error));
                    }
                    AscomFocuserCommand::IsMoving(reply) => {
                        let _ = reply.send(focuser.is_moving().map_err(super::ascom_error));
                    }
                    AscomFocuserCommand::Halt(reply) => {
                        let _ = reply.send(focuser.halt().map_err(super::ascom_error));
                    }
                    AscomFocuserCommand::GetTemperature(reply) => {
                        // Check if temp comp available or just try getting temp
                        // Some drivers might error if not available
                        let res = focuser.temperature().map(Some).or(Ok(None));
                        let _ = reply.send(res);
                    }
                    AscomFocuserCommand::GetMaxPosition(reply) => {
                        let _ = reply.send(focuser.max_step().map_err(super::ascom_error));
                    }
                    AscomFocuserCommand::GetStepSize(reply) => {
                        let _ = reply.send(focuser.step_size().map_err(super::ascom_error));
                    }
                    AscomFocuserCommand::GetAbsolute(reply) => {
                        let _ = reply.send(focuser.absolute().map_err(super::ascom_error));
                    }
                    AscomFocuserCommand::Heartbeat(reply) => {
                        let _ = reply.send(focuser.heartbeat().map_err(super::ascom_error));
                    }
                    AscomFocuserCommand::GetCapabilityReadings(reply) => {
                        // `get_capabilities` + `get_full_status` already swallow
                        // per-property failures into `None` (a driver raising
                        // PropertyNotImplemented is normal), so this whole read is
                        // infallible; only the channel/STA layer can fail.
                        let caps = focuser.get_capabilities();
                        let live = focuser.get_full_status();
                        let _ = reply.send(Ok(AscomFocuserReadings {
                            max_step: caps.max_step,
                            max_increment: caps.max_increment,
                            step_size: caps.step_size,
                            absolute: caps.absolute,
                            temp_comp_available: caps.temp_comp_available,
                            temp_comp: live.temp_comp,
                            temperature: live.temperature,
                            position: live.position,
                            is_moving: live.is_moving,
                        }));
                    }
                }
                PumpOutcome::DidWork
            })
                as crate::ascom_wrapper::sta_worker::DevicePump)
        })?;

        Ok(Self {
            id: prog_id.clone(),
            name: prog_id,
            sender: tx,
            // Initialize with defaults - real values are fetched after connect()
            max_position: AtomicI32::new(0),
            step_size: AtomicU64::new(0.0f64.to_bits()),
            connected: AtomicBool::new(false),
        })
    }

    async fn fetch_max_position(&self) -> Result<i32, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::GetMaxPosition(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        super::recv_with_timeout("Focuser", rx, Timeouts::property_read(), "get_max_position").await
    }

    async fn fetch_step_size(&self) -> Result<f64, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::GetStepSize(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        super::recv_with_timeout("Focuser", rx, Timeouts::property_read(), "get_step_size").await
    }

    pub async fn heartbeat(&self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::Heartbeat(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        super::recv_with_timeout("Focuser", rx, Timeouts::property_read(), "heartbeat").await
    }

    /// Read the capability + live-status bundle for
    /// `/api/equipment/focuser/capabilities` from THIS live wrapper.
    ///
    /// Exists so the capability probe never has to build a throwaway
    /// `AscomFocuser` for a device that is already connected — the same reason
    /// the camera, mount and filter-wheel probes query their registered
    /// wrappers. A second COM object for the same ProgID is not an independent
    /// client: many ASCOM local servers share `Connected` state, so a probe that
    /// connects (or disconnects) its own object mutates the live session, and
    /// each throwaway also churns an IDispatch on the shared STA apartment.
    pub async fn capability_readings(&self) -> Result<AscomFocuserReadings, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::GetCapabilityReadings(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        super::recv_with_timeout(
            "Focuser",
            rx,
            Timeouts::property_read(),
            "capability_readings",
        )
        .await
    }
}

#[async_trait::async_trait]
impl DeviceDriver for AscomFocuserWrapper {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Ascom
    }

    fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::Connect(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        let info =
            super::recv_with_timeout("Focuser", rx, Timeouts::connection(), "connect").await?;

        // Update cached values with real values from the connected device
        self.max_position.store(info.max_position, Ordering::SeqCst);
        self.step_size
            .store(info.step_size.to_bits(), Ordering::SeqCst);

        tracing::info!(
            "Focuser connected: max_position={}, step_size={}",
            info.max_position,
            info.step_size
        );

        match self.fetch_max_position().await {
            Ok(max_position) => {
                self.max_position.store(max_position, Ordering::SeqCst);
            }
            Err(err) => {
                tracing::warn!(
                    "Failed to refresh focuser max_position after connect: {}",
                    err
                );
            }
        }

        match self.fetch_step_size().await {
            Ok(step_size) => {
                self.step_size.store(step_size.to_bits(), Ordering::SeqCst);
            }
            Err(err) => {
                tracing::warn!("Failed to refresh focuser step_size after connect: {}", err);
            }
        }

        self.connected.store(true, Ordering::SeqCst);
        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::Disconnect(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        let result =
            super::recv_with_timeout("Focuser", rx, Timeouts::connection(), "disconnect").await;
        if result.is_ok() {
            self.connected.store(false, Ordering::SeqCst);
        }
        result
    }
}

#[async_trait::async_trait]
impl FocuserDriver for AscomFocuserWrapper {
    async fn move_to(&mut self, position: i32) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::MoveTo(position, tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        // Focuser moves can take a long time
        super::recv_with_timeout("Focuser", rx, Timeouts::focuser_move(), "move_to").await
    }

    async fn move_relative(&mut self, steps: i32) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::MoveRelative(steps, tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        super::recv_with_timeout("Focuser", rx, Timeouts::focuser_move(), "move_relative").await
    }

    async fn get_position(&self) -> Result<i32, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::GetPosition(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        super::recv_with_timeout("Focuser", rx, Timeouts::property_read(), "get_position").await
    }

    async fn is_moving(&self) -> Result<bool, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::IsMoving(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        super::recv_with_timeout("Focuser", rx, Timeouts::property_read(), "is_moving").await
    }

    async fn halt(&mut self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::Halt(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        super::recv_with_timeout("Focuser", rx, Timeouts::property_write(), "halt").await
    }

    async fn get_temperature(&self) -> Result<Option<f64>, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::GetTemperature(tx))
            .await
            .map_err(|e| DriverError::SdkError(e.to_string()))?;
        super::recv_with_timeout("Focuser", rx, Timeouts::property_read(), "get_temperature").await
    }

    fn get_max_position(&self) -> i32 {
        self.max_position.load(Ordering::SeqCst)
    }

    fn get_step_size(&self) -> f64 {
        f64::from_bits(self.step_size.load(Ordering::SeqCst))
    }
}

// Version query methods
impl AscomFocuserWrapper {
    /// Whether this focuser supports absolute positioning.
    pub async fn is_absolute(&self) -> Result<bool, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFocuserCommand::GetAbsolute(tx))
            .await
            .map_err(|_| DriverError::Unknown("Worker thread dead".to_string()))?;
        super::recv_with_timeout("Focuser", rx, Timeouts::property_read(), "is_absolute").await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn build_test_wrapper<F>(handler: F) -> AscomFocuserWrapper
    where
        F: FnMut(AscomFocuserCommand) -> bool + Send + 'static,
    {
        let (tx, mut rx) = mpsc::channel(8);
        let _handle = thread::spawn(move || {
            let mut handler = handler;
            while let Some(cmd) = crate::ascom_wrapper::pump_blocking_recv(&mut rx) {
                if handler(cmd) {
                    break;
                }
            }
        });

        AscomFocuserWrapper {
            id: "test-focuser".to_string(),
            name: "Test Focuser".to_string(),
            sender: tx,
            max_position: AtomicI32::new(0),
            step_size: AtomicU64::new(1.0f64.to_bits()),
            connected: AtomicBool::new(false),
        }
    }

    #[tokio::test]
    async fn test_connect_refreshes_cached_limits_from_commands() {
        let mut wrapper = build_test_wrapper(|cmd| {
            match cmd {
                AscomFocuserCommand::Connect(reply) => {
                    let info = FocuserConnectInfo {
                        max_position: 1000,
                        step_size: 1.0,
                    };
                    let _ = reply.send(Ok(info));
                }
                AscomFocuserCommand::GetMaxPosition(reply) => {
                    let _ = reply.send(Ok(1200));
                }
                AscomFocuserCommand::GetStepSize(reply) => {
                    let _ = reply.send(Ok(2.5));
                }
                _ => {}
            }
            false
        });

        wrapper.connect().await.expect("connect");
        assert_eq!(wrapper.get_max_position(), 1200);
        assert!((wrapper.get_step_size() - 2.5).abs() < f64::EPSILON);
    }

    #[tokio::test]
    async fn test_heartbeat_uses_worker_command() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomFocuserCommand::Heartbeat(reply) = cmd {
                let _ = reply.send(Err(DriverError::SdkError("COM disconnected".to_string())));
                return true;
            }
            false
        });

        let result = wrapper.heartbeat().await;
        assert!(
            result.is_err(),
            "heartbeat must propagate COM read failures"
        );
    }
}
