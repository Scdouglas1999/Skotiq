use super::*;
use crate::event::EquipmentEvent;

impl DeviceManager {
    // Mount control

    /// Slew to J2000 coordinates and leave the mount tracking.
    ///
    /// Every goto ends tracking the target: tracking is switched on before the
    /// slew (ASCOM drivers may refuse a coordinate slew while it is off, and a
    /// mount that arrives untracked trails the target). A parked mount is left
    /// alone so the slew reports the park refusal itself, and a failed tracking
    /// command does not block the slew.
    pub async fn mount_slew(
        &self,
        device_id: &str,
        ra: f64,
        dec: f64,
    ) -> Result<(), DeviceOpError> {
        if let Some(reason) = crate::device_manager::motion_guard::block_reason(device_id) {
            return Err(DeviceOpError::invalid_state(device_id, reason));
        }
        self.ensure_tracking_for_slew(device_id).await;
        crate::device_manager::motion_guard::record_command(
            device_id,
            crate::device_manager::motion_guard::CommandKind::Slew,
        );
        self.mount_slew_dispatch(device_id, ra, dec).await?;
        // The driver returning means the slew has started, not finished: the
        // completion event waits for the mount to arrive (see `state_events`).
        self.publish_state_event(EquipmentEvent::MountSlewStarted { ra, dec });
        self.spawn_slew_completion_watch(device_id, ra, dec).await;
        Ok(())
    }

    async fn ensure_tracking_for_slew(&self, device_id: &str) {
        match self.mount_get_status(device_id).await {
            Ok(status) if status.tracking || status.parked => {}
            Ok(_) => {
                if let Err(e) = self.mount_set_tracking(device_id, true).await {
                    tracing::warn!(
                        "mount_slew: could not turn tracking on for {} before the slew: {}",
                        device_id,
                        e
                    );
                } else {
                    tracing::info!("mount_slew: turned tracking on for {}", device_id);
                }
            }
            Err(e) => tracing::warn!(
                "mount_slew: could not read the tracking state of {} before the slew: {}",
                device_id,
                e
            ),
        }
    }

    async fn mount_slew_dispatch(
        &self,
        device_id: &str,
        ra: f64,
        dec: f64,
    ) -> Result<(), DeviceOpError> {
        tracing::debug!(
            "mount_slew called: device_id={}, ra={}, dec={}",
            device_id,
            ra,
            dec
        );

        let mount = self.mount(device_id).await?;
        let frame = self
            .mount_frame(device_id)
            .await
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        // Catalog/solver coordinates are J2000; most mounts (ASCOM
        // equTopocentric, INDI EQUATORIAL_EOD_COORD, native LX200-protocol)
        // expect of-date coordinates — ~22′ apart in 2026. Convert at this
        // single choke point so every caller (sequencer, planetarium GOTO,
        // centering) lands on target. The Simulator is an of-date mount too
        // unless pinned to J2000 (`epoch::SimMountFrame`), so frame mixing
        // above this layer shows up offline instead of first on the rig.
        // See `device_manager::epoch` for the direction policy.
        let (ra, dec) = {
            let (mount_ra, mount_dec) = frame.j2000_to_mount(ra, dec);
            tracing::debug!(
                "mount_slew: J2000 ({:.5}h, {:.4}°) -> {} ({:.5}h, {:.4}°)",
                ra,
                dec,
                frame,
                mount_ra,
                mount_dec
            );
            (mount_ra, mount_dec)
        };

        mount.slew(ra, dec).await
    }

    /// Slew to a horizon position, publishing that the slew started (see
    /// `state_events`). There is no J2000 target to watch for arrival, so
    /// the UIs follow the slew to its end on their mount poll, which speeds
    /// up while the mount slews.
    pub async fn mount_slew_alt_az(
        &self,
        device_id: &str,
        altitude: f64,
        azimuth: f64,
    ) -> Result<(), DeviceOpError> {
        if let Some(reason) = crate::device_manager::motion_guard::block_reason(device_id) {
            return Err(DeviceOpError::invalid_state(device_id, reason));
        }
        crate::device_manager::motion_guard::record_command(
            device_id,
            crate::device_manager::motion_guard::CommandKind::Slew,
        );
        self.mount_slew_alt_az_dispatch(device_id, altitude, azimuth)
            .await?;
        self.publish_property_changed(
            DeviceType::Mount,
            device_id,
            crate::device_manager::ops::state_events::property::MOUNT_SLEW_ALT_AZ,
            format!("{altitude} {azimuth}"),
        );
        Ok(())
    }

    async fn mount_slew_alt_az_dispatch(
        &self,
        device_id: &str,
        altitude: f64,
        azimuth: f64,
    ) -> Result<(), DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.slew_alt_az(altitude, azimuth).await
    }

    /// Abort a slew, publishing that it was aborted (see `state_events`).
    pub async fn mount_abort(&self, device_id: &str) -> Result<(), DeviceOpError> {
        crate::device_manager::motion_guard::record_command(
            device_id,
            crate::device_manager::motion_guard::CommandKind::Abort,
        );
        self.mount_abort_dispatch(device_id).await?;
        self.publish_property_changed(
            DeviceType::Mount,
            device_id,
            crate::device_manager::ops::state_events::property::MOUNT_ABORT,
            String::new(),
        );
        Ok(())
    }

    async fn mount_abort_dispatch(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.abort().await
    }

    pub async fn mount_stop(&self, device_id: &str) -> Result<(), DeviceOpError> {
        crate::device_manager::motion_guard::record_command(
            device_id,
            crate::device_manager::motion_guard::CommandKind::Abort,
        );
        let mount = self.mount(device_id).await?;

        mount.stop().await
    }

    /// Move an axis at the specified rate (degrees/second)
    /// axis: 0=RA/Azimuth (primary), 1=Dec/Altitude (secondary)
    /// rate: degrees per second (positive = N/E, negative = S/W), 0 to stop
    pub async fn mount_move_axis(
        &self,
        device_id: &str,
        axis: i32,
        rate: f64,
    ) -> Result<(), DeviceOpError> {
        tracing::debug!(
            "mount_move_axis called: device_id={}, axis={}, rate={}",
            device_id,
            axis,
            rate
        );
        crate::device_manager::motion_guard::record_command(
            device_id,
            crate::device_manager::motion_guard::CommandKind::MoveAxis { axis, rate },
        );

        let mount = self.mount(device_id).await?;

        mount.move_axis(axis, rate).await
    }
}
