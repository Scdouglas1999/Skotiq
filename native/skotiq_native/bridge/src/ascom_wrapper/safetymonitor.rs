use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomSafetyMonitor;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

enum AscomSafetyMonitorCommand {
    Connect(oneshot::Sender<Result<(), String>>),
    Disconnect(oneshot::Sender<Result<(), String>>),
    IsSafe(oneshot::Sender<Result<bool, String>>),
    // ASCOM-Common metadata query commands. Mirrors the four
    // `InterfaceVersion` / `DriverVersion` / `DriverInfo` /
    // `SupportedActions` properties common to every ASCOM driver and is
    // consumed by `DeviceCommonMetadata` via `dispatch::ascom_device_common`.
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    GetDriverVersion(oneshot::Sender<Result<String, String>>),
    GetDriverInfo(oneshot::Sender<Result<String, String>>),
    GetSupportedActions(oneshot::Sender<Result<Vec<String>, String>>),
}

pub struct AscomSafetyMonitorWrapper {
    sender: mpsc::Sender<AscomSafetyMonitorCommand>,
    connected: AtomicBool,
}

impl AscomSafetyMonitorWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper, exactly as the legacy init-channel did.
        register_device(move || {
            let mut safety_monitor = match AscomSafetyMonitor::new(&prog_id_clone) {
                Ok(safety_monitor) => safety_monitor,
                Err(error) => {
                    return Err(format!("Failed to create ASCOM safety monitor: {}", error));
                }
            };

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let command = match rx.try_recv() {
                    Ok(command) => command,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM teardown ordering — the typed
                        // `AscomSafetyMonitor` (and its IDispatch) is released
                        // when this closure is dropped, still on the STA worker
                        // thread that owns the apartment. The apartment persists
                        // for the process lifetime, so COM is NOT uninitialized
                        // here.
                        return PumpOutcome::Finished;
                    }
                };
                match command {
                    AscomSafetyMonitorCommand::Connect(reply) => {
                        let _ = reply.send(safety_monitor.connect());
                    }
                    AscomSafetyMonitorCommand::Disconnect(reply) => {
                        let _ = reply.send(safety_monitor.disconnect());
                    }
                    AscomSafetyMonitorCommand::IsSafe(reply) => {
                        let _ = reply.send(safety_monitor.is_safe());
                    }
                    AscomSafetyMonitorCommand::GetInterfaceVersion(reply) => {
                        let _ = reply.send(safety_monitor.interface_version());
                    }
                    AscomSafetyMonitorCommand::GetDriverVersion(reply) => {
                        let _ = reply.send(safety_monitor.driver_version());
                    }
                    AscomSafetyMonitorCommand::GetDriverInfo(reply) => {
                        let _ = reply.send(safety_monitor.driver_info());
                    }
                    AscomSafetyMonitorCommand::GetSupportedActions(reply) => {
                        let _ = reply.send(safety_monitor.supported_actions());
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
                "Safety monitor {} timed out after {:?}",
                operation, timeout
            )),
        }
    }

    pub async fn connect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSafetyMonitorCommand::Connect(tx))
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
            .send(AscomSafetyMonitorCommand::Disconnect(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "disconnect").await;
        if result.is_ok() {
            self.connected.store(false, Ordering::SeqCst);
        }
        result
    }

    pub async fn is_safe(&self) -> Result<bool, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSafetyMonitorCommand::IsSafe(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "is_safe").await
    }

    /// Returns the ASCOM `InterfaceVersion` integer (ASCOM-Common §IAscomDriverV1).
    pub async fn interface_version(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSafetyMonitorCommand::GetInterfaceVersion(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Returns the ASCOM `DriverVersion` free-form vendor version string (ASCOM-Common §IAscomDriverV1).
    pub async fn driver_version(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSafetyMonitorCommand::GetDriverVersion(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_version").await
    }

    /// Returns the ASCOM `DriverInfo` vendor description string (ASCOM-Common §IAscomDriverV1).
    pub async fn driver_info(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSafetyMonitorCommand::GetDriverInfo(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_info").await
    }

    /// Returns the list of custom action names from ASCOM `SupportedActions` (ASCOM-Common §ISupportedActions, V2+ optional).
    pub async fn supported_actions(&self) -> Result<Vec<String>, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomSafetyMonitorCommand::GetSupportedActions(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "supported_actions").await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn build_test_wrapper<F>(handler: F) -> AscomSafetyMonitorWrapper
    where
        F: FnMut(AscomSafetyMonitorCommand) -> bool + Send + 'static,
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
        AscomSafetyMonitorWrapper {
            sender: tx,
            connected: AtomicBool::new(false),
        }
    }

    #[tokio::test]
    async fn interface_version_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomSafetyMonitorCommand::GetInterfaceVersion(reply) = cmd {
                let _ = reply.send(Ok(1));
            }
            false
        });
        assert_eq!(wrapper.interface_version().await.expect("ok"), 1);
    }

    #[tokio::test]
    async fn driver_version_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomSafetyMonitorCommand::GetDriverVersion(reply) = cmd {
                let _ = reply.send(Ok("4.5".to_string()));
            }
            false
        });
        assert_eq!(wrapper.driver_version().await.expect("ok"), "4.5");
    }

    #[tokio::test]
    async fn driver_info_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomSafetyMonitorCommand::GetDriverInfo(reply) = cmd {
                let _ = reply.send(Ok("Acme Safety Monitor".to_string()));
            }
            false
        });
        assert_eq!(
            wrapper.driver_info().await.expect("ok"),
            "Acme Safety Monitor"
        );
    }

    #[tokio::test]
    async fn supported_actions_returns_worker_value() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomSafetyMonitorCommand::GetSupportedActions(reply) = cmd {
                let _ = reply.send(Ok(vec!["RaiseAlarm".to_string()]));
            }
            false
        });
        let actions = wrapper.supported_actions().await.expect("ok");
        assert_eq!(actions, vec!["RaiseAlarm".to_string()]);
    }

    #[tokio::test]
    async fn supported_actions_propagates_property_not_implemented_error() {
        // ASCOM 1.x drivers without `ISupportedActions` raise
        // `PropertyNotImplementedException`. The wrapper passes the error
        // through unchanged; `fetch_api_version` is responsible for the
        // documented silent-fallback-to-empty-Vec policy at the dispatch layer.
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomSafetyMonitorCommand::GetSupportedActions(reply) = cmd {
                let _ = reply.send(Err("PropertyNotImplemented".to_string()));
            }
            false
        });
        assert!(wrapper.supported_actions().await.is_err());
    }
}
