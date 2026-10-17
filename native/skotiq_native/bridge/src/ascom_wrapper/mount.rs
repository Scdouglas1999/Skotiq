//! ASCOM mount STA-thread wrapper.
//!
//! # `unwrap_or` policy
//!
//! All `ascom_caps.can_*.unwrap_or(false)` and `m.can_*().unwrap_or(false)`
//! calls in this file follow the ASCOM ITelescope optional-property contract:
//! drivers that do not implement a Can* probe throw `PropertyNotImplemented`,
//! which `skotiq_ascom` surfaces as `Err`. The audit policy is to
//! interpret missing probe as "this feature not supported" — `false` — so
//! the UI never offers a button that the driver will reject. The same
//! interpretation applies to `alignment_mode().map(...).unwrap_or(false)`
//! (alignment mode unknown ⇒ "not safely classifiable as equatorial").
//! Hard connection errors are still propagated through the worker channel
//! to the caller as Err(String).
use crate::ascom_wrapper::sta_worker::{register_device, PumpOutcome};
use crate::timeout_ops::Timeouts;
use skotiq_ascom::AscomMount;
use skotiq_native::traits::{
    GuideDirection, NativeDevice, NativeError, NativeMount, TrackingRate,
};
use skotiq_native::NativeVendor;
use std::fmt::Debug;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};

/// ASCOM mount capabilities returned from the device
#[derive(Debug, Clone, Default)]
pub struct AscomMountCapabilities {
    pub can_slew: bool,
    pub can_slew_async: bool,
    pub can_sync: bool,
    pub can_park: bool,
    pub can_unpark: bool,
    pub can_set_park: bool,
    pub can_pulse_guide: bool,
    pub can_set_tracking: bool,
    pub can_find_home: bool,
    pub can_move_axis_primary: bool,
    pub can_move_axis_secondary: bool,
    pub is_equatorial: bool,
}

/// Command sent to the ASCOM worker thread
enum AscomMountCommand {
    Connect(oneshot::Sender<Result<(), String>>),
    Disconnect(oneshot::Sender<Result<(), String>>),
    SlewToCoordinates(f64, f64, oneshot::Sender<Result<(), String>>),
    SyncToCoordinates(f64, f64, oneshot::Sender<Result<(), String>>),
    Park(oneshot::Sender<Result<(), String>>),
    Unpark(oneshot::Sender<Result<(), String>>),
    GetCoordinates(oneshot::Sender<Result<(f64, f64), String>>),
    IsSlewing(oneshot::Sender<Result<bool, String>>),
    IsParked(oneshot::Sender<Result<bool, String>>),
    CanPark(oneshot::Sender<Result<bool, String>>),
    GetCapabilities(oneshot::Sender<Result<AscomMountCapabilities, String>>),
    Stop(oneshot::Sender<Result<(), String>>),
    AbortSlew(oneshot::Sender<Result<(), String>>),
    SetTracking(bool, oneshot::Sender<Result<(), String>>),
    GetTracking(oneshot::Sender<Result<bool, String>>),
    PulseGuide(GuideDirection, u32, oneshot::Sender<Result<(), String>>),
    GetSideOfPier(oneshot::Sender<Result<skotiq_native::traits::PierSide, String>>),
    GetAltAz(oneshot::Sender<Result<(f64, f64), String>>),
    GetSiderealTime(oneshot::Sender<Result<f64, String>>),
    // Tracking rate commands
    SetTrackingRate(i32, oneshot::Sender<Result<(), String>>),
    GetTrackingRate(oneshot::Sender<Result<i32, String>>),
    // Axis movement commands (for jogging)
    MoveAxis(i32, f64, oneshot::Sender<Result<(), String>>),
    // Alt/Az slew
    SlewToAltAz(f64, f64, oneshot::Sender<Result<(), String>>),
    // Find home
    FindHome(oneshot::Sender<Result<(), String>>),
    GetSite(oneshot::Sender<Result<(f64, f64, Option<f64>), String>>),
    SetSite(f64, f64, Option<f64>, oneshot::Sender<Result<(), String>>),
    GetUtcDate(oneshot::Sender<Result<f64, String>>),
    SetUtcDate(f64, oneshot::Sender<Result<(), String>>),
    // Version query commands
    GetInterfaceVersion(oneshot::Sender<Result<i32, String>>),
    GetDriverVersion(oneshot::Sender<Result<String, String>>),
    GetDriverInfo(oneshot::Sender<Result<String, String>>),
    GetSupportedActions(oneshot::Sender<Result<Vec<String>, String>>),
}

