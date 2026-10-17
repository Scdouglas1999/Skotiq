//! Device connection lifecycle: register, connect, disconnect, auto-reconnect.
//!
//! Methods in this module are additional impl blocks on `DeviceManager` and
//! contain the cross-driver lifecycle logic. Driver-specific `connect_*`
//! helpers continue to live in `crate::dispatch::{ascom,alpaca,indi,native}`
//! (also split-impl-block) and are invoked from `connect_device_internal`
//! below. No behavior or signature has changed relative to the previous
//! monolithic `devices.rs`.

use crate::device::*;
use crate::device_manager::identity::{DeviceIdentity, IDENTITY_CONFLICT_MARKER};
use crate::device_manager::{DeviceManager, ManagedDevice};
use crate::event::*;
use std::time::Duration;
use tokio::sync::watch;
use tokio::time::interval;
// `NativeDevice` also backs the ASCOM wrapper guards on Windows; the identity
// probe below needs it (and `NativeCamera`) on every platform.
use skotiq_native::traits::{NativeCamera, NativeDevice};

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
    /// sender on miss — it only borrows an existing one. Used by
    /// `connect_device_internal` to consult an in-flight reconnect's token
    /// without accidentally arming a user-initiated connect path.
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

            // Check if we should stop
            if *self.stop_reconnect.read().await {
                break;
            }

            if !self.reconnect_config.enabled {
                continue;
            }

            // Find devices that need reconnection
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

                // Attempt reconnection. `connect_device_internal` re-checks the
                // cancel token at additional checkpoints inside the call.
                match self.connect_device_internal(&device.info).await {
                    Err(e) if e == RECONNECT_CANCELED_MSG => {
                        // Reconnect was aborted by a concurrent disconnect.
                        // Do NOT increment the attempt counter or emit a
                        // "reconnection attempt failed" event — that would be
                        // misleading because the user themselves stopped it.
                        tracing::info!(
                            "Reconnect for {} canceled mid-attempt (manual disconnect)",
                            device_id
                        );
                        continue;
                    }
                    Err(e) => {
                        tracing::warn!("Reconnection failed for {}: {}", device_id, e);

                        // Update attempt counter
                        let mut devices = self.devices.write().await;
                        if let Some(dev) = devices.get_mut(&device_id) {
                            dev.reconnect_attempts += 1;
                            dev.last_error = Some(e.clone());

                            // Publish reconnection failed event
                            self.app_state.publish_equipment_event(
                                EquipmentEvent::Error {
                                    device_type: dev.info.device_type.as_str().to_string(),
                                    device_id: device_id.clone(),
                                    message: format!(
                                        "Reconnection attempt {} failed: {}",
                                        dev.reconnect_attempts, e
                                    ),
                                },
                                EventSeverity::Warning,
                            );
                        }
                    }
                    Ok(()) => {
                        tracing::info!("Reconnection successful for {}", device_id);

                        // Reset attempt counter on success
                        let mut devices = self.devices.write().await;
                        if let Some(dev) = devices.get_mut(&device_id) {
                            dev.reconnect_attempts = 0;
                            dev.last_error = None;
                        }
                    }
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
    /// over its own TCP socket, opened by `api_phd2_connect`, not by any driver
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
                heartbeat_active: false,
                api_version: None,
                desired_cooler: None,
                desired_tracking: None,
            },
        );
    }

    /// Check if a device is registered
    pub async fn is_device_registered(&self, device_id: &str) -> bool {
        let devices = self.devices.read().await;
        devices.contains_key(device_id)
    }

    /// Get the display name for a registered device, if it exists.
    pub async fn get_device_display_name(&self, device_id: &str) -> Option<String> {
        let devices = self.devices.read().await;
        devices.get(device_id).map(|d| d.info.display_name.clone())
    }

    /// Connect to a device
    pub async fn connect_device(&self, device_id: &str) -> Result<(), String> {
        let device_info = {
            let devices = self.devices.read().await;
            devices
                .get(device_id)
                .map(|d| d.info.clone())
                .ok_or_else(|| format!("Device not found: {}", device_id))?
        };

        self.connect_device_internal(&device_info).await
    }

    /// Internal connection logic
    pub(crate) async fn connect_device_internal(&self, info: &DeviceInfo) -> Result<(), String> {
        let device_id = &info.id;

        // Subscribe to the device's reconnect cancel token (if any). Only the
        // reconnection loop installs these, so a user-initiated `connect_device`
        // call usually sees `None` here and the cancel checks below are no-ops.
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
        // (heartbeat-lost or report_error path), and on success we must
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

        // Publish connecting event
        self.app_state.publish_equipment_event(
            EquipmentEvent::Connecting {
                device_type: info.device_type.as_str().to_string(),
                device_id: device_id.clone(),
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

        // Update state based on result
        {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(device_id) {
                match &result {
                    Ok(_) => {
                        dev.connection_state = ConnectionState::Connected;
                        dev.last_error = None;
                        dev.reconnect_attempts = 0;
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
                crate::api::api_invalidate_discovery_cache().await;
            }
        }

        // Publish result event
        match &result {
            Ok(_) => {
                crate::device_capabilities::invalidate_capability_cache_for_device(device_id).await;

                self.app_state.publish_equipment_event(
                    EquipmentEvent::Connected {
                        device_type: info.device_type.as_str().to_string(),
                        device_id: device_id.clone(),
                    },
                    EventSeverity::Info,
                );

                // Also register in app state
                self.app_state
                    .register_device(info.clone(), ConnectionState::Connected)
                    .await;

                // Auto-start heartbeat monitoring for the connected device
                let heartbeat_config = Self::get_heartbeat_config(&info.device_type);
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
    /// plain `String` (`NativeError::InvalidDevice` carries no code). The
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
    /// * no baseline yet → record it, refresh the registered `DeviceInfo` so
    ///   the API stops reporting the id-derived placeholder name, `Ok`.
    /// * baseline agrees → refresh and `Ok`.
    /// * baseline contradicted → tear the driver back down and `Err`.
    ///
    /// The teardown on conflict is the point: leaving the handle open would
    /// leave a live connection to the wrong sensor that every later command
    /// would happily address. `disconnect_device` also clears `auto_reconnect`,
    /// so the manager stops re-opening the wrong camera in a loop. Recovering
    /// from a genuine swap needs a human, and stopping is the safe answer for
    /// an unattended run.
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

        if let Some(previous) = previous {
            if let Some(reason) = observed.conflict_with(&previous) {
                let message = format!(
                    "Device id {} {}: {}. \
                     Connected device reports {}; previously it was {}. \
                     This id is a position on the bus, not an identity, so it \
                     re-binds when devices are replugged or re-enumerated. \
                     Refusing the connection rather than using the wrong device.",
                    info.id,
                    IDENTITY_CONFLICT_MARKER,
                    reason,
                    observed.describe(),
                    previous.describe(),
                );
                tracing::error!("{}", message);

                if let Err(e) = self.disconnect_device(&info.id).await {
                    tracing::warn!(
                        "Failed to release the mismatched device {} after an identity conflict: {}",
                        info.id,
                        e
                    );
                }
                return Err(message);
            }
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

    /// Read identity straight off the connected driver.
    ///
    /// Cameras are the case that matters and the case that can answer: both the
    /// vendor-SDK cameras and the ASCOM wrapper implement `NativeCamera`, so
    /// model, serial and sensor geometry come from one code path. Non-camera
    /// native devices contribute model and serial. Transports with no
    /// post-connect identity surface return an empty identity, which the caller
    /// treats as "no opinion" rather than as a match.
    pub(crate) async fn probe_device_identity(&self, info: &DeviceInfo) -> DeviceIdentity {
        if let Some(camera) = self.native_cameras.read().await.get(&info.id) {
            return Self::identity_from_camera(&info.id, camera.as_ref());
        }

        if let Some(identity) = self.probe_ascom_camera_identity(&info.id).await {
            return identity;
        }

        if let Some(device) = self.native_devices.read().await.get(&info.id) {
            return Self::identity_from_device(&info.id, device.as_ref());
        }

        DeviceIdentity::default()
    }

    /// Identity of a connected ASCOM camera, when this platform has ASCOM.
    ///
    /// **Geometry only, deliberately.** `AscomCameraWrapper::name()` returns the
    /// ProgID it was constructed with, not anything the driver said, so feeding
    /// it in as `model` would compare a constant against itself and would also
    /// overwrite the displayed name with `ASCOM.ASICamera2.Camera`. The sensor
    /// cache, by contrast, is refreshed from the live driver during
    /// `AscomCameraWrapper::connect` (which calls `get_capabilities` and fails
    /// the connect if the driver cannot answer), so the geometry read here is
    /// genuinely the connected camera's — and geometry is exactly what
    /// distinguishes two bodies sharing one ProgID.
    ///
    /// Getting the real model over ASCOM needs a `Name` read *after*
    /// `Connected = true`. Measured on the reference rig, an unconnected
    /// `ASCOM.ASICamera2.Camera` answers `Name = "ASI Camera (1)"` and an empty
    /// `SensorName`, so the existing `skotiq_ascom::probe_device_name`
    /// helper — which reads `Name` without connecting — cannot supply it.
    #[cfg(windows)]
    async fn probe_ascom_camera_identity(&self, device_id: &str) -> Option<DeviceIdentity> {
        let cameras = self.ascom_cameras.read().await;
        let camera = cameras.get(device_id)?.clone();
        drop(cameras);
        let sensor = camera.read().await.get_sensor_info();
        Some(DeviceIdentity {
            model: None,
            serial_number: None,
            sensor: DeviceIdentity::sensor_fingerprint(
                sensor.width,
                sensor.height,
                sensor.pixel_size_x,
            ),
        })
    }

    #[cfg(not(windows))]
    async fn probe_ascom_camera_identity(&self, _device_id: &str) -> Option<DeviceIdentity> {
        None
    }

    /// A driver-reported model, or `None` when the driver only echoed the id.
    ///
    /// Some vendor wrappers implement `NativeDevice::name()` by handing back the
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
    fn identity_from_device(device_id: &str, device: &dyn NativeDevice) -> DeviceIdentity {
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
    fn identity_from_camera(device_id: &str, camera: &dyn NativeCamera) -> DeviceIdentity {
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

    /// Connect to a simulator device.
    ///
    /// Sets the matching `simulation.rs` singleton's `connected = true` so
    /// status accessors, heartbeat checks, and Dart-side `isConnected`
    /// observers all see a consistent "real" connection state for the
    /// simulator.
    ///
    /// # Behavior
    ///
    /// * Validates the device id has the `sim_` prefix (the established
    ///   convention used by every `device_id.starts_with("sim_")` branch in
    ///   `bridge::api::devices`). An unrecognized id returns `Err`: a silent
    ///   fallback would let a typoed sim id appear "connected" with no
    ///   backing state.
    /// * Dispatches by `DeviceInfo.device_type`. Device types without a
    ///   `simulation.rs` singleton (Guider) return
    ///   `Err` so we never claim "connected"
    ///   for a simulator backend that doesn't exist. The existing
    ///   ops-level `DriverType::Simulator => Ok(...)` short-circuits in
    ///   `device_manager/ops/*` are a separate, known inconsistency.
    /// * Idempotent: if the singleton is already `connected`, returns `Ok`
    ///   so the user can re-trigger "Connect" from the UI without spurious
    ///   errors.
    pub(crate) async fn connect_simulator(&self, info: &DeviceInfo) -> Result<(), String> {
        if !info.id.starts_with("sim_") {
            return Err(format!(
                "connect_simulator: device id '{}' is not a simulator id (expected 'sim_' prefix)",
                info.id
            ));
        }

        use crate::api::devices::simulation::{
            get_sim_camera, get_sim_cover_calibrator, get_sim_dome, get_sim_filterwheel,
            get_sim_focuser, get_sim_mount, get_sim_rotator, get_sim_safety_monitor,
            get_sim_switch, get_sim_weather,
        };

        // Arm any faults named by `SKOTIQ_SIM_FAULTS` before the device is
        // usable, so a drive can inject hardware misbehaviour into a release
        // build without a rebuild. Idempotent — re-arming the same spec on a
        // second connect just resets its counters.
        crate::device_manager::ops::sim_faults::arm_from_env();

        match info.device_type {
            DeviceType::Camera => {
                let mut cam = get_sim_camera().write().await;
                cam.status.connected = true;
            }
            DeviceType::Mount => {
                let mut mount = get_sim_mount().write().await;
                mount.status.connected = true;
            }
            DeviceType::Focuser => {
                let mut focuser = get_sim_focuser().write().await;
                focuser.status.connected = true;
            }
            DeviceType::FilterWheel => {
                let mut fw = get_sim_filterwheel().write().await;
                fw.status.connected = true;
            }
            DeviceType::Rotator => {
                let mut rot = get_sim_rotator().write().await;
                rot.status.connected = true;
            }
            DeviceType::Dome => {
                get_sim_dome().write().await.status.connected = true;
            }
            DeviceType::Weather => {
                get_sim_weather().write().await.connected = true;
            }
            DeviceType::SafetyMonitor => {
                get_sim_safety_monitor().write().await.status.connected = true;
            }
            DeviceType::Switch => {
                get_sim_switch().write().await.connected = true;
            }
            DeviceType::CoverCalibrator => {
                get_sim_cover_calibrator().write().await.connected = true;
            }
            other => {
                return Err(format!(
                    "connect_simulator: no simulator implementation for device type {:?} (id '{}')",
                    other, info.id
                ));
            }
        }

        tracing::info!(
            "Simulator connected: id={} type={:?}",
            info.id,
            info.device_type
        );
        Ok(())
    }

    /// Disconnect a simulator device.
    ///
    /// Mirrors `connect_simulator`: sets the matching singleton's
    /// `connected = false` so the heartbeat loop and any other consumer of
    /// the singleton state agree that the device is no longer connected.
    /// Idempotent — disconnecting an already-disconnected simulator returns
    /// `Ok`.
    ///
    /// Unrecognized device types return `Err` (consistent with
    /// `connect_simulator`): a silent no-op would hide bugs where the user
    /// thinks a disconnect happened but no singleton was actually touched.
    pub(crate) async fn disconnect_simulator(&self, info: &DeviceInfo) -> Result<(), String> {
        if !info.id.starts_with("sim_") {
            return Err(format!(
                "disconnect_simulator: device id '{}' is not a simulator id (expected 'sim_' prefix)",
                info.id
            ));
        }

        use crate::api::devices::simulation::{
            get_sim_camera, get_sim_cover_calibrator, get_sim_dome, get_sim_filterwheel,
            get_sim_focuser, get_sim_mount, get_sim_rotator, get_sim_safety_monitor,
            get_sim_switch, get_sim_weather,
        };

        match info.device_type {
            DeviceType::Camera => {
                let mut cam = get_sim_camera().write().await;
                cam.status.connected = false;
            }
            DeviceType::Mount => {
                let mut mount = get_sim_mount().write().await;
                mount.status.connected = false;
            }
            DeviceType::Focuser => {
                let mut focuser = get_sim_focuser().write().await;
                focuser.status.connected = false;
            }
            DeviceType::FilterWheel => {
                let mut fw = get_sim_filterwheel().write().await;
                fw.status.connected = false;
            }
            DeviceType::Rotator => {
                let mut rot = get_sim_rotator().write().await;
                rot.status.connected = false;
            }
            DeviceType::Dome => {
                get_sim_dome().write().await.status.connected = false;
            }
            DeviceType::Weather => {
                get_sim_weather().write().await.connected = false;
            }
            DeviceType::SafetyMonitor => {
                get_sim_safety_monitor().write().await.status.connected = false;
            }
            DeviceType::Switch => {
                get_sim_switch().write().await.connected = false;
            }
            DeviceType::CoverCalibrator => {
                get_sim_cover_calibrator().write().await.connected = false;
            }
            other => {
                return Err(format!(
                    "disconnect_simulator: no simulator implementation for device type {:?} (id '{}')",
                    other, info.id
                ));
            }
        }

        tracing::info!(
            "Simulator disconnected: id={} type={:?}",
            info.id,
            info.device_type
        );
        Ok(())
    }

    /// Disconnect a device
    pub async fn disconnect_device(&self, device_id: &str) -> Result<(), String> {
        // Stop heartbeat monitoring first to prevent false disconnect events
        let _ = self.stop_heartbeat(device_id).await;
        crate::device_capabilities::invalidate_capability_cache_for_device(device_id).await;

        let device_info = {
            let devices = self.devices.read().await;
            devices
                .get(device_id)
                .map(|d| d.info.clone())
                .ok_or_else(|| format!("Device not found: {}", device_id))?
        };

        // Update state
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

        if device_info.id == crate::builtin_guider::device_id() {
            record_disconnect!("Built-in guider", crate::builtin_guider::disconnect().await);
        }
        // PHD2 has its own out-of-band disconnect path (the PHD2
        // client storage lives outside the per-driver maps below). If a user
        // disconnects PHD2 via the generic `disconnect_device` route, we have
        // to mirror the built-in-guider check above so the PHD2 socket is
        // actually torn down. Without this the PHD2 client was leaked: state
        // was reset but the TCP connection and event listener kept running,
        // so a subsequent reconnect attempted to talk through a stale client.
        if crate::api::connection::is_phd2_device_id(&device_info.id) {
            if let Err(e) = crate::api::phd2::api_phd2_disconnect().await {
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
        match device_info.driver_type {
            DriverType::Native => {
                // Remove from generic native_devices map
                let mut native_devices = self.native_devices.write().await;
                if let Some(mut device) = native_devices.remove(device_id) {
                    record_disconnect!("Native device", device.disconnect().await);
                }

                // Also remove from typed native storage maps
                match device_info.device_type {
                    DeviceType::Camera => {
                        let mut cameras = self.native_cameras.write().await;
                        if let Some(mut camera) = cameras.remove(device_id) {
                            record_disconnect!("Native camera", camera.disconnect().await);
                        }
                    }
                    DeviceType::Mount => {
                        let mut mounts = self.native_mounts.write().await;
                        if let Some(mut mount) = mounts.remove(device_id) {
                            record_disconnect!("Native mount", mount.disconnect().await);
                        }
                    }
                    DeviceType::Focuser => {
                        let mut focusers = self.native_focusers.write().await;
                        if let Some(mut focuser) = focusers.remove(device_id) {
                            record_disconnect!("Native focuser", focuser.disconnect().await);
                        }
                    }
                    DeviceType::FilterWheel => {
                        let mut fws = self.native_filter_wheels.write().await;
                        if let Some(mut fw) = fws.remove(device_id) {
                            record_disconnect!("Native filter wheel", fw.disconnect().await);
                        }
                    }
                    // Rotator, dome, weather, safety monitor, switch and
                    // cover calibrator have no native-SDK driver: the generic
                    // `native_devices` removal above is the whole cleanup.
                    DeviceType::Rotator
                    | DeviceType::Dome
                    | DeviceType::Weather
                    | DeviceType::SafetyMonitor
                    | DeviceType::Switch
                    | DeviceType::CoverCalibrator
                    | DeviceType::Guider => {}
                }
            }
            DriverType::Alpaca => {
                // Remove from Alpaca storage based on device type
                match device_info.device_type {
                    DeviceType::Camera => {
                        let mut cameras = self.alpaca_cameras.write().await;
                        if let Some(camera) = cameras.remove(device_id) {
                            record_disconnect!("Alpaca camera", camera.disconnect().await);
                        }
                    }
                    DeviceType::Mount => {
                        let mut mounts = self.alpaca_mounts.write().await;
                        if let Some(mount) = mounts.remove(device_id) {
                            record_disconnect!("Alpaca mount", mount.disconnect().await);
                        }
                    }
                    DeviceType::Focuser => {
                        let mut focusers = self.alpaca_focusers.write().await;
                        if let Some(focuser) = focusers.remove(device_id) {
                            record_disconnect!("Alpaca focuser", focuser.disconnect().await);
                        }
                    }
                    DeviceType::FilterWheel => {
                        let mut fws = self.alpaca_filter_wheels.write().await;
                        if let Some(fw) = fws.remove(device_id) {
                            record_disconnect!("Alpaca filter wheel", fw.disconnect().await);
                        }
                    }
                    DeviceType::Rotator => {
                        let mut rotators = self.alpaca_rotators.write().await;
                        if let Some(rotator) = rotators.remove(device_id) {
                            record_disconnect!("Alpaca rotator", rotator.disconnect().await);
                        }
                    }
                    DeviceType::Dome => {
                        let mut domes = self.alpaca_domes.write().await;
                        if let Some(dome) = domes.remove(device_id) {
                            record_disconnect!("Alpaca dome", dome.disconnect().await);
                        }
                    }
                    DeviceType::Weather => {
                        let mut weather = self.alpaca_weather.write().await;
                        if let Some(w) = weather.remove(device_id) {
                            record_disconnect!("Alpaca weather", w.disconnect().await);
                        }
                    }
                    DeviceType::SafetyMonitor => {
                        let mut safety = self.alpaca_safety_monitors.write().await;
                        if let Some(s) = safety.remove(device_id) {
                            record_disconnect!("Alpaca safety monitor", s.disconnect().await);
                        }
                    }
                    DeviceType::Switch => {
                        let mut switches = self.alpaca_switches.write().await;
                        if let Some(sw) = switches.remove(device_id) {
                            record_disconnect!("Alpaca switch", sw.disconnect().await);
                        }
                    }
                    DeviceType::CoverCalibrator => {
                        let mut covers = self.alpaca_cover_calibrators.write().await;
                        if let Some(cover) = covers.remove(device_id) {
                            record_disconnect!("Alpaca cover calibrator", cover.disconnect().await);
                        }
                    }
                    DeviceType::Guider => {} // Alpaca guider devices are not currently managed here
                }
            }
            #[cfg(windows)]
            DriverType::Ascom => {
                // Remove from ASCOM storage based on device type
                match device_info.device_type {
                    DeviceType::Camera => {
                        let mut cameras = self.ascom_cameras.write().await;
                        if let Some(camera) = cameras.remove(device_id) {
                            let mut cam = camera.write().await;
                            record_disconnect!("ASCOM camera", cam.disconnect().await);
                        }
                    }
                    DeviceType::Mount => {
                        let mut mounts = self.ascom_mounts.write().await;
                        if let Some(mount) = mounts.remove(device_id) {
                            let mut m = mount.write().await;
                            record_disconnect!("ASCOM mount", m.disconnect().await);
                        }
                    }
                    DeviceType::Focuser => {
                        let mut focusers = self.ascom_focusers.write().await;
                        if let Some(focuser) = focusers.remove(device_id) {
                            let mut f = focuser.write().await;
                            record_disconnect!("ASCOM focuser", f.disconnect().await);
                        }
                    }
                    DeviceType::FilterWheel => {
                        let mut fws = self.ascom_filter_wheels.write().await;
                        if let Some(fw) = fws.remove(device_id) {
                            let mut f = fw.write().await;
                            record_disconnect!("ASCOM filter wheel", f.disconnect().await);
                        }
                    }
                    DeviceType::Rotator => {
                        let mut rotators = self.ascom_rotators.write().await;
                        if let Some(rotator) = rotators.remove(device_id) {
                            let mut r = rotator.write().await;
                            record_disconnect!("ASCOM rotator", r.disconnect().await);
                        }
                    }
                    DeviceType::Dome => {
                        let mut domes = self.ascom_domes.write().await;
                        if let Some(dome) = domes.remove(device_id) {
                            let mut d = dome.write().await;
                            record_disconnect!("ASCOM dome", d.disconnect().await);
                        }
                    }
                    DeviceType::Weather => {
                        let mut weather = self.ascom_weather.write().await;
                        if let Some(device) = weather.remove(device_id) {
                            let mut w = device.write().await;
                            record_disconnect!("ASCOM weather", w.disconnect().await);
                        }
                    }
                    DeviceType::SafetyMonitor => {
                        let mut safety_monitors = self.ascom_safety_monitors.write().await;
                        if let Some(monitor) = safety_monitors.remove(device_id) {
                            let mut sm = monitor.write().await;
                            record_disconnect!("ASCOM safety monitor", sm.disconnect().await);
                        }
                    }
                    DeviceType::Switch => {
                        let mut switches = self.ascom_switches.write().await;
                        if let Some(sw) = switches.remove(device_id) {
                            let mut s = sw.write().await;
                            record_disconnect!("ASCOM switch", s.disconnect().await);
                        }
                    }
                    DeviceType::CoverCalibrator => {
                        let mut covers = self.ascom_cover_calibrators.write().await;
                        if let Some(cover) = covers.remove(device_id) {
                            let mut c = cover.write().await;
                            record_disconnect!("ASCOM cover calibrator", c.disconnect().await);
                        }
                    }
                    _ => {}
                }
            }
            #[cfg(not(windows))]
            DriverType::Ascom => {
                // ASCOM not available on non-Windows platforms
            }
            DriverType::Indi => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;
                let server_key = format!("{host}:{port}");

                let client = {
                    let clients = self.indi_clients.read().await;
                    clients.get(&server_key).cloned()
                };

                let Some(client) = client else {
                    return Err(format!("INDI client not connected for {}", server_key));
                };

                let mut locked_client = client.write().await;
                locked_client
                    .disconnect_device(&device_name)
                    .await
                    .map_err(|e| {
                        format!(
                            "Failed to disconnect INDI device {} via {}: {}",
                            device_name, server_key, e
                        )
                    })?;

                // The command has only been written at this point. Wait for
                // the driver's CONNECTION readback before allowing another
                // backend to claim the same hardware; otherwise its connect
                // can be undone milliseconds later by this pending disconnect.
                let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
                while locked_client.is_device_connected(&device_name).await {
                    if tokio::time::Instant::now() >= deadline {
                        return Err(format!(
                            "Timed out waiting for INDI device {} to confirm disconnection",
                            device_name
                        ));
                    }
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
            }
            DriverType::Simulator => {
                // Flip the matching `simulation.rs` singleton's `connected`
                // bit back to false so the heartbeat loop and any other
                // observer agrees the simulator is offline. Errors here are
                // logged but do not block the rest of disconnect cleanup —
                // the user has already asked to release the device, and the
                // managed-device state is being torn down regardless.
                if let Err(e) = self.disconnect_simulator(&device_info).await {
                    tracing::warn!("disconnect_simulator failed for {}: {}", device_info.id, e);
                }
            }
        }

        // Publish event
        self.app_state.publish_equipment_event(
            EquipmentEvent::Disconnected {
                device_type: device_info.device_type.as_str().to_string(),
                device_id: device_id.to_string(),
            },
            EventSeverity::Info,
        );

        // Update app state
        self.app_state
            .remove_device(device_info.device_type, device_id)
            .await;

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

    /// Report a connection error (triggers auto-reconnect if enabled)
    pub async fn report_error(&self, device_id: &str, error: String) {
        crate::device_capabilities::invalidate_capability_cache_for_device(device_id).await;

        let device_type = {
            let mut devices = self.devices.write().await;
            if let Some(dev) = devices.get_mut(device_id) {
                dev.connection_state = ConnectionState::Error;
                dev.last_error = Some(error.clone());
                dev.info.device_type
            } else {
                return;
            }
        };

        self.app_state.remove_device(device_type, device_id).await;

        self.app_state.publish_equipment_event(
            EquipmentEvent::Error {
                device_type: device_type.as_str().to_string(),
                device_id: device_id.to_string(),
                message: error,
            },
            EventSeverity::Error,
        );
    }

    /// Heartbeat threshold reached: mark the device unhealthy and mirror registry state.
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

        self.app_state
            .remove_device(info.device_type, device_id)
            .await;

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

    /// Stop the reconnection background task
    pub async fn shutdown(&self) {
        *self.stop_reconnect.write().await = true;
    }

    /// Unregister a device
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
