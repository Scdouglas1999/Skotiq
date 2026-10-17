use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomDome;
use std::fmt::Debug;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

#[derive(Debug)]
enum AscomDomeCommand {
    Connect(oneshot::Sender<Result<(), String>>),
    Disconnect(oneshot::Sender<Result<(), String>>),
    OpenShutter(oneshot::Sender<Result<(), String>>),
    CloseShutter(oneshot::Sender<Result<(), String>>),
    Park(oneshot::Sender<Result<(), String>>),
    GetShutterStatus(oneshot::Sender<Result<i32, String>>),
    GetSlewing(oneshot::Sender<Result<bool, String>>),
    GetAtPark(oneshot::Sender<Result<bool, String>>),
    GetAzimuth(oneshot::Sender<Result<f64, String>>),
    SlewToAzimuth {
        azimuth: f64,
        reply: oneshot::Sender<Result<(), String>>,
    },
    AbortSlew(oneshot::Sender<Result<(), String>>),
    FindHome(oneshot::Sender<Result<(), String>>),
    SetSlaved {
        slaved: bool,
        reply: oneshot::Sender<Result<(), String>>,
    },
    // Version query commands
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    GetDriverVersion(oneshot::Sender<Result<String, String>>),
    GetDriverInfo(oneshot::Sender<Result<String, String>>),
    GetSupportedActions(oneshot::Sender<Result<Vec<String>, String>>),
    Heartbeat(oneshot::Sender<Result<(), String>>),
}

pub struct AscomDomeWrapper {
    id: String,
    name: String,
    sender: mpsc::Sender<AscomDomeCommand>,
    connected: AtomicBool,
}

impl Debug for AscomDomeWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AscomDomeWrapper")
            .field("id", &self.id)
            .field("name", &self.name)
            .finish()
    }
}

