//! An ASCOM filter wheel on the STA worker: one command per `IFilterWheel`
//! member. What the members mean is decided in `device_manager::rig::ascom`.

use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::dispatch::DeviceOpError;
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomFilterWheel;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

type Reply<T> = oneshot::Sender<Result<T, DeviceOpError>>;

enum AscomFilterWheelCommand {
    Connect(Reply<()>),
    Disconnect(Reply<()>),
    Connected(Reply<bool>),
    Position(Reply<i32>),
    SetPosition(i32, Reply<()>),
    Names(Reply<Vec<String>>),
    FocusOffsets(Reply<Vec<i32>>),
}

pub struct AscomFilterWheelWrapper {
    sender: mpsc::Sender<AscomFilterWheelCommand>,
}

impl std::fmt::Debug for AscomFilterWheelWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AscomFilterWheelWrapper").finish()
    }
}

impl AscomFilterWheelWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper.
        register_device(move || {
            let mut fw = match AscomFilterWheel::new(&prog_id) {
                Ok(f) => f,
                Err(e) => {
                    return Err(format!("Failed to create ASCOM filter wheel: {}", e));
                }
            };
            tracing::info!("ASCOM FilterWheel COM object created for: {}", prog_id);

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let cmd = match rx.try_recv() {
                    Ok(cmd) => cmd,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM teardown ordering — issue the final disconnect
                        // on the STA worker thread that owns the apartment. The
                        // typed `AscomFilterWheel` (and its IDispatch) is then
                        // released when this closure is dropped, still on this
                        // thread. The apartment persists for the process
                        // lifetime, so COM is NOT uninitialized here.
                        if let Err(e) = fw.disconnect() {
                            tracing::warn!(
                                "ASCOM filter wheel STA-worker shutdown disconnect failed: {}",
                                e
                            );
                        }
                        return PumpOutcome::Finished;
                    }
                };
                fn answer<T>(reply: Reply<T>, result: skotiq_ascom::AscomResult<T>) {
                    let _ = reply.send(result.map_err(DeviceOpError::from));
                }
                match cmd {
                    AscomFilterWheelCommand::Connect(reply) => {
                        let result = fw.connect().map_err(DeviceOpError::from).and_then(|()| {
                            // Why: Names is the source of truth for the slot
                            // count. A wheel whose Names throws is unusable, so
                            // the connect fails and the caller drops the wrapper
                            // before it is registered.
                            let names = fw.names().map_err(|e| {
                                let msg = format!(
                                    "ASCOM FilterWheel `Names` query failed after connect: {}",
                                    e
                                );
                                tracing::error!("{}", msg);
                                if let Err(d) = fw.disconnect() {
                                    tracing::warn!(
                                        "ASCOM FilterWheel disconnect after Names failure failed: {}",
                                        d
                                    );
                                }
                                DeviceOpError::caused_by(None, msg, e)
                            })?;
                            tracing::info!(
                                "ASCOM FilterWheel connected with {} filters: {:?}",
                                names.len(),
                                names
                            );

                            // Give the ASCOM driver a moment to settle, then
                            // read initial position for diagnostic logging.
                            std::thread::sleep(std::time::Duration::from_millis(500));
                            match fw.position() {
                                Ok(pos) => tracing::info!(
                                    "[ASCOM FW] Post-connect initial position read: {}",
                                    pos
                                ),
                                Err(e) => tracing::warn!(
                                    "[ASCOM FW] Post-connect position read failed: {}",
                                    e
                                ),
                            }
                            Ok(())
                        });
                        let _ = reply.send(result);
                    }
                    AscomFilterWheelCommand::Disconnect(reply) => answer(reply, fw.disconnect()),
                    AscomFilterWheelCommand::Connected(reply) => answer(reply, fw.is_connected()),
                    AscomFilterWheelCommand::Position(reply) => {
                        let result = fw.position();
                        if let Err(e) = &result {
                            tracing::error!("[ASCOM FW] GetPosition failed: {}", e);
                        }
                        answer(reply, result)
                    }
                    AscomFilterWheelCommand::SetPosition(slot, reply) => {
                        answer(reply, fw.set_position(slot))
                    }
                    AscomFilterWheelCommand::Names(reply) => {
                        let result = fw.names();
                        if let Err(e) = &result {
                            tracing::error!("ASCOM FilterWheel GetNames failed: {}", e);
                        }
                        answer(reply, result)
                    }
                    AscomFilterWheelCommand::FocusOffsets(reply) => {
                        answer(reply, fw.focus_offsets())
                    }
                }
                PumpOutcome::DidWork
            })
                as crate::ascom_wrapper::sta_worker::DevicePump)
        })?;

        Ok(Self { sender: tx })
    }

    async fn ask<T>(
        &self,
        command: impl FnOnce(Reply<T>) -> AscomFilterWheelCommand,
        timeout: Duration,
        operation: &str,
    ) -> Result<T, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender.send(command(tx)).await.map_err(|_| {
            DeviceOpError::not_connected(None, "ASCOM filter wheel worker has stopped")
        })?;
        super::recv_with_timeout("FilterWheel", rx, timeout, operation).await
    }

    pub async fn connect(&self) -> Result<(), DeviceOpError> {
        self.ask(AscomFilterWheelCommand::Connect, Timeouts::connection(), "connect")
            .await
    }

    pub async fn disconnect(&self) -> Result<(), DeviceOpError> {
        self.ask(
            AscomFilterWheelCommand::Disconnect,
            Timeouts::connection(),
            "disconnect",
        )
        .await
    }

    pub async fn connected(&self) -> Result<bool, DeviceOpError> {
        self.ask(
            AscomFilterWheelCommand::Connected,
            Timeouts::property_read(),
            "connected",
        )
        .await
    }

    pub async fn position(&self) -> Result<i32, DeviceOpError> {
        self.ask(
            AscomFilterWheelCommand::Position,
            Timeouts::property_read(),
            "get_position",
        )
        .await
    }

    /// `Position` set. An IFilterWheelV2 driver may return only once the
    /// wheel is there.
    pub async fn set_position(&self, slot: i32) -> Result<(), DeviceOpError> {
        self.ask(
            |reply| AscomFilterWheelCommand::SetPosition(slot, reply),
            Timeouts::filter_wheel(),
            "move_to_position",
        )
        .await
    }

    pub async fn names(&self) -> Result<Vec<String>, DeviceOpError> {
        self.ask(
            AscomFilterWheelCommand::Names,
            Timeouts::property_read(),
            "get_filter_names",
        )
        .await
    }

    pub async fn focus_offsets(&self) -> Result<Vec<i32>, DeviceOpError> {
        self.ask(
            AscomFilterWheelCommand::FocusOffsets,
            Timeouts::property_read(),
            "get_focus_offsets",
        )
        .await
    }
}

