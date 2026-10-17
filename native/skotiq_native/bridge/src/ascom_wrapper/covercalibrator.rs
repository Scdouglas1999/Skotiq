use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomCoverCalibrator;
use std::fmt::Debug;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

#[derive(Debug)]
enum AscomCoverCalibratorCommand {
    Connect(oneshot::Sender<Result<(), String>>),
    Disconnect(oneshot::Sender<Result<(), String>>),
    OpenCover(oneshot::Sender<Result<(), String>>),
    CloseCover(oneshot::Sender<Result<(), String>>),
    HaltCover(oneshot::Sender<Result<(), String>>),
    CalibratorOn(i32, oneshot::Sender<Result<(), String>>),
    CalibratorOff(oneshot::Sender<Result<(), String>>),
    GetCoverState(oneshot::Sender<Result<i32, String>>),
    GetCalibratorState(oneshot::Sender<Result<i32, String>>),
    GetBrightness(oneshot::Sender<Result<i32, String>>),
    GetMaxBrightness(oneshot::Sender<Result<i32, String>>),
    // Version query commands
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    GetDriverVersion(oneshot::Sender<Result<String, String>>),
    GetDriverInfo(oneshot::Sender<Result<String, String>>),
    GetSupportedActions(oneshot::Sender<Result<Vec<String>, String>>),
}

pub struct AscomCoverCalibratorWrapper {
    id: String,
    name: String,
    sender: mpsc::Sender<AscomCoverCalibratorCommand>,
    max_brightness: i32,
}

impl Debug for AscomCoverCalibratorWrapper {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AscomCoverCalibratorWrapper")
            .field("id", &self.id)
            .field("name", &self.name)
            .field("max_brightness", &self.max_brightness)
            .finish()
    }
}

