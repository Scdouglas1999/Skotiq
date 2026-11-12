use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::dispatch::DeviceOpError;
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomCoverCalibrator;
use std::fmt::Debug;
use tokio::sync::{mpsc, oneshot};

#[derive(Debug)]
enum AscomCoverCalibratorCommand {
    Connect(oneshot::Sender<Result<(), DeviceOpError>>),
    Disconnect(oneshot::Sender<Result<(), DeviceOpError>>),
    OpenCover(oneshot::Sender<Result<(), DeviceOpError>>),
    CloseCover(oneshot::Sender<Result<(), DeviceOpError>>),
    HaltCover(oneshot::Sender<Result<(), DeviceOpError>>),
    CalibratorOn(i32, oneshot::Sender<Result<(), DeviceOpError>>),
    CalibratorOff(oneshot::Sender<Result<(), DeviceOpError>>),
    GetCoverState(oneshot::Sender<Result<i32, DeviceOpError>>),
    GetCalibratorState(oneshot::Sender<Result<i32, DeviceOpError>>),
    GetBrightness(oneshot::Sender<Result<i32, DeviceOpError>>),
    GetMaxBrightness(oneshot::Sender<Result<i32, DeviceOpError>>),
    // Version query commands
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
                        let _ = reply.send(cover_cal.connect().map_err(DeviceOpError::from));
                    }
                    AscomCoverCalibratorCommand::Disconnect(reply) => {
                        let _ = reply.send(cover_cal.disconnect().map_err(DeviceOpError::from));
                    }
                    AscomCoverCalibratorCommand::OpenCover(reply) => {
                        let _ = reply.send(cover_cal.open_cover().map_err(DeviceOpError::from));
                    }
                    AscomCoverCalibratorCommand::CloseCover(reply) => {
                        let _ = reply.send(cover_cal.close_cover().map_err(DeviceOpError::from));
                    }
                    AscomCoverCalibratorCommand::HaltCover(reply) => {
                        let _ = reply.send(cover_cal.halt_cover().map_err(DeviceOpError::from));
                    }
                    AscomCoverCalibratorCommand::CalibratorOn(brightness, reply) => {
                        let _ = reply.send(
                            cover_cal
                                .calibrator_on(brightness)
                                .map_err(DeviceOpError::from),
                        );
                    }
                    AscomCoverCalibratorCommand::CalibratorOff(reply) => {
                        let _ = reply.send(cover_cal.calibrator_off().map_err(DeviceOpError::from));
                    }
                    AscomCoverCalibratorCommand::GetCoverState(reply) => {
                        let _ = reply.send(cover_cal.cover_state().map_err(DeviceOpError::from));
                    }
                    AscomCoverCalibratorCommand::GetCalibratorState(reply) => {
                        let _ =
                            reply.send(cover_cal.calibrator_state().map_err(DeviceOpError::from));
                    }
                    AscomCoverCalibratorCommand::GetBrightness(reply) => {
                        let _ = reply.send(cover_cal.brightness().map_err(DeviceOpError::from));
                    }
                    AscomCoverCalibratorCommand::GetMaxBrightness(reply) => {
                        let _ = reply.send(cover_cal.max_brightness().map_err(DeviceOpError::from));
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

    pub async fn connect(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::Connect(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout("CoverCalibrator", rx, Timeouts::connection(), "connect").await
    }

    pub async fn disconnect(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::Disconnect(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout("CoverCalibrator", rx, Timeouts::connection(), "disconnect").await
    }

    pub async fn open_cover(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::OpenCover(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout(
            "CoverCalibrator",
            rx,
            Timeouts::cover_calibrator(),
            "open_cover",
        )
        .await
    }

    pub async fn close_cover(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::CloseCover(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout(
            "CoverCalibrator",
            rx,
            Timeouts::cover_calibrator(),
            "close_cover",
        )
        .await
    }

    pub async fn halt_cover(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::HaltCover(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout(
            "CoverCalibrator",
            rx,
            Timeouts::property_write(),
            "halt_cover",
        )
        .await
    }

    pub async fn calibrator_on(&self, brightness: i32) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::CalibratorOn(brightness, tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout(
            "CoverCalibrator",
            rx,
            Timeouts::property_write(),
            "calibrator_on",
        )
        .await
    }

    pub async fn calibrator_off(&self) -> Result<(), DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::CalibratorOff(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout(
            "CoverCalibrator",
            rx,
            Timeouts::property_write(),
            "calibrator_off",
        )
        .await
    }

    pub async fn cover_state(&self) -> Result<i32, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetCoverState(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout(
            "CoverCalibrator",
            rx,
            Timeouts::property_read(),
            "cover_state",
        )
        .await
    }

    pub async fn calibrator_state(&self) -> Result<i32, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetCalibratorState(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout(
            "CoverCalibrator",
            rx,
            Timeouts::property_read(),
            "calibrator_state",
        )
        .await
    }

    pub async fn brightness(&self) -> Result<i32, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetBrightness(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout(
            "CoverCalibrator",
            rx,
            Timeouts::property_read(),
            "brightness",
        )
        .await
    }

    pub async fn max_brightness(&self) -> Result<i32, DeviceOpError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomCoverCalibratorCommand::GetMaxBrightness(tx))
            .await
            .map_err(|e| format!("Send error: {}", e))?;
        super::recv_with_timeout(
            "CoverCalibrator",
            rx,
            Timeouts::property_read(),
            "max_brightness",
        )
        .await
    }

    pub fn cached_max_brightness(&self) -> i32 {
        self.max_brightness
    }
}
