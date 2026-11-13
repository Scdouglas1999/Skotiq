use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use crate::event::equipment::EquipmentEvent;

impl DeviceManager {
    /// Park the mount, publishing `MountParkStarted` before the command and
    /// `MountParkCompleted` once the driver reports it done (see
    /// `state_events`). A park that fails publishes no completion; the mount
    /// status polling shows where it stopped.
    pub async fn mount_park(&self, device_id: &str) -> Result<(), DeviceOpError> {
        if self.registered_driver_type(device_id).await.is_none() {
            return Err(DeviceOpError::device_not_found(device_id));
        }
        if let Some(reason) = crate::device_manager::motion_guard::block_reason(device_id) {
            return Err(DeviceOpError::invalid_state(device_id, reason));
        }
        crate::device_manager::motion_guard::record_command(
            device_id,
            crate::device_manager::motion_guard::CommandKind::Park,
        );
        self.publish_state_event(EquipmentEvent::MountParkStarted {
            device_id: device_id.to_string(),
        });
        self.mount_park_dispatch(device_id).await?;
        self.publish_state_event(EquipmentEvent::MountParkCompleted {
            device_id: device_id.to_string(),
        });
        Ok(())
    }

    /// Unpark the mount, publishing `MountUnparked` once it is.
    pub async fn mount_unpark(&self, device_id: &str) -> Result<(), DeviceOpError> {
        crate::device_manager::motion_guard::record_command(
            device_id,
            crate::device_manager::motion_guard::CommandKind::Unpark,
        );
        self.mount_unpark_dispatch(device_id).await?;
        self.publish_state_event(EquipmentEvent::MountUnparked {
            device_id: device_id.to_string(),
        });
        Ok(())
    }
}

impl DeviceManager {
    async fn mount_park_dispatch(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.park().await
    }

    async fn mount_unpark_dispatch(&self, device_id: &str) -> Result<(), DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.unpark().await
    }

    /// Send the mount to its home position.
    ///
    /// Homing is NOT parking. A homed mount is left unparked and keeps
    /// accepting slews, syncs and tracking commands; nothing here marks it
    /// parked. Tracking is left exactly as the driver leaves it — ASCOM's
    /// `FindHome` stops tracking, and turning it back on would carry the mount
    /// straight off the pose the operator asked for.
    ///
    /// Two preconditions are checked for every driver before anything moves:
    ///
    /// * the driver must report that it can home ([`Self::mount_can_find_home`]),
    ///   otherwise the call fails as [`DeviceOpError::Unsupported`];
    /// * the mount must not be parked. Several drivers answer `FindHome` on a
    ///   parked mount by quietly unparking it first, so a parked mount is
    ///   refused with [`DeviceOpError::InvalidState`] and the operator unparks
    ///   it deliberately.
    ///
    /// Most drivers return as soon as the home motion has started (INDI,
    /// OnStep, iOptron, ASCOM Platform 7 drivers, the simulator) and report
    /// progress through `Slewing`/`AtHome`; ASCOM V3 and Alpaca drivers that
    /// implement `FindHome` synchronously return when the mount arrives. An
    /// abort reaches the mount through [`Self::mount_abort`] in the first case;
    /// in the second it waits for the driver to hand the call back.
    pub async fn mount_find_home(&self, device_id: &str) -> Result<(), DeviceOpError> {
        if let Some(reason) = crate::device_manager::motion_guard::block_reason(device_id) {
            return Err(DeviceOpError::invalid_state(device_id, reason));
        }
        if !self.mount_can_find_home(device_id).await? {
            return Err(DeviceOpError::unsupported(format!(
                "Mount {} cannot find home: its driver does not report a home position",
                device_id
            )));
        }
        // Read through the full status path, which is also how the sequencer
        // learns the parked state, so every caller is refused on the same
        // reading. Done before taking the device map lock below: the status
        // read takes it too.
        if self.mount_get_status(device_id).await?.parked {
            return Err(DeviceOpError::invalid_state(
                device_id,
                format!(
                    "Mount {} is parked. Unpark it before sending it home.",
                    device_id
                ),
            ));
        }
        crate::device_manager::motion_guard::record_command(
            device_id,
            crate::device_manager::motion_guard::CommandKind::FindHome,
        );

        let mount = self.mount(device_id).await?;

        mount.find_home().await
    }

    /// Whether the mount's driver can send it to a home position.
    ///
    /// The same answer the capability snapshot publishes as `can_find_home`,
    /// read live from the driver so a command is never sent on a stale flag.
    pub async fn mount_can_find_home(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.can_find_home().await
    }

    /// Store the mount's current position as its park position.
    ///
    /// Nothing moves. Two preconditions are checked for every driver first:
    ///
    /// * the driver must report that it can set park
    ///   ([`Self::mount_can_set_park`]), otherwise the call fails as
    ///   [`DeviceOpError::Unsupported`];
    /// * the mount must not be slewing: the position read mid-slew is a point
    ///   the mount is passing through, not one the operator chose, so it is
    ///   refused with [`DeviceOpError::InvalidState`].
    pub async fn mount_set_park(&self, device_id: &str) -> Result<(), DeviceOpError> {
        if !self.mount_can_set_park(device_id).await? {
            return Err(DeviceOpError::unsupported(format!(
                "Mount {} cannot set its park position: its driver does not support it",
                device_id
            )));
        }
        // The same status path the sequencer reads, taken before the device
        // map lock below because it takes that lock too.
        if self.mount_get_status(device_id).await?.slewing {
            return Err(DeviceOpError::invalid_state(
                device_id,
                format!(
                    "Mount {} is moving. Wait for it to stop before setting park.",
                    device_id
                ),
            ));
        }

        let mount = self.mount(device_id).await?;

        mount.set_park().await
    }

    /// Whether the mount's driver can store the current position as its park
    /// position.
    ///
    /// The same answer the capability snapshot publishes as `can_set_park`,
    /// read live from the driver so a command is never sent on a stale flag.
    pub async fn mount_can_set_park(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.can_set_park().await
    }

    pub async fn mount_can_park(&self, device_id: &str) -> Result<bool, DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.can_park().await
    }
}
