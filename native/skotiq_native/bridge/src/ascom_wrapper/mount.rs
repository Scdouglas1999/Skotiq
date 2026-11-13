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
use skotiq_device::{DeviceDriver, DriverError, GuideDirection, MountDriver, TrackingRate, Vendor};
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
    Connect(oneshot::Sender<Result<(), DriverError>>),
    Disconnect(oneshot::Sender<Result<(), DriverError>>),
    SlewToCoordinates(f64, f64, oneshot::Sender<Result<(), DriverError>>),
    SyncToCoordinates(f64, f64, oneshot::Sender<Result<(), DriverError>>),
    Park(oneshot::Sender<Result<(), DriverError>>),
    Unpark(oneshot::Sender<Result<(), DriverError>>),
    GetCoordinates(oneshot::Sender<Result<(f64, f64), DriverError>>),
    IsSlewing(oneshot::Sender<Result<bool, DriverError>>),
    IsParked(oneshot::Sender<Result<bool, DriverError>>),
    CanPark(oneshot::Sender<Result<bool, DriverError>>),
    GetCapabilities(oneshot::Sender<Result<AscomMountCapabilities, DriverError>>),
    Stop(oneshot::Sender<Result<(), DriverError>>),
    AbortSlew(oneshot::Sender<Result<(), DriverError>>),
    SetTracking(bool, oneshot::Sender<Result<(), DriverError>>),
    GetTracking(oneshot::Sender<Result<bool, DriverError>>),
    PulseGuide(
        GuideDirection,
        u32,
        oneshot::Sender<Result<(), DriverError>>,
    ),
    GetSideOfPier(oneshot::Sender<Result<skotiq_device::PierSide, DriverError>>),
    GetAltAz(oneshot::Sender<Result<(f64, f64), DriverError>>),
    GetSiderealTime(oneshot::Sender<Result<f64, DriverError>>),
    // Tracking rate commands
    SetTrackingRate(i32, oneshot::Sender<Result<(), DriverError>>),
    GetTrackingRate(oneshot::Sender<Result<i32, DriverError>>),
    // Axis movement commands (for jogging)
    MoveAxis(i32, f64, oneshot::Sender<Result<(), DriverError>>),
    SlewToAltAz(f64, f64, oneshot::Sender<Result<(), DriverError>>),
    FindHome(oneshot::Sender<Result<(), DriverError>>),
    AtHome(oneshot::Sender<Result<bool, DriverError>>),
    // Store the current position as the park position
    SetPark(oneshot::Sender<Result<(), DriverError>>),
    GetSite(oneshot::Sender<Result<(f64, f64, Option<f64>), DriverError>>),
    SetSite(
        f64,
        f64,
        Option<f64>,
        oneshot::Sender<Result<(), DriverError>>,
    ),
    GetUtcDate(oneshot::Sender<Result<f64, DriverError>>),
    GetEquatorialSystem(oneshot::Sender<Result<i32, DriverError>>),
    IsPulseGuiding(oneshot::Sender<Result<bool, DriverError>>),
    SetUtcDate(f64, oneshot::Sender<Result<(), DriverError>>),
    // Version query commands
}

