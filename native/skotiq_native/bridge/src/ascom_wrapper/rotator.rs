use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::dispatch::error::DeviceOpError;
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomRotator;
use std::sync::atomic::{AtomicBool, Ordering};
use tokio::sync::{mpsc, oneshot};

enum AscomRotatorCommand {
    Connect(oneshot::Sender<Result<(), DeviceOpError>>),
    Disconnect(oneshot::Sender<Result<(), DeviceOpError>>),
    Position(oneshot::Sender<Result<f64, DeviceOpError>>),
    MoveAbsolute(f64, oneshot::Sender<Result<(), DeviceOpError>>),
    Halt(oneshot::Sender<Result<(), DeviceOpError>>),
    IsMoving(oneshot::Sender<Result<bool, DeviceOpError>>),
    Sync(f64, oneshot::Sender<Result<(), DeviceOpError>>),
    SetReverse(bool, oneshot::Sender<Result<(), DeviceOpError>>),
    InterfaceVersion(oneshot::Sender<Result<i32, DeviceOpError>>),
    MechanicalPosition(oneshot::Sender<Result<f64, DeviceOpError>>),
    Connected(oneshot::Sender<Result<bool, DeviceOpError>>),
    CanReverse(oneshot::Sender<Result<bool, DeviceOpError>>),
    Reverse(oneshot::Sender<Result<bool, DeviceOpError>>),
    StepSize(oneshot::Sender<Result<f64, DeviceOpError>>),
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
                        let _ = reply.send(rotator.connect().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::Disconnect(reply) => {
                        let _ = reply.send(rotator.disconnect().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::Position(reply) => {
                        let _ = reply.send(rotator.position().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::MoveAbsolute(position, reply) => {
                        let _ =
                            reply.send(rotator.move_absolute(position).map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::Halt(reply) => {
                        let _ = reply.send(rotator.halt().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::IsMoving(reply) => {
                        let _ = reply.send(rotator.is_moving().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::Sync(position, reply) => {
                        let _ = reply.send(rotator.sync(position).map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::SetReverse(reverse, reply) => {
                        let _ = reply.send(rotator.set_reverse(reverse).map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::InterfaceVersion(reply) => {
                        let _ = reply.send(rotator.interface_version().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::MechanicalPosition(reply) => {
                        let _ = reply.send(rotator.mechanical_position().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::Connected(reply) => {
                        let _ = reply.send(rotator.is_connected().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::CanReverse(reply) => {
                        let _ = reply.send(rotator.can_reverse().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::Reverse(reply) => {
                        let _ = reply.send(rotator.reverse().map_err(DeviceOpError::from));
                    }
                    AscomRotatorCommand::StepSize(reply) => {
                        let _ = reply.send(rotator.step_size().map_err(DeviceOpError::from));
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

    pub async fn connect(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Connect(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        let result = super::recv_with_timeout("Rotator", rx, Timeouts::connection(), "connect").await;
        if result.is_ok() {
            self.connected.store(true, Ordering::SeqCst);
        }
        result
    }

    pub async fn disconnect(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Disconnect(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        let result = super::recv_with_timeout("Rotator", rx, Timeouts::connection(), "disconnect").await;
        if result.is_ok() {
            self.connected.store(false, Ordering::SeqCst);
        }
        result
    }

    pub async fn position(&self) -> Result<f64, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Position(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_read(), "position").await
    }

    pub async fn move_absolute(&self, position: f64) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::MoveAbsolute(position, tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::rotator_move(), "move_absolute").await
    }

    pub async fn halt(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Halt(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_write(), "halt").await
    }

    pub async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::IsMoving(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_read(), "is_moving").await
    }

    /// Sync the reported sky angle to `position` without moving the hardware.
    /// Why a write timeout (not rotator_move): ASCOM Sync only mutates the
    /// driver's mechanical-vs-sky offset and returns promptly — no physical
    /// motion is initiated.
    pub async fn sync(&self, position: f64) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Sync(position, tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_write(), "sync").await
    }

    /// Write the IRotatorV3 `Reverse` flag. Property write — returns promptly,
    /// so the property-write timeout applies (no physical motion).
    pub async fn set_reverse(&self, reverse: bool) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::SetReverse(reverse, tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_write(), "set_reverse").await
    }

    /// The ASCOM `InterfaceVersion`; `Sync` and `MechanicalPosition` arrived in
    /// IRotatorV3.
    pub async fn interface_version(&self) -> Result<i32, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::InterfaceVersion(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_read(), "interface_version").await
    }

    /// Degrees the mechanism is at, before any sync offset.
    pub async fn mechanical_position(&self) -> Result<f64, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::MechanicalPosition(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_read(), "mechanical_position").await
    }

    /// Fails with NotConnected when the driver says it is not connected.
    pub async fn heartbeat(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Connected(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        let connected =
            super::recv_with_timeout("Rotator", rx, Timeouts::property_read(), "connected").await?;
        if connected {
            Ok(())
        } else {
            Err(DeviceOpError::not_connected(
                None,
                "The ASCOM rotator reports Connected = false",
            ))
        }
    }

    pub async fn can_reverse(&self) -> Result<bool, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::CanReverse(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_read(), "can_reverse").await
    }

    pub async fn reverse(&self) -> Result<bool, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::Reverse(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_read(), "reverse").await
    }

    /// Degrees per step.
    pub async fn step_size(&self) -> Result<f64, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomRotatorCommand::StepSize(tx))
            .await
            .map_err(|error| format!("Send error: {}", error))?;
        super::recv_with_timeout("Rotator", rx, Timeouts::property_read(), "step_size").await
    }
}
