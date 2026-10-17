use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomRotator;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

enum AscomRotatorCommand {
    Connect(oneshot::Sender<Result<(), String>>),
    Disconnect(oneshot::Sender<Result<(), String>>),
    Position(oneshot::Sender<Result<f64, String>>),
    MoveAbsolute(f64, oneshot::Sender<Result<(), String>>),
    Halt(oneshot::Sender<Result<(), String>>),
    IsMoving(oneshot::Sender<Result<bool, String>>),
    Sync(f64, oneshot::Sender<Result<(), String>>),
    SetReverse(bool, oneshot::Sender<Result<(), String>>),
    // ASCOM-Common metadata query commands. Mirrors the four
    // `InterfaceVersion` / `DriverVersion` / `DriverInfo` /
    // `SupportedActions` properties common to every ASCOM driver and is
    // consumed by `DeviceCommonMetadata` via `dispatch::ascom_device_common`.
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    GetDriverVersion(oneshot::Sender<Result<String, String>>),
    GetDriverInfo(oneshot::Sender<Result<String, String>>),
    GetSupportedActions(oneshot::Sender<Result<Vec<String>, String>>),
}

pub struct AscomRotatorWrapper {
    sender: mpsc::Sender<AscomRotatorCommand>,
    connected: AtomicBool,
}