//
// Why: `new()` spawns a real STA thread that requires Windows COM to load the
// ASCOM driver. The tests below build a wrapper struct directly with a mock
// worker thread that intercepts `AscomFilterWheelCommand` messages, so we can
// exercise the public API without any COM dependency.
#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn build_test_wrapper<F>(handler: F) -> AscomFilterWheelWrapper
    where
        F: FnMut(AscomFilterWheelCommand) -> bool + Send + 'static,
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
        AscomFilterWheelWrapper { sender: tx }
    }

    /// When the worker reports a `Names` failure during connect, `connect()`
    /// fails with it; the bridge dispatch then drops the wrapper, so the
    /// device is never registered.
    #[tokio::test]
    async fn test_connect_propagates_names_failure() {
        let wrapper = build_test_wrapper(move |cmd| {
            if let AscomFilterWheelCommand::Connect(reply) = cmd {
                let _ = reply.send(Err(DeviceOpError::hardware(
                    None,
                    "ASCOM FilterWheel `Names` query failed after connect: COM error 0x80004005",
                )));
                return true;
            }
            false
        });

        let error = wrapper.connect().await.expect_err("Names failure must propagate");
        assert!(error.to_string().contains("Names"), "{error}");
    }

    #[tokio::test]
    async fn focus_offsets_are_read_from_the_driver() {
        let wrapper = build_test_wrapper(move |cmd| {
            if let AscomFilterWheelCommand::FocusOffsets(reply) = cmd {
                let _ = reply.send(Ok(vec![0, 120, 240]));
                return true;
            }
            false
        });
        assert_eq!(wrapper.focus_offsets().await.unwrap(), vec![0, 120, 240]);
    }
}
