//! State-change events for device commands.
//!
//! Every command that changes what a device is doing (a filter move, a focuser
//! move, a gain change, a park) publishes its event here, inside the
//! `DeviceManager` op itself. The host GUI, the embedded API that slaves,
//! phones and scripts use, the sequencer and the polar-alignment routine all
//! reach the hardware through these ops, so the event goes out once whoever
//! asked. Before this, only the sequencer's `UnifiedDeviceOps` published, so a
//! slave that moved the wheel through the API left the host's UI showing the
//! old filter.
//!
//! The events are the existing [`EquipmentEvent`] variants the Dart consumers
//! already parse (`event_handling.dart` on the host, `equipment_mirror.dart`
//! on slaves). Settings that have no variant of their own ride
//! [`EquipmentEvent::PropertyChanged`] with one of the property names below,
//! which carries the device id and type.

use crate::device::{DeviceType, DriverType};
use crate::device_manager::DeviceManager;
use crate::event::{EquipmentEvent, EventSeverity};
use crate::state::SharedAppState;

/// `PropertyChanged.property` names for settings with no event of their own.
/// The Dart consumers match on these strings.
pub(crate) mod property {
    // Gain, offset and binning ride `CameraSettingsChanged`, which carries all
    // three; these name them only when the camera's status cannot be read
    // back after the change.
    pub const GAIN: &str = "Gain";
    pub const OFFSET: &str = "Offset";
    /// Value `"<x>x<y>"`, for example `"2x2"`.
    pub const BINNING: &str = "Binning";
    pub const READOUT_MODE: &str = "ReadoutMode";
    /// Value is a JSON array of the slot names.
    pub const FILTER_NAMES: &str = "FilterNames";
    /// Rotator sky angle after a sync, in degrees.
    pub const ROTATOR_POSITION: &str = "Position";
    pub const ROTATOR_REVERSE: &str = "Reverse";
    /// Value `"<ra hours> <dec degrees>"`, the J2000 position synced to.
    pub const MOUNT_SYNCED: &str = "Synced";
    /// Value `"<altitude> <azimuth>"` in degrees: an alt/az slew started.
    pub const MOUNT_SLEW_ALT_AZ: &str = "SlewToAltAz";
    /// Value `""`: the slew was aborted.
    pub const MOUNT_ABORT: &str = "AbortSlew";
    /// Value `"open"`, `"close"` or `"halt"`: the cover command accepted.
    pub const COVER: &str = "Cover";
    /// Value `"on <brightness>"` or `"off"`.
    pub const CALIBRATOR: &str = "Calibrator";
    /// Value `"<switch index> <true|false>"`.
    pub const SWITCH_STATE: &str = "SwitchState";
    /// Value `"<switch index> <value>"`.
    pub const SWITCH_VALUE: &str = "SwitchValue";
    /// Value `"open"` or `"close"`.
    pub const DOME_SHUTTER: &str = "Shutter";
    /// Value is the commanded azimuth in degrees.
    pub const DOME_SLEW: &str = "SlewToAzimuth";
    pub const DOME_PARK: &str = "Park";
    pub const DOME_HOME: &str = "FindHome";
    pub const DOME_ABORT: &str = "AbortSlew";
    /// Value `"true"` or `"false"`.
    pub const DOME_SLAVED: &str = "Slaved";
}

impl crate::device::DeviceInfo {
    /// The name a device is shown by: its display name, else its driver name,
    /// else its id.
    pub(crate) fn shown_name(&self) -> String {
        [&self.display_name, &self.name]
            .into_iter()
            .find(|name| !name.trim().is_empty())
            .cloned()
            .unwrap_or_else(|| self.id.clone())
    }
}

impl DeviceManager {
    /// Publish the camera's readout settings as it now reports them
    /// (`CameraSettingsChanged`). A camera whose status cannot be read has no
    /// settings to report, and nothing is published.
    pub(crate) async fn publish_camera_settings(&self, device_id: &str) -> bool {
        match self.camera_get_status(device_id).await {
            Ok(status) => {
                self.publish_state_event(EquipmentEvent::CameraSettingsChanged {
                    device_id: device_id.to_string(),
                    gain: status.gain,
                    offset: status.offset,
                    bin_x: status.bin_x,
                    bin_y: status.bin_y,
                });
                true
            }
            Err(e) => {
                tracing::debug!("No camera settings to publish for {}: {}", device_id, e);
                false
            }
        }
    }