impl AscomCoverCalibratorWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // The friendly `Name` and `MaxBrightness` are read at construction
        // (before connect) and ferried back to `new()` over this channel.
        // `register_device` owns the success/error signalling; this side channel
        // only carries the construction-time property payload the legacy init
        // channel returned.
        let (info_tx, info_rx) = std::sync::mpsc::channel();

        // Build the COM object and its command pump on the shared STA apartment.
        // A construction failure is propagated out of `register_device` so the
        // caller drops the wrapper, exactly as the legacy init-channel did.
        register_device(move || {
            let mut cover_cal = match AscomCoverCalibrator::new(&prog_id_clone) {
                Ok(cc) => cc,
                Err(e) => {
                    return Err(format!("Failed to create ASCOM cover calibrator: {}", e));
                }
            };

            // Get static properties
            let name = cover_cal.name().unwrap_or_else(|_| prog_id_clone.clone());
            let max_brightness = cover_cal.max_brightness().unwrap_or(100);
            let _ = info_tx.send((name, max_brightness));

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let cmd = match rx.try_recv() {
                    Ok(cmd) => cmd,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM teardown ordering — issue the final disconnect
                        // on the STA worker thread that owns the apartment. The
                        // typed `AscomCoverCalibrator` (and its IDispatch) is then
                        // released when this closure is dropped, still on this
                        // thread. The apartment persists for the process
                        // lifetime, so COM is NOT uninitialized here.
                        if let Err(e) = cover_cal.disconnect() {
                            tracing::warn!(
                                "ASCOM cover calibrator STA-worker shutdown disconnect failed: {}",
                                e
                            );
                        }
                        return PumpOutcome::Finished;
                    }
                };
                match cmd {
                    AscomCoverCalibratorCommand::Connect(reply) => {
                        let _ = reply.send(cover_cal.connect());
                    }
                    AscomCoverCalibratorCommand::Disconnect(reply) => {
                        let _ = reply.send(cover_cal.disconnect());
                    }
                    AscomCoverCalibratorCommand::OpenCover(reply) => {
                        let _ = reply.send(cover_cal.open_cover());
                    }
                    AscomCoverCalibratorCommand::CloseCover(reply) => {
                        let _ = reply.send(cover_cal.close_cover());
                    }
                    AscomCoverCalibratorCommand::HaltCover(reply) => {
                        let _ = reply.send(cover_cal.halt_cover());
                    }
                    AscomCoverCalibratorCommand::CalibratorOn(brightness, reply) => {
                        let _ = reply.send(cover_cal.calibrator_on(brightness));
                    }
                    AscomCoverCalibratorCommand::CalibratorOff(reply) => {
                        let _ = reply.send(cover_cal.calibrator_off());
                    }
                    AscomCoverCalibratorCommand::GetCoverState(reply) => {
                        let _ = reply.send(cover_cal.cover_state());
                    }
                    AscomCoverCalibratorCommand::GetCalibratorState(reply) => {
                        let _ = reply.send(cover_cal.calibrator_state());
                    }
                    AscomCoverCalibratorCommand::GetBrightness(reply) => {
                        let _ = reply.send(cover_cal.brightness());
                    }
                    AscomCoverCalibratorCommand::GetMaxBrightness(reply) => {
                        let _ = reply.send(cover_cal.max_brightness());
                    }
                    AscomCoverCalibratorCommand::GetInterfaceVersion(reply) => {
                        let _ = reply.send(cover_cal.interface_version());
                    }
                    AscomCoverCalibratorCommand::GetDriverVersion(reply) => {
                        let _ = reply.send(cover_cal.driver_version());
                    }
                    AscomCoverCalibratorCommand::GetDriverInfo(reply) => {
                        let _ = reply.send(cover_cal.driver_info());
                    }
                    AscomCoverCalibratorCommand::GetSupportedActions(reply) => {
                        let _ = reply.send(cover_cal.supported_actions());
                    }
                }
                PumpOutcome::DidWork
            })
                as crate::ascom_wrapper::sta_worker::DevicePump)
        })?;

        // The construction-time `(name, max_brightness)` was sent on `info_tx`
        // before the factory returned, so this receive completes immediately once
        // `register_device` reports the device ready.
        let (name, max_brightness) = info_rx
            .recv()
            .map_err(|e| format!("Failed to receive device properties: {}", e))?;

        Ok(Self {
            id: prog_id.clone(),
            name,
            sender: tx,
            max_brightness,
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
            Err(_elapsed) => Err(format!(
                "CoverCalibrator {} timed out after {:?}",
                operation, timeout
            )),
        }
    }

    pub async fn connect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::Connect(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::connection(), "connect").await
    }

    pub async fn disconnect(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::Disconnect(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::connection(), "disconnect").await
    }

    pub async fn open_cover(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::OpenCover(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::cover_calibrator(), "open_cover").await
    }

    pub async fn close_cover(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::CloseCover(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::cover_calibrator(), "close_cover").await
    }

    pub async fn halt_cover(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::HaltCover(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "halt_cover").await
    }

    pub async fn calibrator_on(&mut self, brightness: i32) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::CalibratorOn(brightness, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "calibrator_on").await
    }

    pub async fn calibrator_off(&mut self) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::CalibratorOff(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "calibrator_off").await
    }

    pub async fn cover_state(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetCoverState(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "cover_state").await
    }

    pub async fn calibrator_state(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetCalibratorState(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "calibrator_state").await
    }

    pub async fn brightness(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetBrightness(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "brightness").await
    }

    pub async fn max_brightness(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetMaxBrightness(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "max_brightness").await
    }

    pub fn cached_max_brightness(&self) -> i32 {
        self.max_brightness
    }

    /// Get the ASCOM interface version number
    pub async fn interface_version(&self) -> Result<i32, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetInterfaceVersion(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Get the driver version string
    pub async fn driver_version(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetDriverVersion(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_version").await
    }

    /// Get the driver info/description
    pub async fn driver_info(&self) -> Result<String, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetDriverInfo(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_info").await
    }

    /// Get the list of supported actions
    pub async fn supported_actions(&self) -> Result<Vec<String>, String> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetSupportedActions(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "supported_actions").await
    }
}
