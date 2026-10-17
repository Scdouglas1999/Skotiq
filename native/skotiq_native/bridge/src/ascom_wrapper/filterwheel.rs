use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomFilterWheel;
use skotiq_native::traits::{NativeDevice, NativeError, NativeFilterWheel};
use skotiq_native::NativeVendor;
use std::fmt::Debug;
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

#[derive(Debug)]
enum AscomFilterWheelCommand {
    Connect(oneshot::Sender<Result<i32, String>>), // Returns filter count on success
    Disconnect(oneshot::Sender<Result<(), String>>),
    SetPosition(i32, oneshot::Sender<Result<(), String>>),
    GetPosition(oneshot::Sender<Result<i32, String>>),
    GetNames(oneshot::Sender<Result<Vec<String>, String>>),
    // Version query commands
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    GetDriverVersion(oneshot::Sender<Result<String, String>>),
    GetDriverInfo(oneshot::Sender<Result<String, String>>),
    GetSupportedActions(oneshot::Sender<Result<Vec<String>, String>>),
    Heartbeat(oneshot::Sender<Result<(), String>>),
}

pub struct AscomFilterWheelWrapper {
    id: String,
    name: String,
    sender: mpsc::Sender<AscomFilterWheelCommand>,
    connected: AtomicBool,
    // Cache filter count - updated after connect when we can actually read device properties.
    filter_count: AtomicI32,
}

impl Debug for AscomFilterWheelWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AscomFilterWheelWrapper")
            .field("id", &self.id)
            .field("name", &self.name)
            .finish()
    }
}

impl AscomFilterWheelWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper, exactly as the legacy init-channel did.
        register_device(move || {
            let mut fw = match AscomFilterWheel::new(&prog_id_clone) {
                Ok(f) => f,
                Err(e) => {
                    return Err(format!("Failed to create ASCOM filter wheel: {}", e));
                }
            };

            // Don't read names() here - the device isn't connected yet.
            // Filter count will be updated after connect() when we can actually
            // read device properties.
            tracing::info!(
                "ASCOM FilterWheel COM object created for: {}",
                prog_id_clone
            );

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
                match cmd {
                    AscomFilterWheelCommand::Connect(reply) => {
                        let result = fw.connect().map_err(|e| e.to_string()).and_then(|()| {
                            // Why: Names is the source of truth for filter count and
                            // is required to populate saved-profile filter offsets. If
                            // it errors, returning a zero-count silently breaks every
                            // downstream filter operation; the device
                            // must be marked unusable, so we propagate and force the
                            // caller (bridge dispatch) to drop the wrapper before it
                            // is registered.
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
                                msg
                            })?;
                            // Why: physical filter wheel
                            // slot counts are ≤ 16; usize → i32 SAFE.
                            let count = i32::try_from(names.len()).unwrap_or(i32::MAX);
                            tracing::info!(
                                "ASCOM FilterWheel connected with {} filters: {:?}",
                                count,
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

                            Ok(count)
                        });
                        let _ = reply.send(result);
                    }
                    AscomFilterWheelCommand::Disconnect(reply) => {
                        let _ = reply.send(fw.disconnect().map_err(|e| e.to_string()));
                    }
                    AscomFilterWheelCommand::SetPosition(pos, reply) => {
                        let _ = reply.send(fw.set_position(pos).map_err(|e| e.to_string()));
                    }
                    AscomFilterWheelCommand::GetPosition(reply) => {
                        let result = fw.position().map_err(|e| e.to_string());
                        match &result {
                            Ok(pos) => {
                                tracing::info!("[ASCOM FW] GetPosition returned position={}", pos)
                            }
                            Err(e) => tracing::error!("[ASCOM FW] GetPosition failed: {}", e),
                        }
                        let _ = reply.send(result);
                    }
                    AscomFilterWheelCommand::GetNames(reply) => {
                        let result = fw.names();
                        match &result {
                            Ok(names) => tracing::info!(
                                "ASCOM FilterWheel GetNames returned {} filters: {:?}",
                                names.len(),
                                names
                            ),
                            Err(e) => tracing::error!("ASCOM FilterWheel GetNames failed: {}", e),
                        }
                        let _ = reply.send(result.map_err(|e| e.to_string()));
                    }
                    AscomFilterWheelCommand::GetInterfaceVersion(reply) => {
                        let _ = reply.send(fw.interface_version());
                    }
                    AscomFilterWheelCommand::GetDriverVersion(reply) => {
                        let _ = reply.send(fw.driver_version());
                    }
                    AscomFilterWheelCommand::GetDriverInfo(reply) => {
                        let _ = reply.send(fw.driver_info());
                    }
                    AscomFilterWheelCommand::GetSupportedActions(reply) => {
                        let _ = reply.send(fw.supported_actions());
                    }
                    AscomFilterWheelCommand::Heartbeat(reply) => {
                        let _ = reply.send(fw.heartbeat().map_err(|e| e.to_string()));
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
            connected: AtomicBool::new(false),
            filter_count: AtomicI32::new(0),
        })
    }

    /// Helper to receive a response with a timeout
    async fn recv_with_timeout<T>(
        rx: oneshot::Receiver<Result<T, String>>,
        timeout: Duration,
        operation: &str,
    ) -> Result<T, NativeError> {
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result.map_err(|e| NativeError::SdkError(e)),
            Ok(Err(_recv_err)) => Err(NativeError::Unknown(format!(
                "Worker thread dead during {}",
                operation
            ))),
            Err(_elapsed) => Err(NativeError::Timeout(format!(
                "FilterWheel {} timed out after {:?}",
                operation, timeout
            ))),
        }
    }
}

