//! Device connection lifecycle: register, connect, disconnect, auto-reconnect.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! contain the cross-driver lifecycle logic. Driver-specific `connect_*`
//! helpers continue to live in `crate::dispatch::{ascom,alpaca,indi,native}`
//! (also split-impl-block) and are invoked from `connect_device_internal`
//! below.

use crate::device::{ConnectionState, DeviceInfo, DeviceType, DriverType};
use crate::device_manager::handle::{device_noun, protocol_label};
use crate::device_manager::identity::{DeviceIdentity, IDENTITY_CONFLICT_MARKER};
use crate::device_manager::policy::policy;
use crate::device_manager::{DeviceManager, ManagedDevice};
use crate::event::equipment::{EquipmentEvent, EventSeverity};
use std::time::Duration;
use tokio::sync::watch;
use tokio::time::interval;
// `DeviceDriver` also backs the ASCOM wrapper guards on Windows; the identity
// probe below needs it (and `CameraDriver`) on every platform.
use skotiq_device::{CameraDriver, DeviceDriver};

/// Error message returned by `connect_device_internal` when an in-flight
/// reconnect attempt is aborted by a manual disconnect. The string is part
/// of the public contract (the reconnection loop matches on it to suppress
/// noisy "reconnection attempt failed" events).
pub(crate) const RECONNECT_CANCELED_MSG: &str = "reconnect canceled by manual disconnect";

impl DeviceManager {
    /// Install (or reuse) a per-device cancellation token. The returned
    /// receiver is used by `connect_device_internal` to bail early if a
    /// manual `disconnect_device` arrives during the connect cycle.
    ///
    /// If a previous attempt left a tripped token in the map, this resets
    /// it to `false` so the new attempt starts un-canceled.
    pub(crate) async fn install_reconnect_cancel_token(
        &self,
        device_id: &str,
    ) -> watch::Receiver<bool> {
        let mut tokens = self.reconnect_cancel_tokens.write().await;
        if let Some(sender) = tokens.get(device_id) {
            // Reset to un-tripped state for a fresh attempt.
            // `send_replace` ignores receiver count and doesn't fail when there
            // are no receivers, which suits our reuse-on-second-attempt case.
            let _ = sender.send_replace(false);
            return sender.subscribe();
        }
        let (tx, rx) = watch::channel(false);
        tokens.insert(device_id.to_string(), tx);
        rx
    }

    /// Trip the per-device reconnect cancellation token, if one exists.
    ///
    /// Called from `disconnect_device` so that any in-flight
    /// `connect_device_internal` attempt notices and aborts before publishing
    /// a stale `Connected` event for the device the user just released.
    pub(crate) async fn trip_reconnect_cancel_token(&self, device_id: &str) {
        let tokens = self.reconnect_cancel_tokens.read().await;
        if let Some(sender) = tokens.get(device_id) {
            // send_replace overwrites the value unconditionally. We don't care
            // whether anyone is listening: if nobody is, there was no in-flight
            // attempt to cancel and the no-op is the correct behavior.
            let _ = sender.send_replace(true);
        }
    }

    /// Check whether the given cancellation receiver has been tripped.
    /// Pure inspection — does not await.
    fn reconnect_canceled(rx: &watch::Receiver<bool>) -> bool {
        *rx.borrow()
    }

    /// Subscribe to the existing cancel token for `device_id`, if any.
    ///
    /// Unlike `install_reconnect_cancel_token`, this does NOT create a new
    /// sender on miss, nor reset a tripped one: it only borrows the token the
    /// caller of `connect_device_internal` installed for this attempt.
    async fn subscribe_existing_cancel_token(
        &self,
        device_id: &str,
    ) -> Option<watch::Receiver<bool>> {
        let tokens = self.reconnect_cancel_tokens.read().await;
        tokens.get(device_id).map(|sender| sender.subscribe())
    }

    /// Background task for automatic reconnection
    pub(crate) async fn reconnection_loop(&self) {
        let mut check_interval = interval(Duration::from_secs(5));

        loop {
            check_interval.tick().await;

            if !self.reconnect_config.enabled {
                continue;
            }

            let devices_to_reconnect: Vec<(String, ManagedDevice)> = {
                let devices = self.devices.read().await;
                devices
                    .iter()
                    .filter(|(_, dev)| {
                        dev.auto_reconnect
                            && dev.connection_state == ConnectionState::Error
                            && (self.reconnect_config.max_attempts == 0
                                || dev.reconnect_attempts < self.reconnect_config.max_attempts)
                    })
                    .map(|(id, dev)| (id.clone(), dev.clone()))
                    .collect()
            };

            // Attempt reconnection for each device
            for (device_id, device) in devices_to_reconnect {
                tracing::info!(
                    "Attempting reconnection for {} (attempt {})",
                    device_id,
                    device.reconnect_attempts + 1
                );

                // Install/reset the per-device cancel token BEFORE the backoff
                // sleep, so a disconnect arriving during the sleep is observed
                // when we wake up (and during the connect dispatch below).
                let mut cancel_rx = self.install_reconnect_cancel_token(&device_id).await;

                // Calculate backoff delay, but race it against the cancel
                // token so a manual disconnect during the sleep aborts the
                // entire attempt — not just the subsequent connect call.
                let delay = self.calculate_backoff_delay(device.reconnect_attempts);
                let sleep_fut = tokio::time::sleep(Duration::from_secs(delay));
                tokio::pin!(sleep_fut);
                let canceled_during_sleep = tokio::select! {
                    _ = &mut sleep_fut => false,
                    res = cancel_rx.changed() => {
                        // changed() returns Err only if the sender was dropped,
                        // which only happens during shutdown — treat as cancel.
                        res.is_err() || *cancel_rx.borrow()
                    }
                };

                if canceled_during_sleep {
                    tracing::info!(
                        "Reconnect for {} canceled during backoff (manual disconnect)",
                        device_id
                    );
                    continue;
                }

                self.attempt_reconnect(&device_id, &device.info).await;
            }
        }
    }

