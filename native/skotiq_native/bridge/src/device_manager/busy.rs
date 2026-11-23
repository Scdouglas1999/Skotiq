//! One guard for "this device is busy": what an operation holds off while it
//! runs.
//!
//! Three markers exist because three readers ask different questions: the
//! backstop poll skips a device with a command in flight (and throws away a
//! reading a command overlapped), the heartbeat skips a device whose blocking
//! call is in flight, and the heartbeats of the devices that yield to camera
//! USB ([`super::policy::DevicePolicy::yields_to_camera_usb`]) skip while any
//! camera exposes. [`Busy`] names the kinds of work, and [`Busy::holds`] which
//! markers each sets.

use crate::device_manager::ops::backstop::CommandGuard;
use crate::device_manager::{DeviceManager, OperationGuard, UsbContentionGuard};

/// A kind of work an operation does on a device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Busy {
    /// A command that changes the device (a move, a halt): the backstop
    /// leaves the device alone.
    Command,
    /// A driver call that can block (an ASCOM move on the STA thread): the
    /// device's heartbeat waits.
    BlockingCall,
    /// A camera download: the camera's heartbeat waits.
    Download,
    /// A camera exposure through download: the heartbeats that yield to
    /// camera USB wait.
    Exposure,
}

/// The markers a kind of work sets.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Holds {
    pub(crate) backstop: bool,
    pub(crate) heartbeat: bool,
    pub(crate) camera_usb: bool,
}

impl Busy {
    pub(crate) const fn holds(self) -> Holds {
        match self {
            Self::Command => Holds {
                backstop: true,
                heartbeat: false,
                camera_usb: false,
            },
            Self::BlockingCall | Self::Download => Holds {
                backstop: false,
                heartbeat: true,
                camera_usb: false,
            },
            Self::Exposure => Holds {
                backstop: false,
                heartbeat: false,
                camera_usb: true,
            },
        }
    }
}

/// Holds what its [`Busy`] kind holds off until dropped, on every path out.
pub(crate) struct BusyGuard {
    _command: Option<CommandGuard>,
    _operation: Option<OperationGuard>,
    _camera_usb: Option<UsbContentionGuard>,
}

impl DeviceManager {
    /// Mark `device_id` busy with `kind` of work until the guard drops.
    pub(crate) fn busy(&self, device_id: &str, kind: Busy) -> BusyGuard {
        let holds = kind.holds();
        BusyGuard {
            _command: holds
                .backstop
                .then(|| self.command_activity.begin(device_id)),
            _operation: holds.heartbeat.then(|| self.begin_operation(device_id)),
            _camera_usb: holds.camera_usb.then(|| self.begin_usb_contention()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every kind of work and what it holds off.
    #[test]
    fn each_kind_of_work_and_what_it_holds_off() {
        let table = [
            (Busy::Command, (true, false, false)),
            (Busy::BlockingCall, (false, true, false)),
            (Busy::Download, (false, true, false)),
            (Busy::Exposure, (false, false, true)),
        ];
        for (kind, (backstop, heartbeat, camera_usb)) in table {
            assert_eq!(
                kind.holds(),
                Holds {
                    backstop,
                    heartbeat,
                    camera_usb
                },
                "{kind:?}"
            );
        }
    }

    #[tokio::test]
    async fn a_guard_sets_its_markers_until_it_drops() {
        let manager = DeviceManager::without_reconnection(crate::state::AppState::new());
        {
            let _download = manager.busy("cam", Busy::Download);
            assert!(manager.is_operation_active("cam"));
            assert!(!manager.is_usb_contended());
        }
        assert!(!manager.is_operation_active("cam"));
        {
            let _exposure = manager.busy("cam", Busy::Exposure);
            assert!(manager.is_usb_contended());
            assert!(!manager.is_operation_active("cam"));
        }
        assert!(!manager.is_usb_contended());
        {
            let _command = manager.busy("wheel", Busy::Command);
            assert_eq!(manager.command_activity.snapshot("wheel").0, 1);
        }
        assert_eq!(manager.command_activity.snapshot("wheel").0, 0);
    }
}
