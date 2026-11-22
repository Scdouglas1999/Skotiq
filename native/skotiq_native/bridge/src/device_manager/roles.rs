//! Which device plays a role in an operation: one resolver, and each role's
//! order of the places a device is looked up in.

use crate::device::DeviceType;
use crate::device_manager::DeviceManager;

/// A place a role's device is looked up in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RoleSource {
    /// The device of that type the running sequence was started with.
    Run(DeviceType),
    /// The device of that type the active equipment profile names.
    Profile(DeviceType),
    /// The first connected device of that type, by id.
    Connected(DeviceType),
}

/// A role an operation needs a device for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum RigRole {
    /// The safety source a run's safety check reads.
    RunSafety,
    /// The mount whose pointing a saved frame records.
    FramePointingMount,
    /// The mount a plate solve's diagnostics read.
    SolveDiagnosticsMount,
    /// The camera the motion guard's recovery frame is taken with.
    RecoveryCamera,
    /// The wheel the recovery frame's filter is set on.
    RecoveryWheel,
    /// The dome a run opens and closes.
    RunDome,
    /// The flat panel or cover a run drives.
    RunCoverCalibrator,
    /// The imaging camera the built-in guider keeps off its guide camera.
    GuiderImagingCamera,
    /// The mount the built-in guider pulses.
    GuiderMount,
    /// The camera a polar alignment takes its frames with.
    PolarCamera,
    /// The mount a polar alignment rotates.
    PolarMount,
}

impl RigRole {
    #[cfg(test)]
    pub(crate) const ALL: [Self; 11] = [
        Self::RunSafety,
        Self::FramePointingMount,
        Self::SolveDiagnosticsMount,
        Self::RecoveryCamera,
        Self::RecoveryWheel,
        Self::RunDome,
        Self::RunCoverCalibrator,
        Self::GuiderImagingCamera,
        Self::GuiderMount,
        Self::PolarCamera,
        Self::PolarMount,
    ];

    /// Where the role's device is looked up, first place first.
    pub(crate) const fn order(self) -> &'static [RoleSource] {
        use DeviceType::*;
        use RoleSource::*;
        match self {
            Self::RunSafety => &[
                Connected(SafetyMonitor),
                Profile(SafetyMonitor),
                Profile(Weather),
            ],
            Self::FramePointingMount => &[Connected(Mount)],
            Self::SolveDiagnosticsMount => &[Profile(Mount)],
            Self::RecoveryCamera => &[Run(Camera), Profile(Camera), Connected(Camera)],
            Self::RecoveryWheel => &[Run(FilterWheel), Connected(FilterWheel)],
            Self::RunDome => &[Connected(Dome)],
            Self::RunCoverCalibrator => &[Connected(CoverCalibrator)],
            Self::GuiderImagingCamera => &[Profile(Camera), Connected(Camera)],
            Self::GuiderMount => &[Profile(Mount), Connected(Mount)],
            Self::PolarCamera => &[Connected(Camera)],
            Self::PolarMount => &[Connected(Mount)],
        }
    }
}

impl DeviceManager {
    /// The device that plays `role`: `explicit` when the caller names one,
    /// else the first the role's [`RigRole::order`] finds.
    pub(crate) async fn rig_device(&self, role: RigRole, explicit: Option<&str>) -> Option<String> {
        if let Some(id) = explicit {
            return Some(id.to_string());
        }
        for source in role.order() {
            let found = match *source {
                RoleSource::Run(device_type) => run_device(device_type),
                RoleSource::Profile(device_type) => {
                    self.app_state.get_profile_device_id(device_type).await
                }
                RoleSource::Connected(device_type) => {
                    self.first_connected_device_id(device_type).await
                }
            };
            if found.is_some() {
                return found;
            }
        }
        None
    }
}

fn run_device(device_type: DeviceType) -> Option<String> {
    let devices = skotiq_sequencer::executor_handle().devices();
    match device_type {
        DeviceType::Camera => devices.camera_id,
        DeviceType::FilterWheel => devices.filterwheel_id,
        DeviceType::Mount => devices.mount_id,
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every role and where it looks today. The orders differ: a change of
    /// rule (the profile first, say) is a change of this table.
    #[test]
    fn each_role_and_its_order() {
        use DeviceType::*;
        use RigRole::*;
        use RoleSource::*;
        let table: [(RigRole, &[RoleSource]); 11] = [
            (
                RunSafety,
                &[
                    Connected(SafetyMonitor),
                    Profile(SafetyMonitor),
                    Profile(Weather),
                ],
            ),
            (FramePointingMount, &[Connected(Mount)]),
            (SolveDiagnosticsMount, &[Profile(Mount)]),
            (
                RecoveryCamera,
                &[Run(Camera), Profile(Camera), Connected(Camera)],
            ),
            (RecoveryWheel, &[Run(FilterWheel), Connected(FilterWheel)]),
            (RunDome, &[Connected(Dome)]),
            (RunCoverCalibrator, &[Connected(CoverCalibrator)]),
            (GuiderImagingCamera, &[Profile(Camera), Connected(Camera)]),
            (GuiderMount, &[Profile(Mount), Connected(Mount)]),
            (PolarCamera, &[Connected(Camera)]),
            (PolarMount, &[Connected(Mount)]),
        ];
        assert_eq!(table.map(|row| row.0), RigRole::ALL);
        for (role, order) in table {
            assert_eq!(role.order(), order, "{role:?}");
        }
    }
}