    /// One reconnect attempt, after its backoff. A failed connect already
    /// publishes the device's Error with the reason; the attempt only counts
    /// it, so one failed attempt is one event.
    pub(crate) async fn attempt_reconnect(&self, device_id: &str, info: &DeviceInfo) {
        // `connect_device_internal` re-checks the cancel token at additional
        // checkpoints inside the call.
        match self.connect_device_internal(info).await {
            Err(e) if e == RECONNECT_CANCELED_MSG => {
                // The user stopped it with a disconnect: not a failed attempt.
                tracing::info!(
                    "Reconnect for {} canceled mid-attempt (manual disconnect)",
                    device_id
                );
            }
            Err(e) => {
                let mut devices = self.devices.write().await;
                if let Some(dev) = devices.get_mut(device_id) {
                    dev.reconnect_attempts += 1;
                    tracing::warn!(
                        "Reconnection attempt {} failed for {}: {}",
                        dev.reconnect_attempts,
                        device_id,
                        e
                    );
                    dev.last_error = Some(e);
                }
            }
            Ok(()) => {
                tracing::info!("Reconnection successful for {}", device_id);

                let mut devices = self.devices.write().await;
                if let Some(dev) = devices.get_mut(device_id) {
                    dev.reconnect_attempts = 0;
                    dev.last_error = None;
                }
            }
        }
    }

    /// Calculate backoff delay for reconnection
    pub(crate) fn calculate_backoff_delay(&self, attempts: u32) -> u64 {
        // Why: u64 (initial_delay_secs) → f64 has bounded
        // precision loss for any realistic config (seconds, not nanoseconds).
        // u32 → i32 for `powi` saturates at i32::MAX (~2B retries) which is
        // unreachable; the result is then clamped by `min(max_delay_secs)`.
        // f64 → u64 uses Rust 1.45+ saturating semantics for the final cast.
        let delay = (self.reconnect_config.initial_delay_secs as f64)
            * self
                .reconnect_config
                .backoff_multiplier
                .powi(i32::try_from(attempts).unwrap_or(i32::MAX));

        (delay as u64).min(self.reconnect_config.max_delay_secs)
    }

    /// Register a device for management
    pub async fn register_device(&self, info: DeviceInfo, auto_reconnect: bool) {
        self.insert_device(info, auto_reconnect, ConnectionState::Disconnected)
            .await;
    }

    /// Register a device that is ALREADY connected, in the `Connected` state.
    ///
    /// The normal lifecycle is `register_device` (as `Disconnected`) then
    /// `connect_device`, which dispatches to a driver and flips the state. A
    /// backend that owns its own out-of-band transport — PHD2 talks JSON-RPC
    /// over its own TCP socket, opened by `guider::phd2::connect`, not by any driver
    /// in `dispatch/` — has nothing for `connect_device` to dispatch to, so it
    /// records the already-live connection here instead. A backend that skips
    /// this is invisible to `is_device_connected` /
    /// `get_connected_device_infos`, so the app reports "no guider connected"
    /// while the sequencer is guiding through it.
    ///
    /// `auto_reconnect` is always false: `reconnection_loop` reconnects through
    /// `connect_device_internal`, which cannot re-open a transport it does not
    /// own.
    pub async fn register_connected_device(&self, info: DeviceInfo) {
        self.insert_device(info, false, ConnectionState::Connected)
            .await;
    }

    async fn insert_device(
        &self,
        info: DeviceInfo,
        auto_reconnect: bool,
        connection_state: ConnectionState,
    ) {
        let mut devices = self.devices.write().await;
        devices.insert(
            info.id.clone(),
            ManagedDevice {
                info,
                connection_state,
                last_error: None,
                reconnect_attempts: 0,
                auto_reconnect,
                last_successful_comm: None,
                heartbeat_deferred_at: None,
                heartbeat_active: false,
                desired_cooler: None,
                desired_tracking: None,
                declared_mount_frame: None,
            },
        );
    }

    pub async fn is_device_registered(&self, device_id: &str) -> bool {
        let devices = self.devices.read().await;
        devices.contains_key(device_id)
    }

    /// Connect to a device on request (the user, a profile, the API).
    ///
    /// A requested connect starts with its own un-tripped cancel token. A
    /// manual disconnect trips the device's token and leaves it tripped, so
    /// borrowing the old one made every later connect fail at once with
    /// "reconnect canceled by manual disconnect" until the app restarted. A
    /// disconnect that arrives while this connect runs still trips the fresh
    /// token and cancels it.
    pub async fn connect_device(&self, device_id: &str) -> Result<(), String> {
        let device_info = {
            let devices = self.devices.read().await;
            devices
                .get(device_id)
                .map(|d| d.info.clone())
                .ok_or_else(|| format!("Device not found: {}", device_id))?
        };

        let _cancel_rx = self.install_reconnect_cancel_token(device_id).await;
        self.connect_device_internal(&device_info).await
    }