/// Wrapper for ASCOM Mount whose COM object lives on the shared STA worker.
#[derive(Debug)]
pub struct AscomMountWrapper {
    id: String,
    name: String,
    sender: mpsc::Sender<AscomMountCommand>,
    connected: AtomicBool,
}

impl AscomMountWrapper {
    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel(32);
        let prog_id_clone = prog_id.clone();

        // Build the COM object and its command pump on the process-wide STA
        // apartment. The pump is polled once per worker-loop iteration; the
        // per-command match arms are unchanged from the legacy per-device
        // worker — only the loop shell (and COM teardown ordering) differs.
        register_device(move || {
            let mut mount: Option<AscomMount> = None;

            // Try to create the mount object immediately
            match AscomMount::new(&prog_id_clone) {
                Ok(m) => mount = Some(m),
                Err(e) => tracing::error!("Failed to create ASCOM mount {}: {}", prog_id_clone, e),
            }

            Ok(Box::new(move || {
                use tokio::sync::mpsc::error::TryRecvError;
                let cmd = match rx.try_recv() {
                    Ok(cmd) => cmd,
                    Err(TryRecvError::Empty) => return PumpOutcome::Idle,
                    Err(TryRecvError::Disconnected) => {
                        // Why: COM teardown ordering — release the typed
                        // `AscomMount` (which holds an IDispatch) on the STA
                        // worker thread that owns the apartment. The Drop on
                        // `AscomDeviceConnection` is intentionally a no-op so
                        // this is the only correct place to issue the final
                        // disconnect. The apartment itself persists for the
                        // process lifetime, so it is NOT uninitialized here.
                        if let Some(mut m) = mount.take() {
                            if let Err(e) = m.disconnect() {
                                tracing::warn!(
                                    "ASCOM mount STA-worker shutdown disconnect failed: {}",
                                    e
                                );
                            }
                            drop(m);
                        }
                        return PumpOutcome::Finished;
                    }
                };
                match cmd {
                    AscomMountCommand::Connect(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.connect().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::Disconnect(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.disconnect().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::SlewToCoordinates(ra, dec, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(
                                m.slew_to_coordinates_async(ra, dec)
                                    .map_err(|e| e.to_string()),
                            );
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::SyncToCoordinates(ra, dec, reply) => {
                        if let Some(m) = &mut mount {
                            match m.can_sync() {
                                Ok(true) => {
                                    let _ = reply.send(
                                        m.sync_to_coordinates(ra, dec).map_err(|e| e.to_string()),
                                    );
                                }
                                Ok(false) => {
                                    let _ =
                                        reply.send(Err("Mount does not support Sync".to_string()));
                                }
                                Err(e) => {
                                    let _ =
                                        reply.send(Err(format!("Failed to check CanSync: {}", e)));
                                }
                            }
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::Park(reply) => {
                        if let Some(m) = &mut mount {
                            match m.can_park() {
                                Ok(true) => {
                                    let _ = reply.send(m.park().map_err(|e| e.to_string()));
                                }
                                Ok(false) => {
                                    let _ =
                                        reply.send(Err("Mount does not support Park".to_string()));
                                }
                                Err(e) => {
                                    let _ =
                                        reply.send(Err(format!("Failed to check CanPark: {}", e)));
                                }
                            }
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::Unpark(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.unpark().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetCoordinates(reply) => {
                        if let Some(m) = &mut mount {
                            let ra_res = m.right_ascension();
                            let dec_res = m.declination();
                            match (ra_res, dec_res) {
                                (Ok(ra), Ok(dec)) => {
                                    let _ = reply.send(Ok((ra, dec)));
                                }
                                (Err(e), _) => {
                                    let _ = reply.send(Err(format!("Failed to get RA: {}", e)));
                                }
                                (_, Err(e)) => {
                                    let _ = reply.send(Err(format!("Failed to get DEC: {}", e)));
                                }
                            }
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::IsSlewing(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.slewing().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::IsParked(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.at_park().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::CanPark(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.can_park().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetCapabilities(reply) => {
                        if let Some(m) = &mount {
                            // Query the ASCOM batch capabilities method
                            let ascom_caps = m.get_capabilities();
                            let caps = AscomMountCapabilities {
                                can_slew: ascom_caps.can_slew.unwrap_or(false),
                                can_slew_async: ascom_caps.can_slew_async.unwrap_or(false),
                                can_sync: ascom_caps.can_sync.unwrap_or(false),
                                can_park: ascom_caps.can_park.unwrap_or(false),
                                can_unpark: ascom_caps.can_unpark.unwrap_or(false),
                                can_set_park: false, // ASCOM MountCapabilities doesn't expose this
                                can_pulse_guide: ascom_caps.can_pulse_guide.unwrap_or(false),
                                can_set_tracking: ascom_caps.can_set_tracking.unwrap_or(false),
                                can_find_home: m.can_find_home().unwrap_or(false),
                                can_move_axis_primary: ascom_caps
                                    .can_move_axis_primary
                                    .unwrap_or(false),
                                can_move_axis_secondary: ascom_caps
                                    .can_move_axis_secondary
                                    .unwrap_or(false),
                                is_equatorial: m.alignment_mode().map(|m| m > 0).unwrap_or(false),
                            };
                            let _ = reply.send(Ok(caps));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::AbortSlew(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.abort_slew().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::SetTracking(enabled, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.set_tracking(enabled).map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetTracking(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.tracking().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::PulseGuide(dir, duration, reply) => {
                        if let Some(m) = &mut mount {
                            // Map GuideDirection to ASCOM direction (0=N, 1=S, 2=E, 3=W)
                            let d = match dir {
                                GuideDirection::North => 0,
                                GuideDirection::South => 1,
                                GuideDirection::East => 2,
                                GuideDirection::West => 3,
                            };
                            let _ =
                                reply.send(m.pulse_guide(d, duration).map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetSideOfPier(reply) => {
                        if let Some(m) = &mut mount {
                            match m.side_of_pier() {
                                Ok(0) => {
                                    let _ =
                                        reply.send(Ok(skotiq_native::traits::PierSide::East));
                                }
                                Ok(1) => {
                                    let _ =
                                        reply.send(Ok(skotiq_native::traits::PierSide::West));
                                }
                                Ok(_) => {
                                    let _ = reply
                                        .send(Ok(skotiq_native::traits::PierSide::Unknown));
                                }
                                Err(e) => {
                                    let _ = reply.send(Err(e.to_string()));
                                }
                            }
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetAltAz(reply) => {
                        if let Some(m) = &mut mount {
                            let alt_res = m.altitude();
                            let az_res = m.azimuth();
                            match (alt_res, az_res) {
                                (Ok(alt), Ok(az)) => {
                                    let _ = reply.send(Ok((alt, az)));
                                }
                                (Err(e), _) => {
                                    let _ = reply.send(Err(format!("Failed to get Alt: {}", e)));
                                }
                                (_, Err(e)) => {
                                    let _ = reply.send(Err(format!("Failed to get Az: {}", e)));
                                }
                            }
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetSiderealTime(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.sidereal_time().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::SetTrackingRate(rate, reply) => {
                        if let Some(m) = &mut mount {
                            let _ =
                                reply.send(m.set_tracking_rate(rate).map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetTrackingRate(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.tracking_rate().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::MoveAxis(axis, rate, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.move_axis(axis, rate).map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetInterfaceVersion(reply) => {
                        if let Some(ref m) = mount {
                            let _ = reply.send(m.interface_version());
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetDriverVersion(reply) => {
                        if let Some(ref m) = mount {
                            let _ = reply.send(m.driver_version());
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetDriverInfo(reply) => {
                        if let Some(ref m) = mount {
                            let _ = reply.send(m.driver_info());
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetSupportedActions(reply) => {
                        if let Some(ref m) = mount {
                            let _ = reply.send(m.supported_actions());
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::Stop(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.abort_slew().map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::SlewToAltAz(alt, az, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply
                                .send(m.slew_to_alt_az_async(alt, az).map_err(|e| e.to_string()));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetSite(reply) => {
                        if let Some(m) = &mut mount {
                            let site = m.site_latitude().and_then(|lat| {
                                m.site_longitude().map(|lon| {
                                    // Elevation is optional in ASCOM: absent is
                                    // reported as None rather than as sea level.
                                    (lat, lon, m.site_elevation().ok())
                                })
                            });
                            let _ = reply.send(site);
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::SetSite(lat, lon, elevation, reply) => {
                        if let Some(m) = &mut mount {
                            let result = m.set_site_latitude(lat).and_then(|_| {
                                m.set_site_longitude(lon).map(|_| {
                                    // A driver that refuses elevation must not
                                    // undo the lat/lon that already landed.
                                    if let Some(value) = elevation {
                                        if let Err(e) = m.set_site_elevation(value) {
                                            tracing::warn!(
                                                "ASCOM mount took lat/lon but refused elevation: {}",
                                                e
                                            );
                                        }
                                    }
                                })
                            });
                            let _ = reply.send(result);
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::GetUtcDate(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.utc_date());
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::SetUtcDate(value, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.set_utc_date(value));
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
                    }
                    AscomMountCommand::FindHome(reply) => {
                        if let Some(m) = &mut mount {
                            match m.can_find_home() {
                                Ok(true) => {
                                    let _ = reply.send(m.find_home().map_err(|e| e.to_string()));
                                }
                                Ok(false) => {
                                    let _ = reply
                                        .send(Err("Mount does not support FindHome".to_string()));
                                }
                                Err(e) => {
                                    let _ = reply
                                        .send(Err(format!("Failed to check CanFindHome: {}", e)));
                                }
                            }
                        } else {
                            let _ = reply.send(Err("Mount not created".to_string()));
                        }
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
            connected: std::sync::atomic::AtomicBool::new(false),
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
                "Mount {} timed out after {:?}",
                operation, timeout
            ))),
        }
    }

    /// Get the mount's capabilities by querying the ASCOM device
    ///
    /// This queries all capability-related properties from the mount and returns
    /// a comprehensive capabilities struct. The device should be connected before
    /// calling this method.
    pub async fn get_capabilities(&self) -> Result<AscomMountCapabilities, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetCapabilities(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        let mut caps =
            Self::recv_with_timeout(rx, Timeouts::property_read(), "get_capabilities").await?;
        match self.can_park().await {
            Ok(can_park) => {
                caps.can_park = can_park;
            }
            Err(err) => {
                tracing::warn!("Failed to query mount CanPark: {}", err);
            }
        }
        Ok(caps)
    }

    pub async fn can_park(&self) -> Result<bool, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::CanPark(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "can_park").await
    }

    pub async fn slew_to_alt_az(&self, alt: f64, az: f64) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::SlewToAltAz(alt, az, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::long_slew(), "slew_to_alt_az").await
    }

    pub async fn get_site(&self) -> Result<(f64, f64, Option<f64>), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetSite(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_site").await
    }

    pub async fn set_site(
        &self,
        latitude_deg: f64,
        longitude_deg: f64,
        elevation_m: Option<f64>,
    ) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::SetSite(
                latitude_deg,
                longitude_deg,
                elevation_m,
                tx,
            ))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_site").await
    }

    /// UTCDate as an OLE Automation date (days since 1899-12-30).
    pub async fn get_utc_date(&self) -> Result<f64, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetUtcDate(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_utc_date").await
    }

    pub async fn set_utc_date(&self, utc_date: f64) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::SetUtcDate(utc_date, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_utc_date").await
    }

    pub async fn find_home(&self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::FindHome(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::long_slew(), "find_home").await
    }

    pub async fn stop(&self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::Stop(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::connection(), "stop").await
    }
}

#[async_trait::async_trait]
impl NativeDevice for AscomMountWrapper {
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
            .send(AscomMountCommand::Connect(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        let result = Self::recv_with_timeout(rx, Timeouts::connection(), "connect").await;
        if result.is_ok() {
            self.connected.store(true, Ordering::SeqCst);
        }
        result
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
        // Best-effort: halt any in-progress slew before disconnecting. A PARKED
        // mount cannot be slewing, and some drivers (e.g. PegasusAstro NYX)
        // raise "Mount is parked" from AbortSlew — that is an expected benign
        // state, not a failure, so don't alarm the user with a WARN over it.
        if let Err(err) = self.stop().await {
            if err.to_string().to_lowercase().contains("parked") {
                tracing::debug!(
                    "Skipping slew-abort before disconnect (mount parked): {}",
                    err
                );
            } else {
                tracing::warn!("Failed to stop mount before disconnect: {}", err);
            }
        }
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::Disconnect(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        let disconnect_result =
            Self::recv_with_timeout(rx, Timeouts::connection(), "disconnect").await;
        match disconnect_result {
            Err(err) => Err(err),
            Ok(()) => {
                self.connected.store(false, Ordering::SeqCst);
                Ok(())
            }
        }
    }
}

#[async_trait::async_trait]
impl NativeMount for AscomMountWrapper {
    async fn slew_to_coordinates(&mut self, ra: f64, dec: f64) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::SlewToCoordinates(ra, dec, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        // Slews can take a long time
        Self::recv_with_timeout(rx, Timeouts::long_slew(), "slew_to_coordinates").await
    }

    async fn sync_to_coordinates(&mut self, ra: f64, dec: f64) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::SyncToCoordinates(ra, dec, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "sync_to_coordinates").await
    }

    async fn park(&mut self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::Park(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::park(), "park").await
    }

    async fn unpark(&mut self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::Unpark(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::park(), "unpark").await
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetCoordinates(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_coordinates").await
    }

    async fn is_slewing(&self) -> Result<bool, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::IsSlewing(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "is_slewing").await
    }

    async fn is_parked(&self) -> Result<bool, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::IsParked(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "is_parked").await
    }

    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::PulseGuide(direction, duration_ms, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        // Pulse guide takes the duration plus a buffer
        // Why: `duration_ms` is u32 pulse-guide
        // milliseconds (≤ a few thousand for real guiding); u32 → u64
        // widening, exact.
        let timeout = Duration::from_millis(u64::from(duration_ms)) + Timeouts::short_slew();
        Self::recv_with_timeout(rx, timeout, "pulse_guide").await
    }

    async fn abort_slew(&mut self) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::AbortSlew(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "abort_slew").await
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::SetTracking(enabled, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_tracking").await
    }

    async fn get_tracking(&self) -> Result<bool, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetTracking(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_tracking").await
    }

    async fn get_side_of_pier(&self) -> Result<skotiq_native::traits::PierSide, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetSideOfPier(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_side_of_pier").await
    }

    async fn get_alt_az(&self) -> Result<(f64, f64), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetAltAz(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_alt_az").await
    }

    async fn get_sidereal_time(&self) -> Result<f64, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetSiderealTime(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_sidereal_time").await
    }

    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), NativeError> {
        let rate_int = match rate {
            TrackingRate::Sidereal => 0,
            TrackingRate::Lunar => 1,
            TrackingRate::Solar => 2,
            TrackingRate::King => 3,
            TrackingRate::Custom => return Err(NativeError::NotSupported),
        };
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::SetTrackingRate(rate_int, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_tracking_rate").await
    }

    async fn get_tracking_rate(&self) -> Result<TrackingRate, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetTrackingRate(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        let rate_int =
            Self::recv_with_timeout(rx, Timeouts::property_read(), "get_tracking_rate").await?;
        match rate_int {
            0 => Ok(TrackingRate::Sidereal),
            1 => Ok(TrackingRate::Lunar),
            2 => Ok(TrackingRate::Solar),
            3 => Ok(TrackingRate::King),
            _ => Ok(TrackingRate::Custom),
        }
    }

    fn can_slew(&self) -> bool {
        true
    }

    fn can_sync(&self) -> bool {
        true
    }

    fn can_pulse_guide(&self) -> bool {
        true
    }

    fn can_set_tracking_rate(&self) -> bool {
        false
    }
}

// Additional mount control methods (not in NativeMount trait)
impl AscomMountWrapper {
    /// Set the tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
    pub async fn set_tracking_rate_raw(&mut self, rate: i32) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::SetTrackingRate(rate, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_write(), "set_tracking_rate").await
    }

    /// Get the current tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
    pub async fn get_tracking_rate_raw(&self) -> Result<i32, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetTrackingRate(tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "get_tracking_rate").await
    }

    /// Move an axis at the specified rate (degrees/second)
    /// axis: 0=RA/Azimuth (primary), 1=Dec/Altitude (secondary)
    /// rate: degrees per second (positive = N/E, negative = S/W), 0 to stop
    pub async fn move_axis(&mut self, axis: i32, rate: f64) -> Result<(), NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::MoveAxis(axis, rate, tx))
            .await
            .map_err(|e| NativeError::SdkError(e.to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::short_slew(), "move_axis").await
    }

    /// Get the ASCOM interface version number
    pub async fn interface_version(&self) -> Result<i32, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetInterfaceVersion(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "interface_version").await
    }

    /// Get the driver version string
    pub async fn driver_version(&self) -> Result<String, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetDriverVersion(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_version").await
    }

    /// Get the driver info/description
    pub async fn driver_info(&self) -> Result<String, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetDriverInfo(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "driver_info").await
    }

    /// Get the list of supported actions
    pub async fn supported_actions(&self) -> Result<Vec<String>, NativeError> {
        let (tx, rx) = oneshot::channel();
        self.sender
            .send(AscomMountCommand::GetSupportedActions(tx))
            .await
            .map_err(|_| NativeError::Unknown("Worker thread dead".to_string()))?;
        Self::recv_with_timeout(rx, Timeouts::property_read(), "supported_actions").await
    }
}

#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use std::thread;

    #[derive(Debug, Clone)]
    pub struct TestMountResponses {
        pub coordinates: (f64, f64),
        pub alt_az: (f64, f64),
        pub tracking: bool,
        pub slewing: bool,
        pub parked: bool,
        pub side_of_pier: skotiq_native::traits::PierSide,
        pub sidereal_time: f64,
        pub can_park: bool,
    }

    impl Default for TestMountResponses {
        fn default() -> Self {
            Self {
                coordinates: (0.0, 0.0),
                alt_az: (0.0, 0.0),
                tracking: false,
                slewing: false,
                parked: false,
                side_of_pier: skotiq_native::traits::PierSide::Unknown,
                sidereal_time: 0.0,
                can_park: false,
            }
        }
    }

    pub fn build_test_mount_wrapper(responses: TestMountResponses) -> AscomMountWrapper {
        let (tx, mut rx) = mpsc::channel(8);
        let _handle = thread::spawn(move || {
            while let Some(cmd) = crate::ascom_wrapper::pump_blocking_recv(&mut rx) {
                match cmd {
                    AscomMountCommand::GetCoordinates(reply) => {
                        let _ = reply.send(Ok(responses.coordinates));
                    }
                    AscomMountCommand::GetAltAz(reply) => {
                        let _ = reply.send(Ok(responses.alt_az));
                    }
                    AscomMountCommand::GetTracking(reply) => {
                        let _ = reply.send(Ok(responses.tracking));
                    }
                    AscomMountCommand::IsSlewing(reply) => {
                        let _ = reply.send(Ok(responses.slewing));
                    }
                    AscomMountCommand::IsParked(reply) => {
                        let _ = reply.send(Ok(responses.parked));
                    }
                    AscomMountCommand::GetSideOfPier(reply) => {
                        let _ = reply.send(Ok(responses.side_of_pier));
                    }
                    AscomMountCommand::GetSiderealTime(reply) => {
                        let _ = reply.send(Ok(responses.sidereal_time));
                    }
                    AscomMountCommand::CanPark(reply) => {
                        let _ = reply.send(Ok(responses.can_park));
                    }
                    AscomMountCommand::Stop(reply) => {
                        let _ = reply.send(Ok(()));
                    }
                    _ => {}
                }
            }
        });

        AscomMountWrapper {
            id: "test-mount".to_string(),
            name: "Test Mount".to_string(),
            sender: tx,
            connected: std::sync::atomic::AtomicBool::new(false),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};
    use std::thread;

    fn build_test_wrapper<F>(handler: F) -> AscomMountWrapper
    where
        F: FnMut(AscomMountCommand) -> bool + Send + 'static,
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
        AscomMountWrapper {
            id: "test-mount".to_string(),
            name: "Test Mount".to_string(),
            sender: tx,
            connected: std::sync::atomic::AtomicBool::new(false),
        }
    }

    #[tokio::test]
    async fn test_get_capabilities_uses_can_park_command() {
        let wrapper = build_test_wrapper(|cmd| {
            match cmd {
                AscomMountCommand::GetCapabilities(reply) => {
                    let caps = AscomMountCapabilities {
                        can_park: false,
                        ..Default::default()
                    };
                    let _ = reply.send(Ok(caps));
                }
                AscomMountCommand::CanPark(reply) => {
                    let _ = reply.send(Ok(true));
                }
                _ => {}
            }
            false
        });

        let caps = wrapper.get_capabilities().await.expect("get_capabilities");
        assert!(caps.can_park);
    }

    #[tokio::test]
    async fn test_disconnect_stops_before_disconnect() {
        let order = Arc::new(Mutex::new(Vec::new()));
        let order_flag = Arc::clone(&order);
        let mut wrapper = build_test_wrapper(move |cmd| {
            match cmd {
                AscomMountCommand::Disconnect(reply) => {
                    order_flag.lock().expect("lock order").push("disconnect");
                    let _ = reply.send(Ok(()));
                }
                AscomMountCommand::Stop(reply) => {
                    order_flag.lock().expect("lock order").push("stop");
                    let _ = reply.send(Ok(()));
                }
                _ => {}
            }
            let done = order_flag.lock().expect("lock order").len() >= 2;
            done
        });
        wrapper.disconnect().await.expect("disconnect");
        let order = order.lock().expect("lock order");
        assert_eq!(order.as_slice(), ["stop", "disconnect"]);
    }

    #[tokio::test]
    async fn test_disconnect_returns_ok_when_stop_fails_but_disconnect_succeeds() {
        let mut wrapper = build_test_wrapper(|cmd| {
            match cmd {
                AscomMountCommand::Stop(reply) => {
                    let _ = reply.send(Err("stop failed".to_string()));
                }
                AscomMountCommand::Disconnect(reply) => {
                    let _ = reply.send(Ok(()));
                    return true;
                }
                _ => {}
            }
            false
        });

        wrapper.disconnect().await.expect("disconnect");
        assert!(!wrapper.is_connected());
    }
}
