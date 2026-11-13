//! An ASCOM focuser on the STA worker: one command per `IFocuser` member.
//! What the members mean is decided in `device_manager::rig::ascom`.

use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::dispatch::error::DeviceOpError;
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomFocuser;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

type Reply<T> = oneshot::Sender<Result<T, DeviceOpError>>;

enum AscomFocuserCommand {
    Connect(Reply<()>),
    Disconnect(Reply<()>),
    Connected(Reply<bool>),
    Absolute(Reply<bool>),
    Position(Reply<i32>),
    IsMoving(Reply<bool>),
    MaxStep(Reply<i32>),
    MaxIncrement(Reply<i32>),
    StepSize(Reply<f64>),
    TempCompAvailable(Reply<bool>),
    TempComp(Reply<bool>),
    Temperature(Reply<f64>),
    Move(i32, Reply<()>),
    Halt(Reply<()>),
}

pub struct AscomFocuserWrapper {
    sender: mpsc::Sender<AscomFocuserCommand>,
}

impl std::fmt::Debug for AscomFocuserWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AscomFocuserWrapper").finish()
    }
}

impl AscomFocuserWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper.
        register_device(move || {
            let mut focuser = match AscomFocuser::new(&prog_id) {
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
                fn answer<T>(reply: Reply<T>, result: skotiq_ascom::AscomResult<T>) {
                    let _ = reply.send(result.map_err(DeviceOpError::from));
                }
                match cmd {
                    AscomFocuserCommand::Connect(reply) => answer(reply, focuser.connect()),
                    AscomFocuserCommand::Disconnect(reply) => answer(reply, focuser.disconnect()),
                    AscomFocuserCommand::Connected(reply) => answer(reply, focuser.is_connected()),
                    AscomFocuserCommand::Absolute(reply) => answer(reply, focuser.absolute()),
                    AscomFocuserCommand::Position(reply) => answer(reply, focuser.position()),
                    AscomFocuserCommand::IsMoving(reply) => answer(reply, focuser.is_moving()),
                    AscomFocuserCommand::MaxStep(reply) => answer(reply, focuser.max_step()),
                    AscomFocuserCommand::MaxIncrement(reply) => {
                        answer(reply, focuser.max_increment())
                    }
                    AscomFocuserCommand::StepSize(reply) => answer(reply, focuser.step_size()),
                    AscomFocuserCommand::TempCompAvailable(reply) => {
                        answer(reply, focuser.temp_comp_available())
                    }
                    AscomFocuserCommand::TempComp(reply) => answer(reply, focuser.temp_comp()),
                    AscomFocuserCommand::Temperature(reply) => {
                        answer(reply, focuser.temperature())
                    }
                    AscomFocuserCommand::Move(value, reply) => {
                        answer(reply, focuser.move_to(value))
                    }
                    AscomFocuserCommand::Halt(reply) => answer(reply, focuser.halt()),
                }
                PumpOutcome::DidWork
            })
                as crate::ascom_wrapper::sta_worker::DevicePump)
        })?;

        Ok(Self { sender: tx })
    }

    async fn ask<T>(
        &self,
        command: impl FnOnce(Reply<T>) -> AscomFocuserCommand,
        timeout: Duration,
        operation: &str,
    ) -> Result<T, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(command(tx))
            .await
            .map_err(|_| DeviceOpError::not_connected(None, "ASCOM focuser worker has stopped"))?;
        super::recv_with_timeout("Focuser", rx, timeout, operation).await
    }

    pub async fn connect(&self) -> Result<(), DeviceOpError> {
        self.ask(AscomFocuserCommand::Connect, Timeouts::connection(), "connect")
            .await
    }

    pub async fn disconnect(&self) -> Result<(), DeviceOpError> {
        self.ask(AscomFocuserCommand::Disconnect, Timeouts::connection(), "disconnect")
            .await
    }

    pub async fn connected(&self) -> Result<bool, DeviceOpError> {
        self.ask(AscomFocuserCommand::Connected, Timeouts::property_read(), "connected")
            .await
    }

    pub async fn absolute(&self) -> Result<bool, DeviceOpError> {
        self.ask(AscomFocuserCommand::Absolute, Timeouts::property_read(), "absolute")
            .await
    }

    pub async fn position(&self) -> Result<i32, DeviceOpError> {
        self.ask(AscomFocuserCommand::Position, Timeouts::property_read(), "position")
            .await
    }

    pub async fn is_moving(&self) -> Result<bool, DeviceOpError> {
        self.ask(AscomFocuserCommand::IsMoving, Timeouts::property_read(), "is_moving")
            .await
    }

    pub async fn max_step(&self) -> Result<i32, DeviceOpError> {
        self.ask(AscomFocuserCommand::MaxStep, Timeouts::property_read(), "max_step")
            .await
    }

    pub async fn max_increment(&self) -> Result<i32, DeviceOpError> {
        self.ask(
            AscomFocuserCommand::MaxIncrement,
            Timeouts::property_read(),
            "max_increment",
        )
        .await
    }

    pub async fn step_size(&self) -> Result<f64, DeviceOpError> {
        self.ask(AscomFocuserCommand::StepSize, Timeouts::property_read(), "step_size")
            .await
    }

    pub async fn temp_comp_available(&self) -> Result<bool, DeviceOpError> {
        self.ask(
            AscomFocuserCommand::TempCompAvailable,
            Timeouts::property_read(),
            "temp_comp_available",
        )
        .await
    }

    pub async fn temp_comp(&self) -> Result<bool, DeviceOpError> {
        self.ask(AscomFocuserCommand::TempComp, Timeouts::property_read(), "temp_comp")
            .await
    }

    pub async fn temperature(&self) -> Result<f64, DeviceOpError> {
        self.ask(
            AscomFocuserCommand::Temperature,
            Timeouts::property_read(),
            "temperature",
        )
        .await
    }

    /// `Move`. An IFocuserV2 driver may return only when the move is done.
    pub async fn move_to(&self, value: i32) -> Result<(), DeviceOpError> {
        self.ask(
            |reply| AscomFocuserCommand::Move(value, reply),
            Timeouts::focuser_move(),
            "move",
        )
        .await
    }

    pub async fn halt(&self) -> Result<(), DeviceOpError> {
        self.ask(AscomFocuserCommand::Halt, Timeouts::property_write(), "halt")
            .await
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
        AscomFocuserWrapper { sender: tx }
    }

    #[tokio::test]
    async fn a_member_read_is_answered_by_the_worker() {
        let wrapper = build_test_wrapper(|cmd| {
            match cmd {
                AscomFocuserCommand::MaxIncrement(reply) => {
                    let _ = reply.send(Ok(1200));
                }
                AscomFocuserCommand::Connected(reply) => {
                    let _ = reply.send(Err(DeviceOpError::hardware(None, "COM disconnected")));
                    return true;
                }
                _ => {}
            }
            false
        });

        assert_eq!(wrapper.max_increment().await.unwrap(), 1200);
        assert!(
            wrapper.connected().await.is_err(),
            "a failed Connected read reaches the caller"
        );
    }
}