    /// [`Self::connect_device`], naming the model the caller expects at the
    /// id. The expectation stays with the id, so the reconnection loop checks
    /// it too, until a later connect names another.
    ///
    /// Device ids such as `native:zwo:1` are positions on the bus. The
    /// identity the id was last seen with is the wrong reference once the bus
    /// re-enumerates: it then describes the device that moved away, and a
    /// connect to where the wanted device now sits would be refused for not
    /// being the device that left. The expectation is the reference that
    /// survives that.
    pub async fn connect_device_expecting(
        &self,
        device_id: &str,
        expected_model: Option<&str>,
    ) -> Result<(), String> {
        if let Some(model) = expected_model.map(str::trim).filter(|m| !m.is_empty()) {
            self.expected_models
                .lock()
                .unwrap_or_else(|p| p.into_inner())
                .insert(device_id.to_string(), model.to_string());
        }
        self.connect_device(device_id).await
    }

    pub(crate) async fn connect_device_internal(&self, info: &DeviceInfo) -> Result<(), String> {
        let device_id = &info.id;

        // Subscribe to the device's cancel token. The reconnection loop and
        // `connect_device` each install a fresh one before calling here, so a
        // `disconnect_device` during the attempt cancels it.
        let cancel_rx = self.subscribe_existing_cancel_token(device_id).await;

        // Pre-dispatch cancel check: a manual `disconnect_device` may have run
        // between the reconnection loop's backoff wakeup and our entry here.
        if let Some(rx) = cancel_rx.as_ref() {
            if Self::reconnect_canceled(rx) {
                return Err(RECONNECT_CANCELED_MSG.to_string());
            }
        }

        // Update state to connecting. Capture the prior state first: a connect
        // arriving from `ConnectionState::Error` is an *unplanned reconnect*
        // (the heartbeat-lost path), and on success we must
        // re-apply the essential device state the driver loses across a
        // physical reconnect (camera cooling setpoint, mount tracking). A
        // fresh user-initiated connect from Disconnected does NOT re-apply —
        // there is no prior desired state worth restoring and the user is
        // about to drive the device anyway.
        let was_error_before_connect = {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(device_id) {
                let prior = dev.connection_state == ConnectionState::Error;
                dev.connection_state = ConnectionState::Connecting;
                prior
            } else {
                false
            }
        };

        self.app_state.publish_equipment_event(
            EquipmentEvent::Connecting {
                device_type: info.device_type.as_str().to_string(),
                device_id: device_id.clone(),
                device_name: info.shown_name(),
            },
            EventSeverity::Info,
        );

        // Perform actual connection based on driver type
        let result = match info.driver_type {
            DriverType::Simulator => self.connect_simulator(info).await,
            DriverType::Ascom => self.connect_ascom(info).await,
            DriverType::Alpaca => self.connect_alpaca(info).await,
            DriverType::Indi => self.connect_indi(info).await,
            DriverType::Native => self.connect_native(info).await,
        };

        // The driver is open now, so ask it who it actually is. Every device id
        // Skotiq uses is positional (`native:zwo:1` is an SDK enumeration
        // index, `ascom:ASCOM.ASICamera2.Camera` is a driver slot), so a
        // successful connect proves only that SOMETHING answered — not that it
        // is the device the caller named. This turns a successful open into a
        // failed connect when the hardware behind the id has changed.
        let result = match result {
            Ok(()) => self.verify_identity_after_connect(info).await,
            Err(e) => Err(e),
        };

        // Post-dispatch cancel check: the driver dispatch above can take
        // seconds (TCP/USB negotiation). If `disconnect_device` tripped the
        // token while we were awaiting, treat the result as canceled so we
        // never overwrite the user's `Disconnected` with `Connected` and
        // never publish a misleading event.
        //
        // A dispatch that happened to succeed has its success discarded, so
        // the user sees their disconnect honored. The reconnection_loop
        // already special-cases
        // `RECONNECT_CANCELED_MSG` to suppress the "attempt failed" event.
        //
        // One result is never converted: an identity conflict trips this very
        // token itself, because `verify_identity_after_connect` releases the
        // wrong device through `disconnect_device`. Letting that self-inflicted
        // trip win would replace "this id is now a different camera" with
        // "reconnect canceled by manual disconnect" — a sentence that is both
        // false (nobody canceled anything) and suppressed by the reconnection
        // loop, so the one path the identity check exists for (a mid-night
        // replug re-binding the id) would report nothing at all to the
        // operator.
        if let Some(rx) = cancel_rx.as_ref() {
            if Self::reconnect_canceled(rx) && !Self::is_identity_conflict(&result) {
                // Best-effort: leave the device in whatever state the post-
                // dispatch result implies; the disconnect path will fix it up
                // when it acquires the `devices` write lock next.
                return Err(RECONNECT_CANCELED_MSG.to_string());
            }
        }

        {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(device_id) {
                match &result {
                    Ok(_) => {
                        dev.connection_state = ConnectionState::Connected;
                        dev.last_error = None;
                        dev.reconnect_attempts = 0;
                        self.status_reads.forget(device_id);
                    }
                    Err(e) => {
                        dev.connection_state = ConnectionState::Error;
                        dev.last_error = Some(e.clone());
                    }
                }
            }
        }

        // A connect that failed because the device is no longer in the vendor
        // SDK's enumeration proves the cached discovery list is stale. Drop it,
        // so the next list tells the truth instead of continuing to offer
        // hardware that is gone.
        //
        // The discovery cache holds for 60 s (`DISCOVERY_CACHE_TTL`), so
        // without this a client that retries — or an unattended rig
        // auto-connecting at dusk — keeps failing against a list nobody has
        // refreshed. This is the automatic form of the manual rescan that
        // otherwise clears it.
        if let Err(e) = &result {
            if Self::is_stale_enumeration_error(e) {
                tracing::warn!(
                    "Connect to {} failed because the SDK no longer enumerates it \
                     ({}); invalidating the discovery cache so the next list is \
                     accurate",
                    device_id,
                    e
                );
                crate::discovery::forget().await;
            }
        }

        match &result {
            Ok(_) => {
                crate::device_capabilities::cache::invalidate_capability_cache_for_device(
                    device_id,
                )
                .await;

                // The name the identity check just read off the driver, not
                // the one registered before the connect: after the bus
                // re-enumerates, that one names the device that used to
                // answer this id.
                let device_name = self
                    .devices
                    .read()
                    .await
                    .get(device_id)
                    .map(|d| d.info.shown_name())
                    .unwrap_or_else(|| info.shown_name());
                self.app_state.publish_equipment_event(
                    EquipmentEvent::Connected {
                        device_type: info.device_type.as_str().to_string(),
                        device_id: device_id.clone(),
                        device_name,
                    },
                    EventSeverity::Info,
                );

                // A client that links later learns the gain, offset and
                // binning from this, not from a poll it may never run.
                if info.device_type == DeviceType::Camera {
                    self.publish_camera_settings(device_id).await;
                    self.publish_unknown_pixel_size_notice(device_id).await;
                }

                // A focuser, wheel or rotator moved outside Skotiq is caught
                // by the backstop poll (`ops::backstop`).
                if policy(info.device_type).backstop_polled {
                    self.ensure_backstop_poll();
                }

                // A mount that moves on its own or loses its position is
                // caught by the motion guard (`motion_guard`).
                if info.device_type == DeviceType::Mount {
                    crate::device_manager::motion_guard::ensure_sampler();
                }

                // Auto-start heartbeat monitoring for the connected device
                let heartbeat_config = policy(info.device_type).heartbeat;
                if let Err(e) = self
                    .start_heartbeat_with_config(device_id, heartbeat_config)
                    .await
                {
                    tracing::warn!("Failed to start heartbeat for {}: {}", device_id, e);
                } else {
                    tracing::info!("Auto-started heartbeat for device {}", device_id);
                }

                // Reconnect-only: re-apply the essential device state the
                // driver drops across a physical reconnect. We deliberately
                // gate on `was_error_before_connect` so a fresh user connect
                // does not silently command cooling / tracking the user did
                // not ask for. Failures here are non-fatal — the reconnect
                // itself succeeded; a re-apply failure is logged + surfaced as
                // a warning so the operator can intervene, but it does not
                // turn a recovered device back into an error.
                if was_error_before_connect {
                    self.reapply_essential_state_after_reconnect(info).await;
                }
            }
            Err(e) => {
                self.app_state.publish_equipment_event(
                    EquipmentEvent::Error {
                        device_type: info.device_type.as_str().to_string(),
                        device_id: device_id.clone(),
                        message: e.clone(),
                    },
                    EventSeverity::Error,
                );
            }
        }

        result
    }

