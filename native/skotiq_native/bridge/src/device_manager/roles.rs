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
    /// The first connected device of that type, by id. A device a reopen is
    /// closing and opening counts: it still plays the role.
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
            Self::FramePointingMount => &[Profile(Mount), Connected(Mount)],
            Self::SolveDiagnosticsMount => &[Profile(Mount)],
            Self::RecoveryCamera => &[Run(Camera), Profile(Camera), Connected(Camera)],
            Self::RecoveryWheel => &[Run(FilterWheel), Connected(FilterWheel)],
            Self::RunDome => &[Connected(Dome)],
            Self::RunCoverCalibrator => &[Connected(CoverCalibrator)],
            Self::GuiderImagingCamera => &[Profile(Camera), Connected(Camera)],
            Self::GuiderMount => &[Profile(Mount), Connected(Mount)],
            Self::PolarCamera => &[Profile(Camera), Connected(Camera)],
            Self::PolarMount => &[Profile(Mount), Connected(Mount)],
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
                RoleSource::Connected(device_type) => self.first_playing(device_type).await,
            };
            if found.is_some() {
                return found;
            }
        }
        None
    }
}

impl DeviceManager {
    /// The first device of `device_type` by id that is connected or being
    /// reopened. For the second a reopen takes its state reads disconnected,
    /// and the role must not pass to another device (a second safety monitor,
    /// the guide camera) for it.
    async fn first_playing(&self, device_type: DeviceType) -> Option<String> {
        let devices = self.devices.read().await;
        devices
            .values()
            .filter(|d| {
                d.info.device_type == device_type
                    && (d.connection_state == crate::device::ConnectionState::Connected
                        || self.is_reopening(&d.info.id))
            })
            .map(|d| d.info.id.clone())
            .min()
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

    /// Every role and where it looks. The orders differ: a change of rule is
    /// a change of this table.
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
            (FramePointingMount, &[Profile(Mount), Connected(Mount)]),
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
            (PolarCamera, &[Profile(Camera), Connected(Camera)]),
            (PolarMount, &[Profile(Mount), Connected(Mount)]),
        ];
        assert_eq!(table.map(|row| row.0), RigRole::ALL);
        for (role, order) in table {
            assert_eq!(role.order(), order, "{role:?}");
        }
    }

    fn connected(id: &str, device_type: DeviceType) -> crate::device::DeviceInfo {
        crate::device::DeviceInfo {
            id: id.to_string(),
            name: id.to_string(),
            device_type,
            driver_type: crate::device::DriverType::Simulator,
            description: String::new(),
            driver_version: String::new(),
            serial_number: None,
            unique_id: None,
            display_name: id.to_string(),
        }
    }

    /// P8-5 (BUG M4): with a guide camera connected whose id sorts first,
    /// polar alignment took its frames from the guide camera. Polar
    /// alignment and frame pointing take the profile's device first.
    #[tokio::test]
    async fn polar_alignment_and_frame_pointing_take_the_profiles_device_first() {
        let manager = DeviceManager::without_reconnection(crate::state::AppState::new());
        for (id, device_type) in [
            ("aa_guide_camera", DeviceType::Camera),
            ("zz_imaging_camera", DeviceType::Camera),
            ("aa_other_mount", DeviceType::Mount),
            ("zz_rig_mount", DeviceType::Mount),
        ] {
            manager
                .register_connected_device(connected(id, device_type))
                .await;
        }
        manager
            .app_state
            .set_profile(Some(crate::state::EquipmentProfile {
                id: "rig".into(),
                name: "Rig".into(),
                camera_id: Some("zz_imaging_camera".into()),
                mount_id: Some("zz_rig_mount".into()),
                focuser_id: None,
                filter_wheel_id: None,
                guider_id: None,
                guide_camera_id: Some("aa_guide_camera".into()),
                guide_focal_length_mm: None,
                rotator_id: None,
                dome_id: None,
                weather_id: None,
                safety_monitor_id: None,
                cover_calibrator_id: None,
                telescope_focal_length: 480.0,
                telescope_aperture: 80.0,
            }))
            .await;
        for (role, wanted) in [
            (RigRole::PolarCamera, "zz_imaging_camera"),
            (RigRole::PolarMount, "zz_rig_mount"),
            (RigRole::FramePointingMount, "zz_rig_mount"),
        ] {
            assert_eq!(
                manager.rig_device(role, None).await.as_deref(),
                Some(wanted),
                "{role:?}"
            );
        }
        manager.app_state.set_profile(None).await;
        assert_eq!(
            manager
                .rig_device(RigRole::PolarCamera, None)
                .await
                .as_deref(),
            Some("aa_guide_camera"),
            "with no profile the first connected camera answers, as before"
        );
    }

    /// R1H2-1: while a safety monitor is reopened it still is the run's
    /// safety source; the check does not pass to another monitor for that
    /// second.
    #[tokio::test]
    async fn a_device_being_reopened_keeps_its_role() {
        let manager = DeviceManager::without_reconnection(crate::state::AppState::new());
        for id in ["a_monitor", "b_monitor"] {
            manager
                .register_connected_device(connected(id, DeviceType::SafetyMonitor))
                .await;
        }
        manager.mark_reopening("a_monitor", true);
        manager
            .devices
            .write()
            .await
            .get_mut("a_monitor")
            .unwrap()
            .connection_state = crate::device::ConnectionState::Disconnected;
        assert_eq!(
            manager
                .rig_device(RigRole::RunSafety, None)
                .await
                .as_deref(),
            Some("a_monitor")
        );
        manager.mark_reopening("a_monitor", false);
        assert_eq!(
            manager
                .rig_device(RigRole::RunSafety, None)
                .await
                .as_deref(),
            Some("b_monitor")
        );
    }
}