impl AscomMountCommand {
    /// Whether this command would start the mount moving after its caller has
    /// stopped waiting for it.
    ///
    /// A command queued behind a driver call that hung runs when that call
    /// finally returns, minutes later. A slew or park nobody is waiting for
    /// any more must not run then; stops, aborts and reads still do.
    fn is_abandoned_motion(&self) -> bool {
        match self {
            Self::SlewToCoordinates(_, _, reply)
            | Self::SyncToCoordinates(_, _, reply)
            | Self::SlewToAltAz(_, _, reply) => reply.is_closed(),
            Self::Park(reply)
            | Self::Unpark(reply)
            | Self::FindHome(reply)
            | Self::SetPark(reply) => reply.is_closed(),
            Self::PulseGuide(_, _, reply) => reply.is_closed(),
            Self::MoveAxis(_, rate, reply) => *rate != 0.0 && reply.is_closed(),
            _ => false,
        }
    }
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
    /// Queue a command for the STA worker.
    ///
    /// The queue is bounded and the worker makes one COM call at a time, on a
    /// thread it shares with every other ASCOM device. A driver call that never
    /// returns fills the queue, and a plain `send` would then wait forever,
    /// holding whatever device locks its caller holds: on the rig that froze
    /// every device request in the app behind one stuck mount. Give up after
    /// the write timeout instead, as every reply wait already does.
    async fn enqueue(&self, command: AscomMountCommand) -> Result<(), DriverError> {
        match tokio::time::timeout(Timeouts::property_write(), self.sender.send(command)).await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(_)) => Err(DriverError::Unknown(
                "ASCOM mount worker thread is not running".to_string(),
            )),
            Err(_) => Err(DriverError::Timeout(format!(
                "ASCOM mount {} is not taking commands: an earlier driver call has not returned",
                self.id
            ))),
        }
    }

    pub fn new(prog_id: String) -> Result<Self, String> {
        let (tx, mut rx) = mpsc::channel::<AscomMountCommand>(32);
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
                if cmd.is_abandoned_motion() {
                    tracing::warn!(
                        "ASCOM mount {}: dropping a motion command its caller gave up on",
                        prog_id_clone
                    );
                    return PumpOutcome::DidWork;
                }
                match cmd {
                    AscomMountCommand::Connect(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.connect().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::Disconnect(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.disconnect().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::SlewToCoordinates(ra, dec, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(
                                m.slew_to_coordinates_async(ra, dec)
                                    .map_err(super::ascom_error),
                            );
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::SyncToCoordinates(ra, dec, reply) => {
                        if let Some(m) = &mut mount {
                            match m.can_sync() {
                                Ok(true) => {
                                    let _ = reply.send(
                                        m.sync_to_coordinates(ra, dec).map_err(super::ascom_error),
                                    );
                                }
                                Ok(false) => {
                                    let _ = reply.send(Err(DriverError::NotSupported));
                                }
                                Err(e) => {
                                    let _ = reply.send(Err(DriverError::SdkError(format!(
                                        "Failed to check CanSync: {}",
                                        e
                                    ))));
                                }
                            }
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::Park(reply) => {
                        if let Some(m) = &mut mount {
                            match m.can_park() {
                                Ok(true) => {
                                    let _ = reply.send(m.park().map_err(super::ascom_error));
                                }
                                Ok(false) => {
                                    let _ = reply.send(Err(DriverError::NotSupported));
                                }
                                Err(e) => {
                                    let _ = reply.send(Err(DriverError::SdkError(format!(
                                        "Failed to check CanPark: {}",
                                        e
                                    ))));
                                }
                            }
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::Unpark(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.unpark().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
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
                                    let _ = reply.send(Err(DriverError::SdkError(format!(
                                        "Failed to get RA: {}",
                                        e
                                    ))));
                                }
                                (_, Err(e)) => {
                                    let _ = reply.send(Err(DriverError::SdkError(format!(
                                        "Failed to get DEC: {}",
                                        e
                                    ))));
                                }
                            }
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::IsSlewing(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.slewing().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::IsParked(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.at_park().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::CanPark(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.can_park().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
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
                                can_set_park: m.can_set_park().unwrap_or(false),
                                can_pulse_guide: ascom_caps.can_pulse_guide.unwrap_or(false),
                                can_set_tracking: ascom_caps.can_set_tracking.unwrap_or(false),
                                can_find_home: m.can_find_home().unwrap_or(false),
                                can_move_axis_primary: ascom_caps
                                    .can_move_axis_primary
                                    .unwrap_or(false),
                                can_move_axis_secondary: ascom_caps
                                    .can_move_axis_secondary
                                    .unwrap_or(false),
                                is_equatorial: m.alignment_mode().is_ok_and(|mode| {
                                    skotiq_device::ascom::AlignmentMode::from(mode).is_equatorial()
                                }),
                            };
                            let _ = reply.send(Ok(caps));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::AbortSlew(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.abort_slew().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::SetTracking(enabled, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.set_tracking(enabled).map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::GetTracking(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.tracking().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
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
                                reply.send(m.pulse_guide(d, duration).map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::GetSideOfPier(reply) => {
                        if let Some(m) = &mut mount {
                            match m.side_of_pier() {
                                Ok(0) => {
                                    let _ = reply.send(Ok(skotiq_device::PierSide::East));
                                }
                                Ok(1) => {
                                    let _ = reply.send(Ok(skotiq_device::PierSide::West));
                                }
                                Ok(_) => {
                                    let _ = reply.send(Ok(skotiq_device::PierSide::Unknown));
                                }
                                Err(e) => {
                                    let _ = reply.send(Err(DriverError::SdkError(e.to_string())));
                                }
                            }
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
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
                                    let _ = reply.send(Err(DriverError::SdkError(format!(
                                        "Failed to get Alt: {}",
                                        e
                                    ))));
                                }
                                (_, Err(e)) => {
                                    let _ = reply.send(Err(DriverError::SdkError(format!(
                                        "Failed to get Az: {}",
                                        e
                                    ))));
                                }
                            }
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::GetSiderealTime(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.sidereal_time().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::SetTrackingRate(rate, reply) => {
                        if let Some(m) = &mut mount {
                            let _ =
                                reply.send(m.set_tracking_rate(rate).map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::GetTrackingRate(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.tracking_rate().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::MoveAxis(axis, rate, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.move_axis(axis, rate).map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::Stop(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.abort_slew().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::SlewToAltAz(alt, az, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply
                                .send(m.slew_to_alt_az_async(alt, az).map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
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
                            let _ = reply.send(site.map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
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
                            let _ = reply.send(result.map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::GetUtcDate(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.utc_date().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::IsPulseGuiding(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.is_pulse_guiding().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::GetEquatorialSystem(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.equatorial_system().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::SetUtcDate(value, reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.set_utc_date(value).map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::FindHome(reply) => {
                        if let Some(m) = &mut mount {
                            match m.can_find_home() {
                                Ok(true) => {
                                    let _ = reply.send(m.find_home().map_err(super::ascom_error));
                                }
                                Ok(false) => {
                                    let _ = reply.send(Err(DriverError::NotSupported));
                                }
                                Err(e) => {
                                    let _ = reply.send(Err(DriverError::SdkError(format!(
                                        "Failed to check CanFindHome: {}",
                                        e
                                    ))));
                                }
                            }
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::AtHome(reply) => {
                        if let Some(m) = &mut mount {
                            let _ = reply.send(m.at_home().map_err(super::ascom_error));
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
                        }
                    }
                    AscomMountCommand::SetPark(reply) => {
                        if let Some(m) = &mut mount {
                            match m.can_set_park() {
                                Ok(true) => {
                                    let _ = reply.send(m.set_park().map_err(super::ascom_error));
                                }
                                Ok(false) => {
                                    let _ = reply.send(Err(DriverError::NotSupported));
                                }
                                Err(e) => {
                                    let _ = reply.send(Err(DriverError::SdkError(format!(
                                        "Failed to check CanSetPark: {}",
                                        e
                                    ))));
                                }
                            }
                        } else {
                            let _ = reply
                                .send(Err(DriverError::SdkError("Mount not created".to_string())));
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

    /// Get the mount's capabilities by querying the ASCOM device
    ///
    /// This queries all capability-related properties from the mount and returns
    /// a comprehensive capabilities struct. The device should be connected before
    /// calling this method.
    pub async fn get_capabilities(&self) -> Result<AscomMountCapabilities, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetCapabilities(tx)).await?;
        let mut caps =
            super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_capabilities")
                .await?;
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

    pub async fn can_park(&self) -> Result<bool, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::CanPark(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "can_park").await
    }

    pub async fn slew_to_alt_az(&self, alt: f64, az: f64) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::SlewToAltAz(alt, az, tx))
            .await?;
        super::recv_with_timeout("Mount", rx, Timeouts::long_slew(), "slew_to_alt_az").await
    }

    pub async fn get_site(&self) -> Result<(f64, f64, Option<f64>), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetSite(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_site").await
    }

    pub async fn set_site(
        &self,
        latitude_deg: f64,
        longitude_deg: f64,
        elevation_m: Option<f64>,
    ) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::SetSite(
            latitude_deg,
            longitude_deg,
            elevation_m,
            tx,
        ))
        .await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_write(), "set_site").await
    }

    /// UTCDate as an OLE Automation date (days since 1899-12-30).
    pub async fn get_utc_date(&self) -> Result<f64, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetUtcDate(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_utc_date").await
    }

    /// `IsPulseGuiding`: whether a guide pulse is still running.
    pub async fn is_pulse_guiding(&self) -> Result<bool, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::IsPulseGuiding(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "is_pulse_guiding").await
    }

    /// `EquatorialSystem`: the frame the driver takes and reports RA/Dec in.
    pub async fn equatorial_system(&self) -> Result<i32, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetEquatorialSystem(tx))
            .await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "equatorial_system")
            .await
    }

    pub async fn set_utc_date(&self, utc_date: f64) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::SetUtcDate(utc_date, tx))
            .await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_write(), "set_utc_date").await
    }

    /// Send the mount to its home position through the COM worker.
    ///
    /// ITelescopeV3 drivers implement `FindHome` synchronously and hand the
    /// call back when the mount arrives, so the wait is bounded by the
    /// find-home timeout rather than a property-read one. A driver whose
    /// `CanFindHome` is false answers [`DriverError::NotSupported`].
    pub async fn find_home(&self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::FindHome(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::find_home(), "find_home").await
    }

    /// Store the current position as the park position through the COM
    /// worker. A driver whose `CanSetPark` is false answers
    /// [`DriverError::NotSupported`].
    pub async fn set_park(&self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::SetPark(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_write(), "set_park").await
    }

    /// `AtHome`: whether the mount is stopped at its home position. ASCOM sets
    /// it only after a `FindHome` and clears it on the next slew.
    pub async fn at_home(&self) -> Result<bool, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::AtHome(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "at_home").await
    }

    pub async fn stop(&self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::Stop(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::connection(), "stop").await
    }
}

#[async_trait::async_trait]
impl DeviceDriver for AscomMountWrapper {
    fn id(&self) -> &str {
        &self.id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        Vendor::Ascom
    }

    fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::Connect(tx)).await?;
        let result = super::recv_with_timeout("Mount", rx, Timeouts::connection(), "connect").await;
        if result.is_ok() {
            self.connected.store(true, Ordering::SeqCst);
        }
        result
    }

    /// Releases the driver without commanding the mount, as the Alpaca path
    /// does: a slew still running belongs to whoever started it (the user in
    /// the driver's own app or the hand controller, often), and the driver
    /// keeps the hardware for its other clients.
    async fn disconnect(&mut self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::Disconnect(tx)).await?;
        let disconnect_result =
            super::recv_with_timeout("Mount", rx, Timeouts::connection(), "disconnect").await;
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
impl MountDriver for AscomMountWrapper {
    async fn slew_to_coordinates(&mut self, ra: f64, dec: f64) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::SlewToCoordinates(ra, dec, tx))
            .await?;
        // Slews can take a long time
        super::recv_with_timeout("Mount", rx, Timeouts::long_slew(), "slew_to_coordinates").await
    }

    async fn sync_to_coordinates(&mut self, ra: f64, dec: f64) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::SyncToCoordinates(ra, dec, tx))
            .await?;
        super::recv_with_timeout(
            "Mount",
            rx,
            Timeouts::property_write(),
            "sync_to_coordinates",
        )
        .await
    }

    async fn park(&mut self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::Park(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::park(), "park").await
    }

    async fn unpark(&mut self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::Unpark(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::park(), "unpark").await
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetCoordinates(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_coordinates").await
    }

    async fn is_slewing(&self) -> Result<bool, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::IsSlewing(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "is_slewing").await
    }

    async fn is_parked(&self) -> Result<bool, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::IsParked(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "is_parked").await
    }

    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::PulseGuide(direction, duration_ms, tx))
            .await?;
        // Pulse guide takes the duration plus a buffer
        // Why: `duration_ms` is u32 pulse-guide
        // milliseconds (≤ a few thousand for real guiding); u32 → u64
        // widening, exact.
        let timeout = Duration::from_millis(u64::from(duration_ms)) + Timeouts::short_slew();
        super::recv_with_timeout("Mount", rx, timeout, "pulse_guide").await
    }

    async fn abort_slew(&mut self) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::AbortSlew(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_write(), "abort_slew").await
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::SetTracking(enabled, tx))
            .await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_write(), "set_tracking").await
    }

    async fn get_tracking(&self) -> Result<bool, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetTracking(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_tracking").await
    }

    async fn get_side_of_pier(&self) -> Result<skotiq_device::PierSide, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetSideOfPier(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_side_of_pier").await
    }

    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetAltAz(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_alt_az").await
    }

    async fn get_sidereal_time(&self) -> Result<f64, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetSiderealTime(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_sidereal_time").await
    }

    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), DriverError> {
        let rate_int = match rate {
            TrackingRate::Sidereal => 0,
            TrackingRate::Lunar => 1,
            TrackingRate::Solar => 2,
            TrackingRate::King => 3,
            TrackingRate::Custom => return Err(DriverError::NotSupported),
        };
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::SetTrackingRate(rate_int, tx))
            .await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_write(), "set_tracking_rate").await
    }

    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetTrackingRate(tx)).await?;
        let rate_int =
            super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_tracking_rate")
                .await?;
        match rate_int {
            0 => Ok(TrackingRate::Sidereal),
            1 => Ok(TrackingRate::Lunar),
            2 => Ok(TrackingRate::Solar),
            3 => Ok(TrackingRate::King),
            _ => Ok(TrackingRate::Custom),
        }
    }

    async fn can_slew(&self) -> bool {
        true
    }

    async fn can_sync(&self) -> bool {
        true
    }

    async fn can_pulse_guide(&self) -> bool {
        true
    }

    async fn can_set_tracking_rate(&self) -> bool {
        false
    }
}

// Additional mount control methods (not in MountDriver trait)
impl AscomMountWrapper {
    /// Set the tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
    pub async fn set_tracking_rate_raw(&mut self, rate: i32) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::SetTrackingRate(rate, tx))
            .await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_write(), "set_tracking_rate").await
    }

    /// Get the current tracking rate (0=Sidereal, 1=Lunar, 2=Solar, 3=King)
    pub async fn get_tracking_rate_raw(&self) -> Result<i32, DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::GetTrackingRate(tx)).await?;
        super::recv_with_timeout("Mount", rx, Timeouts::property_read(), "get_tracking_rate").await
    }

    /// Move an axis at the specified rate (degrees/second)
    /// axis: 0=RA/Azimuth (primary), 1=Dec/Altitude (secondary)
    /// rate: degrees per second (positive = N/E, negative = S/W), 0 to stop
    pub async fn move_axis(&mut self, axis: i32, rate: f64) -> Result<(), DriverError> {
        let (tx, rx) = oneshot::channel();
        self.enqueue(AscomMountCommand::MoveAxis(axis, rate, tx))
            .await?;
        super::recv_with_timeout("Mount", rx, Timeouts::short_slew(), "move_axis").await
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
        pub side_of_pier: skotiq_device::PierSide,
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
                side_of_pier: skotiq_device::PierSide::Unknown,
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

    /// A connected wrapper whose worker answers every command, keeps the
    /// state the commands change (tracking, parked, position, tracking rate)
    /// and hands each command's name and arguments to `saw` before answering.
    /// The mount starts parked, not tracking, at RA 5.5 h / Dec 22 degrees.
    pub fn build_recording_mount_wrapper(
        saw: impl Fn(String) + Send + 'static,
    ) -> AscomMountWrapper {
        let (tx, mut rx) = mpsc::channel(8);
        let _handle = thread::spawn(move || {
            let (mut tracking, mut parked, mut rate) = (false, true, 0);
            let mut position = (5.5, 22.0);
            while let Some(cmd) = crate::ascom_wrapper::pump_blocking_recv(&mut rx) {
                use AscomMountCommand::*;
                match cmd {
                    Connect(reply) => {
                        saw("Connect".into());
                        let _ = reply.send(Ok(()));
                    }
                    Disconnect(reply) => {
                        saw("Disconnect".into());
                        let _ = reply.send(Ok(()));
                    }
                    SlewToCoordinates(ra, dec, reply) => {
                        saw(format!("SlewToCoordinates {ra:.1} {dec:.1}"));
                        position = (ra, dec);
                        let _ = reply.send(Ok(()));
                    }
                    SyncToCoordinates(ra, dec, reply) => {
                        saw(format!("SyncToCoordinates {ra:.1} {dec:.1}"));
                        position = (ra, dec);
                        let _ = reply.send(Ok(()));
                    }
                    Park(reply) => {
                        saw("Park".into());
                        parked = true;
                        tracking = false;
                        let _ = reply.send(Ok(()));
                    }
                    Unpark(reply) => {
                        saw("Unpark".into());
                        parked = false;
                        let _ = reply.send(Ok(()));
                    }
                    GetCoordinates(reply) => {
                        saw("GetCoordinates".into());
                        let _ = reply.send(Ok(position));
                    }
                    IsSlewing(reply) => {
                        saw("IsSlewing".into());
                        let _ = reply.send(Ok(false));
                    }
                    IsParked(reply) => {
                        saw("IsParked".into());
                        let _ = reply.send(Ok(parked));
                    }
                    CanPark(reply) => {
                        saw("CanPark".into());
                        let _ = reply.send(Ok(true));
                    }
                    GetCapabilities(reply) => {
                        saw("GetCapabilities".into());
                        let _ = reply.send(Ok(AscomMountCapabilities {
                            can_slew: true,
                            can_slew_async: true,
                            can_sync: true,
                            can_park: true,
                            can_unpark: true,
                            can_set_park: true,
                            can_pulse_guide: true,
                            can_set_tracking: true,
                            can_find_home: true,
                            can_move_axis_primary: true,
                            can_move_axis_secondary: true,
                            is_equatorial: true,
                        }));
                    }
                    Stop(reply) => {
                        saw("Stop".into());
                        let _ = reply.send(Ok(()));
                    }
                    AbortSlew(reply) => {
                        saw("AbortSlew".into());
                        let _ = reply.send(Ok(()));
                    }
                    SetTracking(on, reply) => {
                        saw(format!("SetTracking {on}"));
                        tracking = on;
                        let _ = reply.send(Ok(()));
                    }
                    GetTracking(reply) => {
                        saw("GetTracking".into());
                        let _ = reply.send(Ok(tracking));
                    }
                    PulseGuide(direction, ms, reply) => {
                        saw(format!("PulseGuide {direction:?} {ms}"));
                        let _ = reply.send(Ok(()));
                    }
                    GetSideOfPier(reply) => {
                        saw("GetSideOfPier".into());
                        let _ = reply.send(Ok(skotiq_device::PierSide::East));
                    }
                    GetAltAz(reply) => {
                        saw("GetAltAz".into());
                        let _ = reply.send(Ok((45.0, 180.0)));
                    }
                    GetSiderealTime(reply) => {
                        saw("GetSiderealTime".into());
                        let _ = reply.send(Ok(5.0));
                    }
                    SetTrackingRate(value, reply) => {
                        saw(format!("SetTrackingRate {value}"));
                        rate = value;
                        let _ = reply.send(Ok(()));
                    }
                    GetTrackingRate(reply) => {
                        saw("GetTrackingRate".into());
                        let _ = reply.send(Ok(rate));
                    }
                    MoveAxis(axis, speed, reply) => {
                        saw(format!("MoveAxis {axis} {speed}"));
                        let _ = reply.send(Ok(()));
                    }
                    SlewToAltAz(alt, az, reply) => {
                        saw(format!("SlewToAltAz {alt:.4} {az:.4}"));
                        let _ = reply.send(Ok(()));
                    }
                    FindHome(reply) => {
                        saw("FindHome".into());
                        let _ = reply.send(Ok(()));
                    }
                    AtHome(reply) => {
                        saw("AtHome".into());
                        let _ = reply.send(Ok(false));
                    }
                    SetPark(reply) => {
                        saw("SetPark".into());
                        let _ = reply.send(Ok(()));
                    }
                    GetSite(reply) => {
                        saw("GetSite".into());
                        let _ = reply.send(Ok((40.0, -75.0, Some(100.0))));
                    }
                    SetSite(latitude, longitude, elevation, reply) => {
                        saw(format!("SetSite {latitude:.4} {longitude:.4} {elevation:?}"));
                        let _ = reply.send(Ok(()));
                    }
                    GetUtcDate(reply) => {
                        saw("GetUtcDate".into());
                        let _ = reply.send(Ok(46338.125));
                    }
                    GetEquatorialSystem(reply) => {
                        saw("GetEquatorialSystem".into());
                        let _ = reply.send(Ok(1));
                    }
                    IsPulseGuiding(reply) => {
                        saw("IsPulseGuiding".into());
                        let _ = reply.send(Ok(false));
                    }
                    SetUtcDate(days, reply) => {
                        saw(format!("SetUtcDate {days:.6}"));
                        let _ = reply.send(Ok(()));
                    }
                }
            }
        });

        AscomMountWrapper {
            id: "test-mount".to_string(),
            name: "Test Mount".to_string(),
            sender: tx,
            connected: std::sync::atomic::AtomicBool::new(true),
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

    /// A driver call that never returns must not hang every later caller. The
    /// worker below takes the first command and never answers; the queue holds
    /// eight more. Before the bounded enqueue the tenth caller waited on `send`
    /// forever, and on the rig that caller held the device table's read lock.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn a_wedged_worker_fails_every_caller_instead_of_hanging() {
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let wrapper = Arc::new(build_test_wrapper(move |_cmd| {
            let _ = release_rx.recv();
            true
        }));
        let mut calls = tokio::task::JoinSet::new();
        for _ in 0..10 {
            let wrapper = Arc::clone(&wrapper);
            calls.spawn(async move { wrapper.get_tracking().await });
        }
        let results = tokio::time::timeout(Duration::from_secs(30), async {
            let mut results = Vec::new();
            while let Some(result) = calls.join_next().await {
                results.push(result.expect("call task panicked"));
            }
            results
        })
        .await
        .expect("a caller hung behind the wedged worker");
        assert_eq!(results.len(), 10);
        assert!(results
            .iter()
            .all(|r| matches!(r, Err(DriverError::Timeout(_)))));
        drop(release_tx);
    }

    #[test]
    fn a_motion_command_nobody_waits_for_is_abandoned() {
        let (tx, rx) = oneshot::channel();
        drop(rx);
        assert!(AscomMountCommand::Park(tx).is_abandoned_motion());

        let (tx, rx) = oneshot::channel();
        drop(rx);
        assert!(AscomMountCommand::SlewToCoordinates(1.0, 2.0, tx).is_abandoned_motion());

        let (tx, rx) = oneshot::channel();
        drop(rx);
        assert!(AscomMountCommand::MoveAxis(0, 1.0, tx).is_abandoned_motion());
    }

    #[test]
    fn stops_reads_and_awaited_motion_are_never_abandoned() {
        let (tx, rx) = oneshot::channel();
        drop(rx);
        assert!(!AscomMountCommand::MoveAxis(0, 0.0, tx).is_abandoned_motion());

        let (tx, rx) = oneshot::channel();
        drop(rx);
        assert!(!AscomMountCommand::AbortSlew(tx).is_abandoned_motion());

        let (tx, rx) = oneshot::channel();
        drop(rx);
        assert!(!AscomMountCommand::IsParked(tx).is_abandoned_motion());

        let (tx, _rx) = oneshot::channel();
        assert!(!AscomMountCommand::Park(tx).is_abandoned_motion());
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

    /// FindHome travels through the COM worker and its success comes back
    /// to the caller.
    #[tokio::test]
    async fn find_home_is_sent_to_the_com_worker() {
        let sent = Arc::new(Mutex::new(0u32));
        let sent_flag = Arc::clone(&sent);
        let wrapper = build_test_wrapper(move |cmd| {
            if let AscomMountCommand::FindHome(reply) = cmd {
                *sent_flag.lock().expect("lock sent") += 1;
                let _ = reply.send(Ok(()));
            }
            false
        });

        wrapper.find_home().await.expect("find_home");
        assert_eq!(*sent.lock().expect("lock sent"), 1);
    }

    /// A driver whose CanFindHome is false is reported as unsupported, not as
    /// a driver fault, so the caller can tell the operator the mount has no
    /// home rather than that something broke.
    #[tokio::test]
    async fn find_home_on_a_driver_without_home_is_not_supported() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomMountCommand::FindHome(reply) = cmd {
                let _ = reply.send(Err(DriverError::NotSupported));
            }
            false
        });

        assert!(matches!(
            wrapper.find_home().await,
            Err(DriverError::NotSupported)
        ));
    }

    #[tokio::test]
    async fn set_park_on_a_driver_without_set_park_is_not_supported() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomMountCommand::SetPark(reply) = cmd {
                let _ = reply.send(Err(DriverError::NotSupported));
            }
            false
        });

        assert!(matches!(
            wrapper.set_park().await,
            Err(DriverError::NotSupported)
        ));
    }

    #[tokio::test]
    async fn at_home_reads_the_driver_flag() {
        let wrapper = build_test_wrapper(|cmd| {
            if let AscomMountCommand::AtHome(reply) = cmd {
                let _ = reply.send(Ok(true));
            }
            false
        });

        assert!(wrapper.at_home().await.expect("at_home"));
    }

    /// Disconnecting is not a motion command: a slew someone else started
    /// keeps going, as it does when an Alpaca mount is released.
    #[tokio::test]
    async fn disconnect_sends_no_motion_command() {
        let sent = Arc::new(Mutex::new(Vec::new()));
        let sent_log = Arc::clone(&sent);
        let mut wrapper = build_test_wrapper(move |cmd| match cmd {
            AscomMountCommand::Disconnect(reply) => {
                sent_log.lock().expect("lock sent").push("disconnect");
                let _ = reply.send(Ok(()));
                true
            }
            AscomMountCommand::Stop(reply) | AscomMountCommand::AbortSlew(reply) => {
                sent_log.lock().expect("lock sent").push("abort");
                let _ = reply.send(Ok(()));
                false
            }
            _ => false,
        });
        wrapper.disconnect().await.expect("disconnect");
        assert_eq!(sent.lock().expect("lock sent").as_slice(), ["disconnect"]);
        assert!(!wrapper.is_connected());
    }
}