    /// True when this connect failed because the id re-bound to other hardware.
    ///
    /// Used only to stop the self-inflicted disconnect inside
    /// `verify_identity_after_connect` from masquerading as a user cancel; see
    /// the post-dispatch cancel check in `connect_device_internal`.
    fn is_identity_conflict(result: &Result<(), String>) -> bool {
        matches!(result, Err(e) if e.contains(IDENTITY_CONFLICT_MARKER))
    }

    /// True when a connect failed because the vendor SDK no longer enumerates
    /// the device — as opposed to the many ways a device that IS present can
    /// refuse to open (in use, permissions, a driver fault).
    ///
    /// The distinction decides whether the cached discovery list is wrong. A
    /// busy or faulty device is still on the bus and the list is accurate; a
    /// device the SDK cannot enumerate is not, and the list is lying.
    ///
    /// Matched on the message because these strings cross a vendor boundary as
    /// plain `String` (`DriverError::InvalidDevice` carries no code). The
    /// phrases are the ones the vendor modules emit — `zwo.rs` for the first,
    /// and the generic form the shared enumeration helpers use.
    fn is_stale_enumeration_error(message: &str) -> bool {
        const MARKERS: [&str; 2] = [
            "no longer present in the SDK enumeration",
            "not present in the SDK enumeration",
        ];
        MARKERS.iter().any(|m| message.contains(m))
    }

