use super::*;

impl DeviceManager {
    /// Sync the mount to J2000 coordinates, publishing the position synced
    /// to (see `state_events`).
    pub async fn mount_sync(
        &self,
        device_id: &str,
        ra: f64,
        dec: f64,
    ) -> Result<(), DeviceOpError> {
        // A sync far from where the mount says it points is a lost position
        // model, not a pointing correction (see `motion_guard::check_sync`).
        if let Ok(status) = self.mount_get_status(device_id).await {
            crate::device_manager::motion_guard::check_sync(
                device_id,
                (status.right_ascension, status.declination),
                (ra, dec),
            )
            .await
            .map_err(|reason| DeviceOpError::invalid_state(device_id, reason))?;
        }
        crate::device_manager::motion_guard::record_command(
            device_id,
            crate::device_manager::motion_guard::CommandKind::Sync,
        );
        self.mount_sync_dispatch(device_id, ra, dec).await?;
        self.publish_property_changed(
            DeviceType::Mount,
            device_id,
            crate::device_manager::ops::state_events::property::MOUNT_SYNCED,
            format!("{ra} {dec}"),
        );
        Ok(())
    }

    async fn mount_sync_dispatch(
        &self,
        device_id: &str,
        ra: f64,
        dec: f64,
    ) -> Result<(), DeviceOpError> {
        let mount = self.mount(device_id).await?;

        // Same J2000 -> of-date conversion as mount_slew, and it MUST match:
        // sync and slew feeding the mount from different frames would skew
        // the pointing model by the precession offset on every centering
        // iteration. See `device_manager::epoch`.
        let (ra, dec) = self
            .mount_frame(device_id)
            .await
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?
            .j2000_to_mount(ra, dec);

        mount.sync(ra, dec).await
    }

    pub async fn mount_get_coordinates(
        &self,
        device_id: &str,
    ) -> Result<(f64, f64), DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.coordinates().await
    }

    /// Read the mount's status. The outcome feeds the device's read health (see
    /// [`crate::device_manager::read_health`]), and every reading also goes to
    /// the motion guard, which compares it with the commands the mount was
    /// sent. Both count the same failed reads: a mount that goes silent is a
    /// run of failed reads to the heartbeat and a silence to the guard.
    pub async fn mount_get_status(&self, device_id: &str) -> Result<MountStatus, DeviceOpError> {
        let result = self.mount_get_status_dispatch(device_id).await;
        self.note_status_read(device_id, &result);
        if !matches!(result, Err(DeviceOpError::DeviceNotFound(_))) {
            crate::device_manager::motion_guard::observe_status(device_id, &result).await;
        }
        result
    }

    async fn mount_get_status_dispatch(
        &self,
        device_id: &str,
    ) -> Result<MountStatus, DeviceOpError> {
        let mount = self.mount(device_id).await?;

        mount.status().await
    }

    pub(crate) fn mount_status_availability_map() -> HashMap<String, FieldAvailability> {
        HashMap::with_capacity(6)
    }

    pub(crate) fn set_mount_availability(
        availability: &mut HashMap<String, FieldAvailability>,
        field: &'static str,
        value: FieldAvailability,
    ) {
        availability.insert(field.to_owned(), value);
    }

    /// Convert a `Result<T, DriverError>` into `(Option<T>, FieldAvailability)`,
    /// inserting the availability entry under `field` and returning the value.
    ///
    /// Used by `mount_get_status` so each per-field branch shrinks to one call
    /// instead of duplicating the same availability/log scaffolding.
    pub(crate) fn availability_from_native_result<T>(
        result: Result<T, skotiq_device::DriverError>,
        field: &'static str,
        availability: &mut HashMap<String, FieldAvailability>,
    ) -> Option<T> {
        match result {
            Ok(v) => {
                Self::set_mount_availability(availability, field, FieldAvailability::Available);
                Some(v)
            }
            Err(skotiq_device::DriverError::NotSupported) => {
                Self::set_mount_availability(availability, field, FieldAvailability::Unsupported);
                None
            }
            Err(e) => {
                Self::set_mount_availability(
                    availability,
                    field,
                    FieldAvailability::Error(e.to_string()),
                );
                None
            }
        }
    }

    /// Same shape as `availability_from_native_result` but for drivers that
    /// surface errors as plain `String` (Alpaca, INDI). Without a typed
    /// "unsupported" variant we always classify failures as `Error(reason)`.
    pub(crate) fn availability_from_string_result<T>(
        result: Result<T, String>,
        field: &'static str,
        availability: &mut HashMap<String, FieldAvailability>,
    ) -> Option<T> {
        match result {
            Ok(v) => {
                Self::set_mount_availability(availability, field, FieldAvailability::Available);
                Some(v)
            }
            Err(e) => {
                Self::set_mount_availability(availability, field, FieldAvailability::Error(e));
                None
            }
        }
    }

    pub(crate) fn pier_side_from_native(side: skotiq_device::PierSide) -> crate::device::PierSide {
        match side {
            skotiq_device::PierSide::East => crate::device::PierSide::East,
            skotiq_device::PierSide::West => crate::device::PierSide::West,
            skotiq_device::PierSide::Unknown => crate::device::PierSide::Unknown,
        }
    }

    pub(crate) fn pier_side_from_indi_element(element: &str) -> crate::device::PierSide {
        let upper = element.to_ascii_uppercase();
        if upper.contains("EAST") || upper.ends_with("_E") || upper == "PIER_E" {
            crate::device::PierSide::East
        } else if upper.contains("WEST") || upper.ends_with("_W") || upper == "PIER_W" {
            crate::device::PierSide::West
        } else {
            crate::device::PierSide::Unknown
        }
    }

    pub(crate) fn tracking_rate_from_native(rate: skotiq_device::TrackingRate) -> TrackingRate {
        match rate {
            skotiq_device::TrackingRate::Sidereal => TrackingRate::Sidereal,
            skotiq_device::TrackingRate::Lunar => TrackingRate::Lunar,
            skotiq_device::TrackingRate::Solar => TrackingRate::Solar,
            skotiq_device::TrackingRate::King => TrackingRate::King,
            skotiq_device::TrackingRate::Custom => TrackingRate::Custom,
        }
    }
}
