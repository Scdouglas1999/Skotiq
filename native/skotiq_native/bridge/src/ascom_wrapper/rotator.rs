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
    InterfaceVersion(oneshot::Sender<Result<i32, String>>),
    MechanicalPosition(oneshot::Sender<Result<f64, String>>),
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
                        let _ = reply.send(rotator.connect().map_err(|e| e.to_string()));
                    }
                    AscomRotatorCommand::Disconnect(reply) => {
                        let _ = reply.send(rotator.disconnect().map_err(|e| e.to_string()));
                    }
                    AscomRotatorCommand::Position(reply) => {
                        let _ = reply.send(rotator.position().map_err(|e| e.to_string()));
                    }
                    AscomRotatorCommand::MoveAbsolute(position, reply) => {
                        let _ =
                            reply.send(rotator.move_absolute(position).map_err(|e| e.to_string()));
                    }
                    AscomRotatorCommand::Halt(reply) => {
                        let _ = reply.send(rotator.halt().map_err(|e| e.to_string()));
                    }
                    AscomRotatorCommand::IsMoving(reply) => {
                        let _ = reply.send(rotator.is_moving().map_err(|e| e.to_string()));
                    }
                    AscomRotatorCommand::Sync(position, reply) => {
                        let _ = reply.send(rotator.sync(position).map_err(|e| e.to_string()));
                    }
                    AscomRotatorCommand::SetReverse(reverse, reply) => {
                        let _ = reply.send(rotator.set_reverse(reverse).map_err(|e| e.to_string()));
                    }
                    AscomRotatorCommand::InterfaceVersion(reply) => {
                        let _ = reply.send(rotator.interface_version().map_err(|e| e.to_string()));
                    }
                    AscomRotatorCommand::MechanicalPosition(reply) => {
                        let _ = reply.send(rotator.mechanical_position().map_err(|e| e.to_string()));
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

    pub async fn connect(&self) -> Result<(), String> {
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

    pub async fn disconnect(&self) -> Result<(), String> {
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

    /// The ASCOM `InterfaceVersion`; `CanReverse` and `Sync` arrived in IRotatorV3.
    pub async fn interface_version(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::InterfaceVersion(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Degrees the mechanism is at, before any sync offset.
    pub async fn mechanical_position(&self) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::MechanicalPosition(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "mechanical_position").await
    }
}