    /// Ask a freshly-connected driver what it is, and refuse the connect if the
    /// answer contradicts what this device id was last observed to be.
    ///
    /// Runs on every connect, including reconnects — a mid-night USB dropout
    /// followed by a re-enumeration is exactly how an id silently re-binds to
    /// the other camera on the bus.
    ///
    /// Outcomes:
    ///
    /// * driver reports nothing identifiable → `Ok`, nothing recorded. We do
    ///   not store an empty baseline, because it would later match anything.
    /// * the caller named the model it expects (see
    ///   [`Self::connect_device_expecting`]) and the driver named a model →
    ///   that comparison decides; the id's baseline describes whatever
    ///   answered it last, which after a re-enumeration is the device that
    ///   moved away.
    /// * no baseline yet → record it, refresh the registered `DeviceInfo` so
    ///   the API stops reporting the id-derived placeholder name, `Ok`.
    /// * baseline agrees → refresh and `Ok`.
    /// * contradicted → tear the driver back down, drop the discovery cache
    ///   (it describes the bus before the change), and `Err`.
    ///
    /// The teardown on conflict is the point: leaving the handle open would
    /// leave a live connection to the wrong sensor that every later command
    /// would happily address. `disconnect_device` also clears `auto_reconnect`,
    /// so the manager stops re-opening the wrong camera in a loop. Finding
    /// where the wanted device went is the caller's: the app looks the
    /// profile's device up by name in a fresh enumeration and connects it at
    /// its new id with the model expected.
    pub(crate) async fn verify_identity_after_connect(
        &self,
        info: &DeviceInfo,
    ) -> Result<(), String> {
        let observed = self.probe_device_identity(info).await;
        if observed.is_empty() {
            tracing::debug!(
                "No identity reported by {} ({:?}); identity check skipped",
                info.id,
                info.driver_type
            );
            return Ok(());
        }

        let previous = self.observed_identities.read().await.get(&info.id).cloned();
        let expected = self
            .expected_models
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .get(&info.id)
            .cloned();

        let conflict = match (&expected, &observed.model) {
            // The caller said which model it wants and the driver named one:
            // that decides it. The id's last observation is not consulted for
            // the model or sensor, because after a re-enumeration it describes
            // the device that moved away.
            (Some(expected), Some(_)) => match observed.conflict_with_expected(expected) {
                // A driver can name itself differently from how discovery
                // labels it (the profile saved discovery's name). Before
                // refusing on the name alone, ask a fresh enumeration what is
                // at this id.
                Some(_) if self.enumeration_names(info, expected).await => {
                    tracing::info!(
                        "{} names itself {:?}; discovery lists it as {}, so it is the expected device",
                        info.id,
                        observed.model,
                        expected
                    );
                    None
                }
                Some(reason) => Some(reason),
                // Two identical bodies trading places: only a serial tells
                // them apart, and only against the same model.
                None => previous
                    .as_ref()
                    .filter(|p| {
                        p.model.as_deref().is_some_and(|m| {
                            crate::device_manager::identity::same_model(m, expected)
                        })
                    })
                    .and_then(|p| match (&observed.serial_number, &p.serial_number) {
                        (Some(now), Some(before)) if now != before => {
                            Some(format!("serial number changed from {} to {}", before, now))
                        }
                        _ => None,
                    }),
            },
            _ => previous.as_ref().and_then(|p| observed.conflict_with(p)),
        };

        if let Some(reason) = conflict {
            let previously = match (&expected, &previous) {
                (Some(expected), _) => format!("the caller expected {}", expected),
                (None, Some(previous)) => format!("previously it was {}", previous.describe()),
                (None, None) => "nothing was expected".to_string(),
            };
            let message = format!(
                "Device id {} {}: {}. \
                     Connected device reports {}; {}. \
                     This id is a position on the bus, not an identity, so it \
                     re-binds when devices are replugged or re-enumerated. \
                     Refusing the connection rather than using the wrong device.",
                info.id,
                IDENTITY_CONFLICT_MARKER,
                reason,
                observed.describe(),
                previously,
            );
            tracing::error!("{}", message);

            // The id answered as a different device, so the enumeration
            // the discovery cache holds is out of date: drop it, so the
            // caller's next look for the device it wanted sees where it
            // went.
            crate::discovery::forget().await;

            if let Err(e) = self.disconnect_device(&info.id).await {
                tracing::warn!(
                    "Failed to release the mismatched device {} after an identity conflict: {}",
                    info.id,
                    e
                );
            }
            return Err(message);
        }

        tracing::info!("Device {} identified as {}", info.id, observed.describe());

        self.observed_identities
            .write()
            .await
            .insert(info.id.clone(), observed.clone());

        // Replace the placeholder identity that `device_info_from_id` derived
        // from the id string with what the driver reported.
        {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(&info.id) {
                observed.apply_to(&mut dev.info);
            }
        }

        Ok(())
    }

    /// Whether a fresh enumeration lists `expected_model` at `info.id`.
    ///
    /// The discovery cache is dropped first: after a re-enumeration it still
    /// describes the bus as it was, which is exactly the question here.
    async fn enumeration_names(&self, info: &DeviceInfo, expected_model: &str) -> bool {
        crate::discovery::forget().await;
        match crate::discovery::discover_devices(info.device_type.clone()).await {
            Ok(devices) => devices.iter().any(|d| {
                d.id == info.id
                    && (crate::device_manager::identity::same_model(&d.name, expected_model)
                        || crate::device_manager::identity::same_model(
                            &d.display_name,
                            expected_model,
                        ))
            }),
            Err(e) => {
                tracing::warn!(
                    "Could not enumerate {} devices to check {}: {}",
                    info.device_type.as_str(),
                    info.id,
                    e
                );
                false
            }
        }
    }