impl AscomDomeWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // The device's friendly `Name` is read at construction (before connect)
        // and ferried back to `new()` over this channel. `register_device` owns
        // the success/error signalling; this side channel only carries the
        // construction-time property payload the legacy init channel returned.
        let (info_tx, info_rx) = std::sync::mpsc::channel();

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper, exactly as the legacy init-channel did.
        register_device(move || {
            let mut dome = match AscomDome::new(&prog_id_clone) {
                Ok(d) => d,
                Err(e) => {
                    return Err(format!("Failed to create ASCOM dome: {}", e));
                }
            };

            // Try to get the device name
            let name = dome.name().unwrap_or_else(|_| prog_id_clone.clone());
            let _ = info_tx.send(name);

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let cmd = match rx.try_recv() {
                    Ok(cmd) => cmd,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM teardown ordering — the typed `AscomDome`
                        // (and its IDispatch) is released when this closure is
                        // dropped, still on the STA worker thread that owns the
                        // apartment. The apartment persists for the process
                        // lifetime, so COM is NOT uninitialized here.
                        return PumpOutcome::Finished;
                    }
                };
                match cmd {
                    AscomDomeCommand::Connect(reply) => {
                        let _ = reply.send(dome.connect());
                    }
                    AscomDomeCommand::Disconnect(reply) => {
                        let _ = reply.send(dome.disconnect());
                    }
                    AscomDomeCommand::OpenShutter(reply) => {
                        let _ = reply.send(dome.open_shutter());
                    }
                    AscomDomeCommand::CloseShutter(reply) => {
                        let _ = reply.send(dome.close_shutter());
                    }
                    AscomDomeCommand::Park(reply) => {
                        let _ = reply.send(dome.park());
                    }
                    AscomDomeCommand::GetShutterStatus(reply) => {
                        let _ = reply.send(dome.shutter_status());
                    }
                    AscomDomeCommand::GetSlewing(reply) => {
                        let _ = reply.send(dome.slewing());
                    }
                    AscomDomeCommand::GetAtPark(reply) => {
                        let _ = reply.send(dome.at_park());
                    }
                    AscomDomeCommand::GetAzimuth(reply) => {
                        let _ = reply.send(dome.azimuth());
                    }
                    AscomDomeCommand::SlewToAzimuth { azimuth, reply } => {
                        let _ = reply.send(dome.slew_to_azimuth(azimuth));
                    }
                    AscomDomeCommand::AbortSlew(reply) => {
                        let _ = reply.send(dome.abort_slew());
                    }
                    AscomDomeCommand::FindHome(reply) => {
                        let _ = reply.send(dome.find_home());
                    }
                    AscomDomeCommand::SetSlaved { slaved, reply } => {
                        let _ = reply.send(dome.set_slaved(slaved));
                    }
                    AscomDomeCommand::GetInterfaceVersion(reply) => {
                        let _ = reply.send(dome.interface_version());
                    }
                    AscomDomeCommand::GetDriverVersion(reply) => {
                        let _ = reply.send(dome.driver_version());
                    }
                    AscomDomeCommand::GetDriverInfo(reply) => {
                        let _ = reply.send(dome.driver_info());
                    }
                    AscomDomeCommand::GetSupportedActions(reply) => {
                        let _ = reply.send(dome.supported_actions());
                    }
                    AscomDomeCommand::Heartbeat(reply) => {
                        let _ = reply.send(dome.heartbeat());
                    }
                }
                PumpOutcome::DidWork
            })
                as crate::ascom_wrapper::sta_worker::DevicePump)
        })?;

        // The construction-time `Name` was sent on `info_tx` before the factory
        // returned, so this receive completes immediately once `register_device`
        // reports the device ready.
        let name = info_rx
            .recv()
            .map_err(|e| format!("Failed to receive device name: {}", e))?;

        Ok(Self {
            id: prog_id.clone(),
            name,
            sender: tx,
            connected: AtomicBool::new(false),
        })
    }

    /// Helper to receive a response with a timeout
    async fn recv_with_timeout<T>(
        rx: oneshot::Receiver<Result<T, String>>,
        timeout: Duration,
        operation: &str,
    ) -> Result<T, String> {
        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_recv_err)) => Err(format!("Worker thread dead during {}", operation)),
            Err(_elapsed) => Err(format!("Dome {} timed out after {:?}", operation, timeout)),
        }
    }

    pub async fn connect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::Connect(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "connect").await;
        if result.is_ok() {
            self.connected.store(true, Ordering::SeqCst);
        }
        result
    }

    pub async fn disconnect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::Disconnect(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "disconnect").await;
        if result.is_ok() {
            self.connected.store(false, Ordering::SeqCst);
        }
        result
    }

    #[allow(dead_code)] // Used by ASCOM dome heartbeat once FB-in-dispatch probe lands.
    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    pub async fn heartbeat(&self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::Heartbeat(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "heartbeat").await
    }

    pub async fn open_shutter(&self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::OpenShutter(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::dome_shutter(), "open_shutter").await
    }

    pub async fn close_shutter(&self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::CloseShutter(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::dome_shutter(), "close_shutter").await
    }

    pub async fn park(&self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::Park(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::dome(), "park").await
    }

    pub async fn shutter_status(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::GetShutterStatus(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "shutter_status").await
    }

    pub async fn slewing(&self) -> Result<bool, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::GetSlewing(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "slewing").await
    }

    pub async fn at_park(&self) -> Result<bool, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::GetAtPark(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "at_park").await
    }

    pub async fn azimuth(&self) -> Result<f64, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::GetAzimuth(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "azimuth").await
    }

    pub async fn slew_to_azimuth(&self, azimuth: f64) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::SlewToAzimuth { azimuth, reply: tx })
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::dome(), "slew_to_azimuth").await
    }

    pub async fn abort_slew(&self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::AbortSlew(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::dome(), "abort_slew").await
    }

    pub async fn find_home(&self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::FindHome(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::find_home(), "find_home").await
    }

    pub async fn set_slaved(&self, slaved: bool) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::SetSlaved { slaved, reply: tx })
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_slaved").await
    }

    /// Get the ASCOM interface version number
    pub async fn interface_version(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::GetInterfaceVersion(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Get the driver version string
    pub async fn driver_version(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::GetDriverVersion(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_version").await
    }

    /// Get the driver info/description
    pub async fn driver_info(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::GetDriverInfo(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_info").await
    }

    /// Get the list of supported actions
    pub async fn supported_actions(&self) -> Result<Vec<String>, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomDomeCommand::GetSupportedActions(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "supported_actions").await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread;

    fn build_test_wrapper<F>(handler: F) -> AscomDomeWrapper
    where
        F: FnMut(AscomDomeCommand) -> bool + Send + 'static,
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

        AscomDomeWrapper {
            id: "test-dome".to_string(),
            name: "Test Dome".to_string(),
            sender: tx,
            connected: AtomicBool::new(false),
        }
    }

    #[tokio::test]
    async fn test_heartbeat_uses_worker_command() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomDomeCommand::Heartbeat(reply) = cmd {
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
        assert!(!wrapper.is_connected());
    }
}
