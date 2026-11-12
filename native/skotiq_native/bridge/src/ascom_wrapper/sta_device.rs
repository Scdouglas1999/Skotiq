//! One ASCOM driver object on the STA worker, reached by closures that run
//! there.
//!
//! The driver's COM object is created on the worker thread and never leaves
//! it; a call is a closure sent to that thread, run against the object, and
//! answered over a oneshot channel. Each wrapper's methods are then one line
//! naming the member, its timeout and the call.

use super::sta_worker::{register_device, DevicePump, PumpOutcome};
use crate::dispatch::DeviceOpError;
use skotiq_ascom::AscomResult;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

type Job<D> = Box<dyn FnOnce(&mut D) + Send>;

pub(crate) struct StaDevice<D> {
    /// The device kind in timeout messages ("Dome").
    kind: &'static str,
    jobs: mpsc::Sender<Job<D>>,
}

impl<D: 'static> StaDevice<D> {
    /// Creates the driver's COM object on the STA worker with `create`, and
    /// reads with `describe` what the wrapper keeps from it before it is
    /// connected (its name, say).
    pub(crate) fn new<I: Send + 'static>(
        kind: &'static str,
        create: impl FnOnce() -> AscomResult<D> + Send + 'static,
        describe: impl FnOnce(&D) -> I + Send + 'static,
    ) -> Result<(Self, I), String> {
        let (jobs, mut queue) = mpsc::channel::<Job<D>>(32);
        let (described, description) = std::sync::mpsc::channel();
        register_device(move || {
            let mut device =
                create().map_err(|e| format!("Failed to create the ASCOM {kind} driver: {e}"))?;
            let _ = described.send(describe(&device));
            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                match queue.try_recv() {
                    Ok(job) => {
                        job(&mut device);
                        PumpOutcome::DidWork
                    }
                    Err(TryRecvError::Empty) => PumpOutcome::Idle,
                    // The COM object is released when this closure is
                    // dropped, still on the worker thread that owns the
                    // apartment.
                    Err(TryRecvError::Disconnected) => PumpOutcome::Finished,
                }
            }) as DevicePump)
        })?;
        let description = description
            .recv()
            .map_err(|e| format!("The ASCOM {kind} driver was not described: {e}"))?;
        Ok((Self { kind, jobs }, description))
    }

    /// Runs `call` against the driver and answers what it returned, or a
    /// timeout once `timeout` has passed.
    pub(crate) async fn run<T: Send + 'static>(
        &self,
        operation: &str,
        timeout: Duration,
        call: impl FnOnce(&mut D) -> AscomResult<T> + Send + 'static,
    ) -> Result<T, DeviceOpError> {
        let (reply, answer) = oneshot::channel();
        self.jobs
            .send(Box::new(move |device: &mut D| {
                let _ = reply.send(call(device).map_err(DeviceOpError::from));
            }))
            .await
            .map_err(|e| format!("Send error: {e}"))?;
        super::recv_with_timeout(self.kind, answer, timeout, operation).await
    }
}

/// An ASCOM failure as the driver traits classify it. `NotImplemented` is
/// `NotSupported`, as an Alpaca server's 0x400 is, so the shared rules of
/// `skotiq_device::ascom` see a missing member the same way over both
/// transports.
pub(crate) fn driver_error(error: DeviceOpError) -> skotiq_device::DriverError {
    match error {
        DeviceOpError::Unsupported { .. } => skotiq_device::DriverError::NotSupported,
        other => other.into(),
    }
}

/// The accessory heartbeat: `Connected` read back, `false` meaning the
/// device is gone, as the Alpaca probe reads it.
macro_rules! sta_accessory {
    ($wrapper:ty) => {
        #[async_trait::async_trait]
        impl skotiq_device::AccessoryDriver for $wrapper {
            async fn disconnect(&self) -> Result<(), skotiq_device::DriverError> {
                self.device
                    .run("disconnect", $crate::timeout_ops::Timeouts::connection(), |d| {
                        d.disconnect()
                    })
                    .await
                    .map_err($crate::ascom_wrapper::sta_device::driver_error)
            }

            async fn heartbeat(&self) -> Result<(), skotiq_device::DriverError> {
                let connected = self
                    .device
                    .run("heartbeat", $crate::timeout_ops::Timeouts::heartbeat(), |d| {
                        d.is_connected()
                    })
                    .await
                    .map_err($crate::ascom_wrapper::sta_device::driver_error)?;
                if connected {
                    Ok(())
                } else {
                    Err(skotiq_device::DriverError::NotConnected)
                }
            }
        }
    };
}
pub(crate) use sta_accessory;