    /// Read identity straight off the connected driver.
    ///
    /// A camera answers with model, serial and sensor geometry; any other
    /// vendor device with model and serial. A transport that gives the
    /// driver nothing to say returns an empty identity, which the caller
    /// treats as "no opinion" rather than as a match.
    pub(crate) async fn probe_device_identity(&self, info: &DeviceInfo) -> DeviceIdentity {
        if let Some(handle) = self.handles.get(&info.id) {
            if let Some(identity) = handle.identity().await {
                return identity;
            }
        }

        if let Some(device) = self.native_devices.read().await.get(&info.id) {
            return Self::identity_from_device(&info.id, device.as_ref());
        }

        if info.driver_type == DriverType::Simulator && info.device_type == DeviceType::Camera {
            return Self::simulated_camera_identity(&info.id).await;
        }

        DeviceIdentity::default()
    }

    /// What a simulated camera says it is: the name and sensor of the body
    /// at the id, which can change when the simulated bus re-enumerates
    /// (the `unplug(reorder)` fault), so the identity check runs against the
    /// simulators the same way it does against a ZWO pair.
    async fn simulated_camera_identity(device_id: &str) -> DeviceIdentity {
        let status = crate::simulator::camera::get_sim_camera_for(device_id)
            .read()
            .await
            .status
            .clone();
        DeviceIdentity {
            model: crate::discovery::simulator_display_name(device_id, DeviceType::Camera),
            serial_number: None,
            sensor: DeviceIdentity::sensor_fingerprint(
                status.sensor_width,
                status.sensor_height,
                status.pixel_size_x,
            ),
        }
    }

    /// A driver-reported model, or `None` when the driver only echoed the id.
    ///
    /// Some vendor wrappers implement `DeviceDriver::name()` by handing back the
    /// device id — `ZwoCamera` did exactly that until the model was cached, and
    /// `PlayerOneCamera` still does. That answer is worthless as identity (it is
    /// a pure function of the id, so it can never contradict itself across a
    /// swap) and actively harmful as a name: recording it would replace the
    /// placeholder `ZWO 1` with the raw `native:zwo:1` in the connected-device
    /// list and stamp an enumeration index into the FITS `INSTRUME` keyword.
    /// Treat it as "the driver did not say".
    fn reported_model(device_id: &str, reported: &str) -> Option<String> {
        let trimmed = reported.trim();
        if trimmed.is_empty() || trimmed.eq_ignore_ascii_case(device_id.trim()) {
            return None;
        }
        Some(trimmed.to_string())
    }

    /// Model + serial from any connected native device.
    pub(crate) fn identity_from_device(
        device_id: &str,
        device: &dyn DeviceDriver,
    ) -> DeviceIdentity {
        DeviceIdentity {
            model: Self::reported_model(device_id, device.name()),
            serial_number: device.serial_number().filter(|s| !s.trim().is_empty()),
            sensor: None,
        }
    }

    /// Model + serial + sensor geometry from any connected camera.
    ///
    /// Geometry is what separates two bodies whose driver-reported names are
    /// identical, which is the normal case behind one ASCOM ProgID.
    pub(crate) fn identity_from_camera(
        device_id: &str,
        camera: &dyn CameraDriver,
    ) -> DeviceIdentity {
        let sensor = camera.get_sensor_info();
        DeviceIdentity {
            model: Self::reported_model(device_id, camera.name()),
            serial_number: camera.serial_number().filter(|s| !s.trim().is_empty()),
            sensor: DeviceIdentity::sensor_fingerprint(
                sensor.width,
                sensor.height,
                sensor.pixel_size_x,
            ),
        }
    }

