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
                        let _ = reply.send(safety_monitor.connect().map_err(|e| e.to_string()));
                    }
                    AscomSafetyMonitorCommand::Disconnect(reply) => {
                        let _ = reply.send(safety_monitor.disconnect().map_err(|e| e.to_string()));
                    }
                    AscomSafetyMonitorCommand::IsSafe(reply) => {
                        let _ = reply.send(safety_monitor.is_safe().map_err(|e| e.to_string()));
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
}