#[async_trait::async_trait]
impl NativeDevice for AscomFilterWheelWrapper {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        NativeVendor::Ascom
    }

    fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::Connect(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        let result: Result<i32, NativeError> =
            Self::recv_with_timeout(rx, Timeouts::connection(), "connect").await;
        match result {
            Ok(count) => {
                self.connected.store(true, Ordering::SeqCst);
                self.filter_count.store(count, Ordering::SeqCst);
                Ok(())
            }
            Err(e) => Err(e),
        }
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::Disconnect(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "disconnect").await;
        if result.is_ok() {
            self.connected.store(false, Ordering::SeqCst);
        }
        result
    }
}

#[async_trait::async_trait]
impl NativeFilterWheel for AscomFilterWheelWrapper {
    async fn move_to_position(&mut self, position: i32) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::SetPosition(position, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        // Filter wheel rotation can take time
        Self::recv_with_timeout(rx, Timeouts::filter_wheel(), "move_to_position").await
    }

    async fn get_position(&self) -> Result<i32, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::GetPosition(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_position").await
    }

    async fn is_moving(&self) -> Result<bool, NativeError> {
        // ASCOM Position returns -1 if moving
        let pos = self.get_position().await?;
        Ok(pos == -1)
    }

    fn get_filter_count(&self) -> i32 {
        self.filter_count.load(Ordering::SeqCst)
    }

    async fn get_filter_names(&self) -> Result<Vec<String>, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::GetNames(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_filter_names").await
    }

    async fn set_filter_name(&mut self, _position: i32, _name: String) -> Result<(), NativeError> {
        Err(NativeError::NotSupported)
    }
}

// Version query methods
impl AscomFilterWheelWrapper {
    pub async fn heartbeat(&self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::Heartbeat(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "heartbeat").await
    }

    /// Get the ASCOM interface version number
    pub async fn interface_version(&self) -> Result<i32, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::GetInterfaceVersion(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Get the driver version string
    pub async fn driver_version(&self) -> Result<String, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::GetDriverVersion(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_version").await
    }

    /// Get the driver info/description
    pub async fn driver_info(&self) -> Result<String, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::GetDriverInfo(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_info").await
    }

    /// Get the list of supported actions
    pub async fn supported_actions(&self) -> Result<Vec<String>, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomFilterWheelCommand::GetSupportedActions(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "supported_actions").await
    }
}

//
// Why: `new()` spawns a real STA thread that requires Windows COM to load the
// ASCOM driver. The tests below build a wrapper struct directly with a mock
// worker thread that intercepts `AscomFilterWheelCommand` messages, so we can
// exercise the public `connect`/`disconnect` API without any COM dependency.
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

        AscomFilterWheelWrapper {
            id: "test-fw".to_string(),
            name: "Test FW".to_string(),
            sender: tx,
            connected: AtomicBool::new(false),
            filter_count: AtomicI32::new(0),
        }
    }

    /// when the worker reports a `Names` failure during connect,
    /// `connect()` must return Err and leave the wrapper in the disconnected
    /// state. The bridge dispatch in `devices.rs` propagates this error and
    /// drops the wrapper, so the device is effectively marked unusable.
    #[tokio::test]
    async fn test_connect_propagates_names_failure() {
        let mut wrapper = build_test_wrapper(move |cmd| {
            if let AscomFilterWheelCommand::Connect(reply) = cmd {
                let _ = reply.send(Err(
                    "ASCOM FilterWheel `Names` query failed after connect: COM error 0x80004005"
                        .to_string(),
                ));
                return true;
            }
            false
        });

        let result = wrapper.connect().await;
        assert!(result.is_err(), "Names failure must propagate as Err");
        match result.unwrap_err() {
            NativeError::SdkError(msg) => {
                assert!(
                    msg.contains("Names"),
                    "error message should mention Names property, got: {}",
                    msg
                );
            }
            other => panic!("expected SdkError, got {:?}", other),
        }
        assert!(!wrapper.is_connected(), "wrapper must remain disconnected");
        assert_eq!(
            wrapper.get_filter_count(),
            0,
            "filter count must remain zero after failed connect"
        );
    }

    /// Sanity check that the connect path stores the filter count when the
    /// worker reports success. This guards against regressions where a future
    /// refactor of the Result chain might silently drop the count.
    #[tokio::test]
    async fn test_connect_success_records_filter_count() {
        let mut wrapper = build_test_wrapper(move |cmd| {
            if let AscomFilterWheelCommand::Connect(reply) = cmd {
                let _ = reply.send(Ok(7));
                return true;
            }
            false
        });

        wrapper.connect().await.expect("connect should succeed");
        assert!(wrapper.is_connected());
        assert_eq!(wrapper.get_filter_count(), 7);
    }

    #[tokio::test]
    async fn test_heartbeat_uses_worker_command() {
        let wrapper = build_test_wrapper(move |cmd| {
            if let AscomFilterWheelCommand::Heartbeat(reply) = cmd {
                let _ = reply.send(Err("COM disconnected".to_string()));
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