    /// The fault-injection key prefix for a simulated device, as the
    /// simulator's own gates name it.
    pub(crate) fn sim_fault_prefix(info: &DeviceInfo) -> Option<&'static str> {
        Some(match info.device_type {
            DeviceType::Camera => crate::simulator::camera::sim_camera_fault_prefix(&info.id),
            DeviceType::Mount => "mount",
            DeviceType::Focuser => "focuser",
            DeviceType::FilterWheel => "filterwheel",
            DeviceType::Rotator => "rotator",
            _ => return None,
        })
    }

    /// Connects a simulated device: arms the faults `SKOTIQ_SIM_FAULTS` names,
    /// lets a `<device>.connect` fault refuse or delay the open, and holds the
    /// handle the simulator hands back. Connecting a connected simulator is
    /// `Ok`; an id without the `sim_` prefix and a device type with no
    /// simulator are errors, so neither ever reads as connected.
    pub(crate) async fn connect_simulator(&self, info: &DeviceInfo) -> Result<(), String> {
        if !info.id.starts_with("sim_") {
            return Err(format!(
                "connect_simulator: device id '{}' is not a simulator id (expected 'sim_' prefix)",
                info.id
            ));
        }

        crate::simulator::faults::arm_from_env();
        if let Some(prefix) = Self::sim_fault_prefix(info) {
            crate::simulator::faults::check(&format!("{prefix}.connect")).await?;
        }

        let handle = crate::simulator::driver::connect(info)
            .await
            .ok_or_else(|| {
                format!(
                    "connect_simulator: no simulator implementation for device type {:?} (id '{}')",
                    info.device_type, info.id
                )
            })?;
        self.handles.insert(&info.id, handle);

        tracing::info!(
            "Simulator connected: id={} type={:?}",
            info.id,
            info.device_type
        );
        Ok(())
    }

    pub async fn disconnect_device(&self, device_id: &str) -> Result<(), String> {
        // Stop heartbeat monitoring first to prevent false disconnect events
        let _ = self.stop_heartbeat(device_id).await;
        crate::device_capabilities::cache::invalidate_capability_cache_for_device(device_id).await;

        let device_info = {
            let devices = self.devices.read().await;
            devices
                .get(device_id)
                .map(|d| d.info.clone())
                .ok_or_else(|| format!("Device not found: {}", device_id))?
        };

        self.status_reads.forget(device_id);

        {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(device_id) {
                dev.connection_state = ConnectionState::Disconnected;
                dev.auto_reconnect = false; // Disable auto-reconnect on manual disconnect
            }
        }

        // Trip any in-flight reconnect attempt's cancel token. This
        // must happen AFTER releasing the `devices` write lock above (lock
        // ordering: `devices` then `reconnect_cancel_tokens`) but BEFORE we
        // begin tearing down driver-specific state — otherwise a reconnect
        // currently inside `connect_device_internal` could re-populate the
        // driver maps we are about to drain.
        //
        // We do not block waiting for the reconnect to bail: `connect_device_
        // internal` polls the token at pre- and post-dispatch checkpoints and
        // returns `RECONNECT_CANCELED_MSG`, which the reconnection_loop
        // suppresses. Worst case, the driver dispatch is mid-flight and runs
        // to completion against now-stale maps; its result is then discarded
        // by the post-dispatch cancel check.
        self.trip_reconnect_cancel_token(device_id).await;

        // Clean up device from driver-specific storage based on driver type and device type
        let mut disconnect_errors = Vec::new();
        macro_rules! record_disconnect {
            ($label:expr, $result:expr) => {
                if let Err(e) = $result {
                    let message = format!("{} disconnect failed for {}: {}", $label, device_id, e);
                    tracing::warn!("{}", message);
                    disconnect_errors.push(message);
                }
            };
        }

        if device_info.id == crate::builtin_guider::control::device_id() {
            record_disconnect!(
                "Built-in guider",
                crate::builtin_guider::control::disconnect().await
            );
        }
        // PHD2 has its own out-of-band disconnect path (the PHD2
        // client storage lives outside the per-driver maps below). If a user
        // disconnects PHD2 via the generic `disconnect_device` route, we have
        // to mirror the built-in-guider check above so the PHD2 socket is
        // actually torn down. Without this the PHD2 client was leaked: state
        // was reset but the TCP connection and event listener kept running,
        // so a subsequent reconnect attempted to talk through a stale client.
        if crate::guider::phd2::is_device_id(&device_info.id) {
            if let Err(e) = crate::guider::phd2::disconnect().await {
                // Log loudly so a stuck PHD2 client is never hidden, but
                // continue with the generic cleanup either way: the device is
                // already being released and a PHD2-side error must not block
                // disconnecting the rest of the device record.
                tracing::warn!(
                    "PHD2 disconnect via generic route failed for {}: {}",
                    device_info.id,
                    e
                );
            }
        }
        if let Some(handle) = self.handles.remove(device_id) {
            let label = format!(
                "{} {}",
                protocol_label(device_info.driver_type),
                device_noun(device_info.device_type)
            );
            record_disconnect!(label, handle.disconnect().await);
        } else {
            match device_info.driver_type {
                DriverType::Native => {
                    let mut native_devices = self.native_devices.write().await;
                    if let Some(mut device) = native_devices.remove(device_id) {
                        record_disconnect!("Native device", device.disconnect().await);
                    }
                }
                // Every Alpaca, ASCOM and simulated device is released
                // through its handle above.
                DriverType::Alpaca | DriverType::Ascom | DriverType::Simulator => {}
                // A device type with no handle (a guider) is released on its
                // server's shared connection.
                DriverType::Indi => {
                    record_disconnect!("INDI device", self.release_indi_device(device_id).await);
                }
            }
        }

        self.app_state.publish_equipment_event(
            EquipmentEvent::Disconnected {
                device_type: device_info.device_type.as_str().to_string(),
                device_id: device_id.to_string(),
            },
            EventSeverity::Info,
        );

        if !disconnect_errors.is_empty() {
            return Err(format!(
                "Disconnected {} from Skotiq state, but driver cleanup reported: {}",
                device_id,
                disconnect_errors.join("; ")
            ));
        }

        Ok(())
    }

    /// Enable or disable auto-reconnect for a device
    pub async fn set_auto_reconnect(&self, device_id: &str, enabled: bool) {
        let mut devices = self.devices.write().await;
        if let Some(dev) = devices.get_mut(device_id) {
            dev.auto_reconnect = enabled;
        }
    }

    /// Heartbeat threshold reached: mark the device unhealthy.
    ///
    /// Real reconnection is handled exclusively by `reconnection_loop` when
    /// `auto_reconnect` is enabled (FB-); the heartbeat task must not sleep
    /// and pretend to reconnect.
    pub(crate) async fn handle_heartbeat_lost(
        &self,
        device_id: &str,
        heartbeat_auto_reconnect: bool,
        consecutive_failures: u32,
        error_msg: &str,
    ) -> Option<DeviceInfo> {
        let info = {
            let mut devices = self.devices.write().await;
            let dev = devices.get_mut(device_id)?;
            dev.connection_state = ConnectionState::Error;
            dev.last_error = Some(format!(
                "Unresponsive after {} heartbeat failures: {}",
                consecutive_failures, error_msg
            ));
            if heartbeat_auto_reconnect {
                dev.auto_reconnect = true;
            }
            dev.info.clone()
        };

        Some(info)
    }

    /// Re-apply the essential device state that a physical reconnect drops.
    ///
    /// Drivers come back from a USB / serial reconnect in their power-on
    /// defaults: a camera's cooler is off and its setpoint cleared, a mount is
    /// parked / not tracking. After an unplanned reconnect we replay the last
    /// state the user / sequencer commanded (recorded in `camera_set_cooler` /
    /// `mount_set_tracking`) so an unattended run does not silently warm the
    /// sensor or leave the mount stationary while the sequence "resumes".
    ///
    /// Only camera cooling and mount tracking are replayed — these are the two
    /// pieces of state that (a) are commanded ahead of time and persist, and
    /// (b) materially break the session if lost. Position / filter / focus are
    /// re-established by the recovery loop and the next instruction's own
    /// centering / filter-change steps, so we do not duplicate them here.
    ///
    /// Errors are non-fatal: the reconnect already succeeded, so a replay
    /// failure is surfaced as a `Warning` event for operator visibility but
    /// does NOT flip the device back into an error state.
    async fn reapply_essential_state_after_reconnect(&self, info: &DeviceInfo) {
        let device_id = &info.id;

        let (desired_cooler, desired_tracking) = {
            let devices = self.devices.read().await;
            match devices.get(device_id) {
                Some(dev) => (dev.desired_cooler, dev.desired_tracking),
                None => return,
            }
        };

        match info.device_type {
            DeviceType::Camera => {
                if let Some((enabled, target_temp)) = desired_cooler {
                    tracing::info!(
                        "Reconnect: re-applying camera {} cooler (enabled={}, target={:?})",
                        device_id,
                        enabled,
                        target_temp
                    );
                    if let Err(e) = self
                        .camera_set_cooler(device_id, enabled, target_temp)
                        .await
                    {
                        tracing::warn!(
                            "Reconnect: failed to re-apply camera {} cooler: {}",
                            device_id,
                            e
                        );
                        self.app_state.publish_equipment_event(
                            EquipmentEvent::Error {
                                device_type: info.device_type.as_str().to_string(),
                                device_id: device_id.clone(),
                                message: format!(
                                    "Reconnected but could not restore cooling setpoint: {}",
                                    e
                                ),
                            },
                            EventSeverity::Warning,
                        );
                    }
                }
            }
            DeviceType::Mount => {
                if let Some(enabled) = desired_tracking {
                    tracing::info!(
                        "Reconnect: re-applying mount {} tracking={}",
                        device_id,
                        enabled
                    );
                    if let Err(e) = self.mount_set_tracking(device_id, enabled).await {
                        tracing::warn!(
                            "Reconnect: failed to re-apply mount {} tracking: {}",
                            device_id,
                            e
                        );
                        self.app_state.publish_equipment_event(
                            EquipmentEvent::Error {
                                device_type: info.device_type.as_str().to_string(),
                                device_id: device_id.clone(),
                                message: format!(
                                    "Reconnected but could not restore mount tracking: {}",
                                    e
                                ),
                            },
                            EventSeverity::Warning,
                        );
                    }
                }
            }
            _ => {}
        }
    }

    pub async fn unregister_device(&self, device_id: &str) {
        let mut devices = self.devices.write().await;
        devices.remove(device_id);
    }
}

