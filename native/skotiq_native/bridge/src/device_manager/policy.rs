//! How the device manager treats each device type, in one place.

use crate::device::DeviceType;
use crate::device_manager::HeartbeatConfig;

pub(crate) struct DevicePolicy {
    pub(crate) heartbeat: HeartbeatConfig,
    /// A failed heartbeat probe is probed again after 750 ms, and only the
    /// second answer counts: these drivers miss single reads under load.
    pub(crate) retry_heartbeat: bool,
    /// Heartbeats are held off while a camera exposes or downloads. These are
    /// the auxiliaries that share the camera's USB path (a ZWO EAF/EFW behind
    /// an ASI camera) and lose status reads to the frame download. The camera
    /// drives the contention and the mount is on its own link, so neither
    /// yields.
    pub(crate) yields_to_camera_usb: bool,
    /// The backstop poll watches the device for moves made outside Skotiq
    /// (see `ops::backstop`).
    pub(crate) backstop_polled: bool,
}

/// The policy for `device_type`.
///
/// `escalate_to_disconnect` is `true` where liveness is itself a signal a run
/// depends on: a sustained loss tears the device down so reconnect and
/// recovery run, rather than leaving a dead device registered as connected.
/// Slow, contention-prone auxiliaries reach that point later, through higher
/// failure thresholds, the heartbeat retry and the USB hold-off.
pub(crate) fn policy(device_type: DeviceType) -> DevicePolicy {
    match device_type {
        DeviceType::Camera => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 10,
                max_interval_secs: 60,
                failure_threshold: 3,
                // Three failed polls already debounce transient errors;
                // backing off would add 40 s before confirming a lost camera.
                backoff_multiplier: 1.0,
                auto_reconnect: false,
                // A dead camera stalls every frame.
                escalate_to_disconnect: true,
            },
            retry_heartbeat: false,
            yields_to_camera_usb: false,
            backstop_polled: false,
        },
        DeviceType::Mount => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 5,
                max_interval_secs: 30,
                // One transient timeout pair must not drop a tracking mount:
                // the ASCOM probe shares the process-wide STA worker, so a slow
                // driver call can starve a single read. The run's own slews and
                // syncs surface a dead mount sooner than the heartbeat.
                failure_threshold: 3,
                backoff_multiplier: 1.5,
                auto_reconnect: true,
                // A dead mount drifts off target and can slew into the pier.
                escalate_to_disconnect: true,
            },
            retry_heartbeat: true,
            yields_to_camera_usb: false,
            backstop_polled: false,
        },
        DeviceType::Focuser => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 15,
                max_interval_secs: 60,
                // Tolerates another client briefly holding the focuser (NINA).
                failure_threshold: 5,
                // Five double-probed misses are debounce enough; a fixed cadence
                // recovers a dead focuser in about 75 s.
                backoff_multiplier: 1.0,
                auto_reconnect: false,
                escalate_to_disconnect: true,
            },
            retry_heartbeat: true,
            yields_to_camera_usb: true,
            backstop_polled: true,
        },
        DeviceType::FilterWheel => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 20,
                max_interval_secs: 120,
                // Tolerates another client briefly holding the wheel (NINA).
                failure_threshold: 5,
                // A fixed cadence recovers a lost wheel in about 100 s.
                backoff_multiplier: 1.0,
                auto_reconnect: false,
                escalate_to_disconnect: true,
            },
            retry_heartbeat: true,
            yields_to_camera_usb: true,
            backstop_polled: true,
        },
        DeviceType::Rotator => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 15,
                max_interval_secs: 60,
                // Tolerates another client briefly holding the rotator (NINA).
                failure_threshold: 5,
                backoff_multiplier: 1.0,
                auto_reconnect: false,
                escalate_to_disconnect: true,
            },
            retry_heartbeat: false,
            yields_to_camera_usb: true,
            backstop_polled: true,
        },
        DeviceType::Dome => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 15,
                max_interval_secs: 90,
                failure_threshold: 4,
                backoff_multiplier: 2.0,
                auto_reconnect: true,
                // The enclosure is safety-relevant (rain, roof).
                escalate_to_disconnect: true,
            },
            retry_heartbeat: false,
            yields_to_camera_usb: false,
            backstop_polled: false,
        },
        DeviceType::Weather => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 30,
                max_interval_secs: 180,
                failure_threshold: 5,
                backoff_multiplier: 2.0,
                auto_reconnect: true,
                // Safety-relevant (clouds, rain): the session must be able to react.
                escalate_to_disconnect: true,
            },
            retry_heartbeat: false,
            yields_to_camera_usb: false,
            backstop_polled: false,
        },
        DeviceType::SafetyMonitor => DevicePolicy {
            // Only a liveness ping: the safety signal (`IsSafe`) is read on its
            // own paths, the Dart environment poll and, during a run, the
            // sequencer's fail-closed check. A missed ping latches a Degraded
            // "stale" badge and monitoring continues; tearing the device down
            // would turn a flaky network hub into an endless
            // disconnect/reconnect cycle of error toasts, while a real loss of
            // safety is still caught by the `IsSafe` read.
            heartbeat: HeartbeatConfig {
                base_interval_secs: 15,
                max_interval_secs: 60,
                failure_threshold: 4,
                backoff_multiplier: 2.0,
                auto_reconnect: false,
                escalate_to_disconnect: false,
            },
            retry_heartbeat: false,
            yields_to_camera_usb: false,
            backstop_polled: false,
        },
        DeviceType::Guider => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 5,
                max_interval_secs: 30,
                failure_threshold: 2,
                backoff_multiplier: 1.5,
                auto_reconnect: true,
                // Guiding must not lapse silently during an exposure.
                escalate_to_disconnect: true,
            },
            retry_heartbeat: false,
            yields_to_camera_usb: false,
            backstop_polled: false,
        },
        DeviceType::Switch => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 20,
                max_interval_secs: 120,
                // With a 2.0 backoff from 20 s, five failures is well over a
                // minute of real unresponsiveness; it also tolerates another
                // client briefly holding the switch.
                failure_threshold: 5,
                backoff_multiplier: 2.0,
                auto_reconnect: false,
                // A switch often powers the rig (dew heaters, the mount's
                // supply): a lost power controller must surface loudly.
                escalate_to_disconnect: true,
            },
            retry_heartbeat: false,
            yields_to_camera_usb: false,
            backstop_polled: false,
        },
        DeviceType::CoverCalibrator => DevicePolicy {
            heartbeat: HeartbeatConfig {
                base_interval_secs: 10,
                max_interval_secs: 60,
                failure_threshold: 3,
                backoff_multiplier: 2.0,
                auto_reconnect: true,
                // Flat panel or dust cover: part of the session's safety.
                escalate_to_disconnect: true,
            },
            retry_heartbeat: false,
            yields_to_camera_usb: false,
            backstop_polled: false,
        },
    }
}

const DEVICE_TYPES: [DeviceType; 11] = [
    DeviceType::Camera,
    DeviceType::Mount,
    DeviceType::Focuser,
    DeviceType::FilterWheel,
    DeviceType::Guider,
    DeviceType::Dome,
    DeviceType::Rotator,
    DeviceType::Weather,
    DeviceType::SafetyMonitor,
    DeviceType::Switch,
    DeviceType::CoverCalibrator,
];

/// The device types a lost heartbeat hands to the reconnection loop. Whoever
/// else reconnects devices leaves these alone.
pub(crate) fn reconnected_by_heartbeat() -> Vec<DeviceType> {
    DEVICE_TYPES
        .into_iter()
        .filter(|device_type| policy(*device_type).heartbeat.auto_reconnect)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_heartbeat_reconnects_the_mount_the_guider_and_the_enclosure_devices() {
        assert_eq!(
            reconnected_by_heartbeat(),
            [
                DeviceType::Mount,
                DeviceType::Guider,
                DeviceType::Dome,
                DeviceType::Weather,
                DeviceType::CoverCalibrator,
            ]
        );
    }
}