    /// Publish one device state change. The reading an end-of-move event
    /// carries becomes the backstop poll's baseline for that device (see
    /// `backstop`), so the poll never re-announces a command's result.
    pub(crate) fn publish_state_event(&self, event: EquipmentEvent) {
        if let Some((device_id, reading)) = super::backstop::Reading::of_event(&event) {
            self.command_activity.record(device_id, reading);
        }
        self.app_state
            .publish_equipment_event(event, EventSeverity::Info);
    }

    /// Publish a setting change that has no event variant of its own.
    pub(crate) fn publish_property_changed(
        &self,
        device_type: DeviceType,
        device_id: &str,
        property: &str,
        value: String,
    ) {
        self.publish_state_event(EquipmentEvent::PropertyChanged {
            device_type: device_type.as_str().to_string(),
            device_id: device_id.to_string(),
            property: property.to_string(),
            value,
        });
    }

    /// Driver type of a registered device, for ops that need it outside their
    /// dispatch.
    pub(crate) async fn registered_driver_type(&self, device_id: &str) -> Option<DriverType> {
        self.devices
            .read()
            .await
            .get(device_id)
            .map(|d| d.info.driver_type)
    }

    /// Publish `MountSlewCompleted` once a commanded slew has actually
    /// arrived, watched in the background so the caller is not held up. A
    /// slew that stops short, is aborted or times out publishes nothing: the
    /// mount's status polling already says it stopped.
    pub(crate) async fn spawn_slew_completion_watch(
        &self,
        mount_id: &str,
        ra_hours: f64,
        dec_degrees: f64,
    ) {
        use skotiq_sequencer::slew_arrival::{
            wait_for_slew_arrival, SlewArrivalTimings, SlewSample,
        };

        let Some(frame) = self.mount_frame(mount_id).await else {
            return;
        };
        let target = frame.j2000_to_mount(ra_hours, dec_degrees);
        let app_state: SharedAppState = self.app_state.clone();
        let mount_id = mount_id.to_string();
        // The watch outlives this call, so it reads through the process-wide
        // manager, the same one the heartbeat tasks use.
        let manager = crate::api::get_device_manager().clone();
        tokio::spawn(async move {
            // Once a second: every read is a driver round trip, and the
            // caller usually runs its own faster watch beside this one.
            let timings = SlewArrivalTimings {
                poll_interval: std::time::Duration::from_secs(1),
                max_consecutive_failures: 10,
                ..SlewArrivalTimings::goto(crate::timeout_ops::Timeouts::long_slew())
            };
            let result = wait_for_slew_arrival(
                Some(target),
                &timings,
                || {
                    let manager = manager.clone();
                    let mount_id = mount_id.clone();
                    async move {
                        match manager.mount_get_status(&mount_id).await {
                            Ok(status) => SlewSample {
                                slewing: Some(status.slewing),
                                position: Some((status.right_ascension, status.declination)),
                            },
                            Err(_) => SlewSample {
                                slewing: None,
                                position: None,
                            },
                        }
                    }
                },
                || false,
                |_| {},
            )
            .await;
            match result {
                Ok(progress) if progress.near_target => {
                    app_state.publish_equipment_event(
                        EquipmentEvent::MountSlewCompleted {
                            ra: ra_hours,
                            dec: dec_degrees,
                        },
                        EventSeverity::Info,
                    );
                }
                Ok(progress) => tracing::info!(
                    "Mount {} stopped {} from the slew target",
                    mount_id,
                    progress.remaining_deg.map_or_else(
                        || "an unknown distance".to_string(),
                        skotiq_sequencer::slew_arrival::format_arc
                    )
                ),
                Err(e) => tracing::info!("Mount {} slew did not complete: {}", mount_id, e),
            }
        });
    }
}

#[cfg(test)]
#[path = "state_events_tests.rs"]
mod tests;