#[cfg(test)]
mod stale_enumeration_tests {
    use super::*;

    /// The message the live rig produced on 2026-08-09, verbatim. The list went
    /// on offering `native:zwo:0` for the full 60 s discovery TTL after the SDK
    /// stopped enumerating it, so every retry failed against a list nobody had
    /// refreshed.
    #[test]
    fn recognises_the_live_rig_message() {
        assert!(DeviceManager::is_stale_enumeration_error(
            "Failed to connect to native:zwo:0 via native bridge: \
             SkotiqError.connectionFailed(deviceId: native:zwo:0, reason: \
             Invalid device: ZWO camera ID 0 is no longer present in the SDK \
             enumeration)"
        ));
    }

    /// A device that IS on the bus and merely refuses to open must not
    /// invalidate the cache: the list is accurate and dropping it would make
    /// every busy-camera retry re-run a full multi-driver scan.
    #[test]
    fn leaves_present_but_unopenable_devices_alone() {
        for message in [
            "Device disconnected",
            "ASIOpenCamera failed: rc=5",
            "Camera is already in use by another application",
            "Access denied opening ASCOM.ASICamera2.Camera",
            "Timed out waiting for the driver to connect",
        ] {
            assert!(
                !DeviceManager::is_stale_enumeration_error(message),
                "{message:?} is not an enumeration failure"
            );
        }
    }
}