impl AscomRotatorWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper, exactly as the legacy init-channel did.
        register_device(move || {
            let mut rotator = match AscomRotator::new(&prog_id_clone) {
                Ok(rotator) => rotator,
                Err(error) => {
                    return Err(format!("Failed to create ASCOM rotator: {}", error));
                }
            };

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let command = match rx.try_recv() {
                    Ok(command) => command,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM teardown ordering — the typed `AscomRotator`
                        // (and its IDispatch) is released when this closure is
                        // dropped, still on the STA worker thread that owns the
                        // apartment. The apartment persists for the process
                        // lifetime, so COM is NOT uninitialized here.
                        return PumpOutcome::Finished;
                    }
                };
                match command {
                    AscomRotatorCommand::Connect(reply) => {
                        let _ = reply.send(rotator.connect());
                    }
                    AscomRotatorCommand::Disconnect(reply) => {
                        let _ = reply.send(rotator.disconnect());
                    }
                    AscomRotatorCommand::Position(reply) => {
                        let _ = reply.send(rotator.position());
                    }
                    AscomRotatorCommand::MoveAbsolute(position, reply) => {
                        let _ = reply.send(rotator.move_absolute(position));
                    }
                    AscomRotatorCommand::Halt(reply) => {
                        let _ = reply.send(rotator.halt());
                    }
                    AscomRotatorCommand::IsMoving(reply) => {
                        let _ = reply.send(rotator.is_moving());
                    }
                    AscomRotatorCommand::Sync(position, reply) => {
                        let _ = reply.send(rotator.sync(position));
                    }
                    AscomRotatorCommand::SetReverse(reverse, reply) => {
                        let _ = reply.send(rotator.set_reverse(reverse));
                    }
                    AscomRotatorCommand::GetInterfaceVersion(reply) => {
                        let _ = reply.send(rotator.interface_version());
                    }
                    AscomRotatorCommand::GetDriverVersion(reply) => {
                        let _ = reply.send(rotator.driver_version());
                    }
                    AscomRotatorCommand::GetDriverInfo(reply) => {
                        let _ = reply.send(rotator.driver_info());
                    }
                    AscomRotatorCommand::GetSupportedActions(reply) => {
                        let _ = reply.send(rotator.supported_actions());
                    }
                }
                PumpOutcome::DidWork
            })
                as crate::ascom_wrapper::sta_worker::DevicePump)
        })?;

        Ok(Self {
            sender: tx,
            connected: AtomicBool::new(false),
        })
    }

    async fn recv_with_timeout<T>(
        rx: oneshot::Receiver<Result<T, String>>,
        timeout: Duration,
        operation: &str,
    ) -> Result<T, String> {
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(format!("Worker thread dead during {}", operation)),
            Err(_) => Err(format!(
                "Rotator {} timed out after {:?}",
                operation, timeout
            )),
        }
    }

    pub async fn connect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Connect(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "connect").await;
        if result.is_ok() {
            self.connected.store(true, Ordering::SeqCst);
        }
        result
    }

    pub async fn disconnect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Disconnect(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "disconnect").await;
        if result.is_ok() {
            self.connected.store(false, Ordering::SeqCst);
        }
        result
    }

    pub async fn position(&self) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Position(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "position").await
    }

    pub async fn move_absolute(&self, position: f64) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::MoveAbsolute(position, tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::rotator_move(), "move_absolute").await
    }

    pub async fn halt(&self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Halt(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "halt").await
    }

    pub async fn is_moving(&self) -> Result<bool, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::IsMoving(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "is_moving").await
    }

    /// Sync the reported sky angle to `position` without moving the hardware.
    /// Why a write timeout (not rotator_move): ASCOM Sync only mutates the
    /// driver's mechanical-vs-sky offset and returns promptly — no physical
    /// motion is initiated.
    pub async fn sync(&self, position: f64) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Sync(position, tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "sync").await
    }

    /// Write the IRotatorV3 `Reverse` flag. Property write — returns promptly,
    /// so the property-write timeout applies (no physical motion).
    pub async fn set_reverse(&self, reverse: bool) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::SetReverse(reverse, tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_reverse").await
    }

    /// Returns the ASCOM `InterfaceVersion` integer (ASCOM-Common §IAscomDriverV1).
    pub async fn interface_version(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::GetInterfaceVersion(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Returns the ASCOM `DriverVersion` free-form vendor version string (ASCOM-Common §IAscomDriverV1).
    pub async fn driver_version(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::GetDriverVersion(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_version").await
    }

    /// Returns the ASCOM `DriverInfo` vendor description string (ASCOM-Common §IAscomDriverV1).
    pub async fn driver_info(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::GetDriverInfo(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_info").await
    }

    /// Returns the list of custom action names from ASCOM `SupportedActions` (ASCOM-Common §ISupportedActions, V2+ optional).
    pub async fn supported_actions(&self) -> Result<Vec<String>, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::GetSupportedActions(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "supported_actions").await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn build_test_wrapper<F>(handler: F) -> AscomRotatorWrapper
    where
        F: FnMut(AscomRotatorCommand) -> bool + Send + 'static,
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
        AscomRotatorWrapper {
            sender: tx,
            connected: AtomicBool::new(false),
        }
    }

    #[tokio::test]
    async fn interface_version_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomRotatorCommand::GetInterfaceVersion(reply) = cmd {
                let _ = reply.send(Ok(3));
            }
            false
        });
        assert_eq!(wrapper.interface_version().await.expect("ok"), 3);
    }

    #[tokio::test]
    async fn driver_version_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomRotatorCommand::GetDriverVersion(reply) = cmd {
                let _ = reply.send(Ok("1.2.3".to_string()));
            }
            false
        });
        assert_eq!(wrapper.driver_version().await.expect("ok"), "1.2.3");
    }

    #[tokio::test]
    async fn driver_info_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomRotatorCommand::GetDriverInfo(reply) = cmd {
                let _ = reply.send(Ok("Acme Rotator Driver".to_string()));
            }
            false
        });
        assert_eq!(
            wrapper.driver_info().await.expect("ok"),
            "Acme Rotator Driver"
        );
    }

    #[tokio::test]
    async fn supported_actions_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomRotatorCommand::GetSupportedActions(reply) = cmd {
                let _ = reply.send(Ok(vec!["Reverse".to_string(), "Sync".to_string()]));
            }
            false
        });
        let actions = wrapper.supported_actions().await.expect("ok");
        assert_eq!(actions, vec!["Reverse".to_string(), "Sync".to_string()]);
    }

    #[tokio::test]
    async fn supported_actions_propagates_property_not_implemented_error() {
        // ASCOM 1.x drivers that lack `ISupportedActions` raise
        // `PropertyNotImplementedException`. The wrapper passes the error
        // through unchanged; `fetch_api_version` is responsible for the
        // documented silent-fallback-to-empty-Vec policy at the dispatch layer.
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomRotatorCommand::GetSupportedActions(reply) = cmd {
                let _ = reply.send(Err("PropertyNotImplemented".to_string()));
            }
            false
        });
        assert!(wrapper.supported_actions().await.is_err());
    }
}
