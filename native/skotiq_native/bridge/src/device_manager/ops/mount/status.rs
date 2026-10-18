use super::*;

impl DeviceManager {
    pub async fn mount_sync(
        &self,
        device_id: &str,
        ra: f64,
        dec: f64,
    ) -> Result<(), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        // Same J2000 -> of-date conversion as mount_slew, and it MUST match:
        // sync and slew feeding the mount from different frames would skew
        // the pointing model by the precession offset on every centering
        // iteration. See `device_manager::epoch`.
        let (ra, dec) =
            crate::device_manager::epoch::j2000_to_mount_frame(info.driver_type, ra, dec);

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        let mut mount = mount.write().await;
                        return mount.sync_to_coordinates(ra, dec).await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to sync ASCOM mount {} to RA={:.4} Dec={:.4}: {}",
                                    device_id, ra, dec, e
                                ),
                            )
                        });
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    return mount
                        .sync_to_coordinates(ra, dec)
                        .await
                        .map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca mount {} not connected", device_id),
                ))
            }
            DriverType::Indi => {
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");
                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
                        return mount.sync_to_coordinates(ra, dec).await.map_err(|e| {
                            DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to sync INDI mount {} to RA={:.4} Dec={:.4}: {}",
                                    device_name, ra, dec, e
                                ),
                            )
                        });
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(format!(
                    "Invalid INDI device ID format: {}",
                    device_id
                )))
            }
            DriverType::Native => {
                let mut native_mounts = self.native_mounts.write().await;
                if let Some(mount) = native_mounts.get_mut(device_id) {
                    return mount.sync_to_coordinates(ra, dec).await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to sync native mount {} to RA={:.4} Dec={:.4}: {}",
                                device_id, ra, dec, e
                            ),
                        )
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Simulator => {
                crate::device_manager::ops::sim_gate::require_mount_connected().await?;
                crate::device_manager::ops::sim_gate::refuse_while_mount_slewing("sync").await?;
                // A sync redefines where the mount believes it is pointing
                // without moving it, so any in-flight slew has to be dropped
                // first — otherwise the interpolation would overwrite the
                // synced coordinates on the next status read.
                crate::api::devices::simulation::cancel_sim_slew().await;
                let m = crate::api::devices::simulation::get_sim_mount();
                let mut m = m.write().await;
                m.status.right_ascension = ra;
                m.status.declination = dec;
                m.status.slewing = false;
                Ok(())
            }
        }
    }

    pub async fn mount_get_coordinates(
        &self,
        device_id: &str,
    ) -> Result<(f64, f64), DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        let mount = mount.read().await;
                        return mount.get_coordinates().await.map_err(DeviceOpError::driver);
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Native => {
                let native_mounts = self.native_mounts.read().await;
                if let Some(mount) = native_mounts.get(device_id) {
                    return mount.get_coordinates().await.map_err(DeviceOpError::driver);
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    let ra = mount
                        .right_ascension()
                        .await
                        .map_err(DeviceOpError::driver)?;
                    let dec = mount.declination().await.map_err(DeviceOpError::driver)?;
                    return Ok((ra, dec));
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("Alpaca mount {} not connected", device_id),
                ))
            }
            DriverType::Indi => {
                if let Ok((host, port, device_name)) = Self::parse_indi_device_id(device_id) {
                    let server_key = format!("{host}:{port}");
                    let clients = self.indi_clients.read().await;
                    if let Some(client) = clients.get(&server_key) {
                        let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
                        return mount.get_coordinates().await.map_err(DeviceOpError::driver);
                    }
                    return Err(DeviceOpError::not_connected(
                        Some(device_id.to_string()),
                        format!("INDI client not connected for {}", server_key),
                    ));
                }
                Err(DeviceOpError::invalid_device_id(format!(
                    "Invalid INDI device ID format: {}",
                    device_id
                )))
            }
            DriverType::Simulator => {
                let sim = crate::device_manager::ops::sim_gate::read_mount_status().await?;
                Ok((sim.right_ascension, sim.declination))
            }
        }
    }

    pub async fn mount_get_status(&self, device_id: &str) -> Result<MountStatus, DeviceOpError> {
        let devices = self.devices.read().await;
        let info = devices
            .get(device_id)
            .map(|d| d.info.clone())
            .ok_or_else(|| DeviceOpError::device_not_found(device_id))?;

        match info.driver_type {
            DriverType::Ascom => {
                #[cfg(windows)]
                {
                    let mounts = self.ascom_mounts.read().await;
                    if let Some(mount) = mounts.get(device_id) {
                        let mount = mount.read().await;

                        // Required fields propagate read failures — these are not optional.
                        let (ra, dec) = mount
                            .get_coordinates()
                            .await
                            .map_err(DeviceOpError::driver)?;
                        let tracking = mount.get_tracking().await.map_err(DeviceOpError::driver)?;
                        let slewing = mount.is_slewing().await.map_err(DeviceOpError::driver)?;
                        let parked = mount.is_parked().await.map_err(DeviceOpError::driver)?;

                        let mut availability = Self::mount_status_availability_map();

                        // Optional fields: the ASCOM wrapper currently does not surface a
                        // distinct "not supported" error so any failure is recorded as Error.
                        let (alt_opt, az_opt) = match mount.get_alt_az().await {
                            Ok((a, z)) => (Some(a), Some(z)),
                            Err(e) => {
                                let msg = e.to_string();
                                Self::set_mount_availability(
                                    &mut availability,
                                    mount_status_field::ALTITUDE,
                                    FieldAvailability::Error(msg.clone()),
                                );
                                Self::set_mount_availability(
                                    &mut availability,
                                    mount_status_field::AZIMUTH,
                                    FieldAvailability::Error(msg),
                                );
                                (None, None)
                            }
                        };
                        if alt_opt.is_some() {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::ALTITUDE,
                                FieldAvailability::Available,
                            );
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::AZIMUTH,
                                FieldAvailability::Available,
                            );
                        }

                        let side_of_pier_opt = Self::availability_from_native_result(
                            mount.get_side_of_pier().await,
                            mount_status_field::SIDE_OF_PIER,
                            &mut availability,
                        )
                        .map(Self::pier_side_from_native);

                        let sidereal_time_opt = Self::availability_from_native_result(
                            mount.get_sidereal_time().await,
                            mount_status_field::SIDEREAL_TIME,
                            &mut availability,
                        );

                        let at_home_opt = Self::availability_from_native_result(
                            mount.at_home().await,
                            mount_status_field::AT_HOME,
                            &mut availability,
                        );

                        let capabilities = match mount.get_capabilities().await {
                            Ok(caps) => caps,
                            Err(err) => {
                                warn!(
                                    "Failed to query ASCOM mount capabilities for {}: {}. Marking capabilities unavailable.",
                                    device_id, err
                                );
                                crate::ascom_wrapper::mount::AscomMountCapabilities::default()
                            }
                        };

                        let (tracking_rate_opt, can_set_tracking_rate) =
                            match mount.get_tracking_rate().await {
                                Ok(rate) => {
                                    Self::set_mount_availability(
                                        &mut availability,
                                        mount_status_field::TRACKING_RATE,
                                        FieldAvailability::Available,
                                    );
                                    (Some(Self::tracking_rate_from_native(rate)), true)
                                }
                                Err(skotiq_native::traits::NativeError::NotSupported) => {
                                    Self::set_mount_availability(
                                        &mut availability,
                                        mount_status_field::TRACKING_RATE,
                                        FieldAvailability::Unsupported,
                                    );
                                    (None, false)
                                }
                                Err(err) => {
                                    Self::set_mount_availability(
                                        &mut availability,
                                        mount_status_field::TRACKING_RATE,
                                        FieldAvailability::Error(err.to_string()),
                                    );
                                    (None, false)
                                }
                            };

                        return Ok(MountStatus {
                            connected: true,
                            tracking,
                            slewing,
                            parked,
                            at_home: at_home_opt,
                            side_of_pier: side_of_pier_opt,
                            right_ascension: ra,
                            declination: dec,
                            altitude: alt_opt,
                            azimuth: az_opt,
                            sidereal_time: sidereal_time_opt,
                            tracking_rate: tracking_rate_opt,
                            can_park: capabilities.can_park,
                            can_slew: capabilities.can_slew,
                            can_sync: capabilities.can_sync,
                            can_pulse_guide: capabilities.can_pulse_guide,
                            can_set_tracking_rate,
                            availability,
                        });
                    }
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "ASCOM mount not connected",
                ))
            }
            DriverType::Native => {
                let native_mounts = self.native_mounts.read().await;
                if let Some(mount) = native_mounts.get(device_id) {
                    // Required fields propagate read failures — these are not optional.
                    let (ra, dec) = mount
                        .get_coordinates()
                        .await
                        .map_err(DeviceOpError::driver)?;
                    let tracking = mount.get_tracking().await.map_err(DeviceOpError::driver)?;
                    let slewing = mount.is_slewing().await.map_err(DeviceOpError::driver)?;
                    let (parked, can_park, parked_readable) = match mount.is_parked().await {
                        Ok(p) => (p, true, true),
                        Err(skotiq_native::traits::NativeError::NotSupported) => {
                            (false, false, false)
                        }
                        Err(e) => {
                            return Err(DeviceOpError::hardware(
                                Some(device_id.to_string()),
                                format!(
                                    "Failed to read native mount parked state for {}: {}",
                                    device_id, e
                                ),
                            ));
                        }
                    };

                    let mut availability = Self::mount_status_availability_map();
                    if !parked_readable {
                        // The `parked: false` above is fabricated, not observed
                        // — record that so consumers can refuse to trust it
                        // (`parked_from_status`). Only this Native arm launders
                        // NotSupported into a bool; every other backend either
                        // reads `parked` genuinely or propagates the error.
                        availability.insert(
                            mount_status_field::PARKED.to_string(),
                            FieldAvailability::Unsupported,
                        );
                    }

                    // get_side_of_pier on `NativeMount` returns Unknown rather than Err
                    // for unsupported mounts (e.g. SkyWatcher), so distinguish here:
                    // Unknown → Unsupported availability; East/West → Available.
                    let side_of_pier_opt = match mount.get_side_of_pier().await {
                        Ok(skotiq_native::traits::PierSide::Unknown) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::SIDE_OF_PIER,
                                FieldAvailability::Unsupported,
                            );
                            None
                        }
                        Ok(other) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::SIDE_OF_PIER,
                                FieldAvailability::Available,
                            );
                            Some(Self::pier_side_from_native(other))
                        }
                        Err(skotiq_native::traits::NativeError::NotSupported) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::SIDE_OF_PIER,
                                FieldAvailability::Unsupported,
                            );
                            None
                        }
                        Err(e) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::SIDE_OF_PIER,
                                FieldAvailability::Error(e.to_string()),
                            );
                            None
                        }
                    };

                    // Native drivers report Err(NotSupported) explicitly for alt/az and
                    // sidereal time on protocols that lack them (e.g. SkyWatcher, LX200).
                    let alt_az_pair = Self::availability_from_native_result(
                        mount.get_alt_az().await,
                        // Use ALTITUDE as primary key; AZIMUTH mirror is set below.
                        mount_status_field::ALTITUDE,
                        &mut availability,
                    );
                    // Mirror availability onto the AZIMUTH key — they share a single call.
                    let alt_avail = availability
                        .get(mount_status_field::ALTITUDE)
                        .cloned()
                        .unwrap_or(FieldAvailability::Available);
                    Self::set_mount_availability(
                        &mut availability,
                        mount_status_field::AZIMUTH,
                        alt_avail,
                    );
                    let (alt_opt, az_opt) = match alt_az_pair {
                        Some((a, z)) => (Some(a), Some(z)),
                        None => (None, None),
                    };

                    let sidereal_time_opt = Self::availability_from_native_result(
                        mount.get_sidereal_time().await,
                        mount_status_field::SIDEREAL_TIME,
                        &mut availability,
                    );

                    // OnStep reports home in `:GU#`; drivers with no home
                    // concept answer NotSupported and land as Unsupported here,
                    // the same distinction the other driver types make.
                    let at_home_opt = Self::availability_from_native_result(
                        mount.at_home().await,
                        mount_status_field::AT_HOME,
                        &mut availability,
                    );

                    let tracking_rate_opt = Self::availability_from_native_result(
                        mount.get_tracking_rate().await,
                        mount_status_field::TRACKING_RATE,
                        &mut availability,
                    )
                    .map(Self::tracking_rate_from_native);

                    return Ok(MountStatus {
                        connected: true,
                        tracking,
                        slewing,
                        parked,
                        at_home: at_home_opt,
                        side_of_pier: side_of_pier_opt,
                        right_ascension: ra,
                        declination: dec,
                        altitude: alt_opt,
                        azimuth: az_opt,
                        sidereal_time: sidereal_time_opt,
                        tracking_rate: tracking_rate_opt,
                        can_park,
                        can_slew: mount.can_slew(),
                        can_sync: mount.can_sync(),
                        can_pulse_guide: mount.can_pulse_guide(),
                        can_set_tracking_rate: mount.can_set_tracking_rate(),
                        availability,
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Native mount not connected",
                ))
            }
            DriverType::Alpaca => {
                let mounts = self.alpaca_mounts.read().await;
                if let Some(mount) = mounts.get(device_id) {
                    // Required fields propagate read failures.
                    let ra = mount.right_ascension().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!("Failed to read Alpaca mount RA for {}: {}", device_id, e),
                        )
                    })?;
                    let dec = mount.declination().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!("Failed to read Alpaca mount Dec for {}: {}", device_id, e),
                        )
                    })?;
                    let tracking = mount.tracking().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to read Alpaca mount tracking for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let slewing = mount.slewing().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to read Alpaca mount slewing for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let parked = mount.at_park().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to read Alpaca mount at_park for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;

                    let mut availability = Self::mount_status_availability_map();

                    // Alpaca returns Result<_, String>; we cannot reliably distinguish
                    // "PropertyNotImplemented" from a transient HTTP failure without
                    // parsing the error message. Treat all failures as Error so callers
                    // see the underlying reason verbatim. UI can match on the prefix
                    // "PropertyNotImplemented" if it wants to render Unsupported.
                    let alt_opt = Self::availability_from_string_result(
                        mount.altitude().await,
                        mount_status_field::ALTITUDE,
                        &mut availability,
                    );
                    let az_opt = Self::availability_from_string_result(
                        mount.azimuth().await,
                        mount_status_field::AZIMUTH,
                        &mut availability,
                    );
                    let at_home_opt = Self::availability_from_string_result(
                        mount.at_home().await,
                        mount_status_field::AT_HOME,
                        &mut availability,
                    );
                    let sidereal_time_opt = Self::availability_from_string_result(
                        mount.sidereal_time().await,
                        mount_status_field::SIDEREAL_TIME,
                        &mut availability,
                    );

                    let side_of_pier_opt = match mount.side_of_pier().await {
                        Ok(skotiq_alpaca::PierSide::Unknown) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::SIDE_OF_PIER,
                                FieldAvailability::Unsupported,
                            );
                            None
                        }
                        Ok(other) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::SIDE_OF_PIER,
                                FieldAvailability::Available,
                            );
                            Some(match other {
                                skotiq_alpaca::PierSide::East => crate::device::PierSide::East,
                                skotiq_alpaca::PierSide::West => crate::device::PierSide::West,
                                skotiq_alpaca::PierSide::Unknown => {
                                    crate::device::PierSide::Unknown
                                }
                            })
                        }
                        Err(e) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::SIDE_OF_PIER,
                                FieldAvailability::Error(e),
                            );
                            None
                        }
                    };

                    let (can_park, can_slew, can_sync, can_pulse_guide) = match mount
                        .get_capabilities()
                        .await
                    {
                        Ok(caps) => (
                            caps.can_park,
                            caps.can_slew,
                            caps.can_sync,
                            caps.can_pulse_guide,
                        ),
                        Err(e) => {
                            warn!(
                                    "Failed to query Alpaca mount capabilities for {}: {}. Marking capabilities unsupported.",
                                    device_id, e
                                );
                            (false, false, false, false)
                        }
                    };
                    // CanSetTracking governs the boolean Tracking property.
                    // Rate mutability is advertised by TelescopeRates.
                    let can_set_tracking_rate = mount
                        .tracking_rates()
                        .await
                        .map(|rates| !rates.is_empty())
                        .unwrap_or(false);

                    let tracking_rate_opt = match mount.tracking_rate().await {
                        Ok(rate) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::TRACKING_RATE,
                                FieldAvailability::Available,
                            );
                            Some(match rate {
                                skotiq_alpaca::DriveRate::Sidereal => TrackingRate::Sidereal,
                                skotiq_alpaca::DriveRate::Lunar => TrackingRate::Lunar,
                                skotiq_alpaca::DriveRate::Solar => TrackingRate::Solar,
                                skotiq_alpaca::DriveRate::King => TrackingRate::King,
                            })
                        }
                        Err(e) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::TRACKING_RATE,
                                FieldAvailability::Error(e),
                            );
                            None
                        }
                    };

                    return Ok(MountStatus {
                        connected: true,
                        tracking,
                        slewing,
                        parked,
                        at_home: at_home_opt,
                        side_of_pier: side_of_pier_opt,
                        right_ascension: ra,
                        declination: dec,
                        altitude: alt_opt,
                        azimuth: az_opt,
                        sidereal_time: sidereal_time_opt,
                        tracking_rate: tracking_rate_opt,
                        can_park,
                        can_slew,
                        can_sync,
                        can_pulse_guide,
                        can_set_tracking_rate,
                        availability,
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    "Alpaca mount not connected",
                ))
            }
            DriverType::Indi => {
                let (host, port, device_name) = Self::parse_indi_device_id(device_id)?;
                let server_key = format!("{}:{}", host, port);
                let clients = self.indi_clients.read().await;
                if let Some(client) = clients.get(&server_key) {
                    let mount = skotiq_indi::IndiMount::new(client.clone(), &device_name);
                    let (ra, dec) = mount.get_coordinates().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to read INDI mount coordinates for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let tracking = mount.try_is_tracking().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to read INDI mount tracking for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;
                    let slewing = mount.try_is_slewing().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!("Failed to read INDI mount slewing for {}: {}", device_id, e),
                        )
                    })?;
                    let parked = mount.try_is_parked().await.map_err(|e| {
                        DeviceOpError::hardware(
                            Some(device_id.to_string()),
                            format!(
                                "Failed to read INDI mount parked state for {}: {}",
                                device_id, e
                            ),
                        )
                    })?;

                    let mut availability = Self::mount_status_availability_map();

                    let (alt_opt, az_opt) = match mount.get_horizontal_coordinates().await {
                        Ok((a, z)) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::ALTITUDE,
                                FieldAvailability::Available,
                            );
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::AZIMUTH,
                                FieldAvailability::Available,
                            );
                            (Some(a), Some(z))
                        }
                        Err(e) => {
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::ALTITUDE,
                                FieldAvailability::Error(e.clone()),
                            );
                            Self::set_mount_availability(
                                &mut availability,
                                mount_status_field::AZIMUTH,
                                FieldAvailability::Error(e),
                            );
                            (None, None)
                        }
                    };
                    let side_of_pier_opt = mount
                        .get_pier_side()
                        .await
                        .map(|side| Self::pier_side_from_indi_element(&side));

                    let locked = client.read().await;
                    let (can_park, can_slew, can_sync, can_pulse_guide) = {
                        let can_park = locked
                            .get_switch(&device_name, "TELESCOPE_PARK", "PARK")
                            .await
                            .is_some()
                            || locked
                                .get_switch(&device_name, "TELESCOPE_PARK", "UNPARK")
                                .await
                                .is_some();
                        let can_slew = locked
                            .get_switch(&device_name, "ON_COORD_SET", "SLEW")
                            .await
                            .is_some();
                        let can_sync = locked
                            .get_switch(&device_name, "ON_COORD_SET", "SYNC")
                            .await
                            .is_some();
                        let can_pulse_guide = locked
                            .get_number(&device_name, "TELESCOPE_TIMED_GUIDE_NS", "TIMED_GUIDE_N")
                            .await
                            .is_some()
                            || locked
                                .get_number(
                                    &device_name,
                                    "TELESCOPE_TIMED_GUIDE_WE",
                                    "TIMED_GUIDE_E",
                                )
                                .await
                                .is_some();
                        (can_park, can_slew, can_sync, can_pulse_guide)
                    };
                    let (tracking_rate_native, can_set_tracking_rate) =
                        Self::indi_mount_tracking_rate(&locked, &device_name).await;
                    let tracking_rate_opt = if can_set_tracking_rate {
                        Self::set_mount_availability(
                            &mut availability,
                            mount_status_field::TRACKING_RATE,
                            FieldAvailability::Available,
                        );
                        Some(tracking_rate_native)
                    } else {
                        // INDI helper currently signals "no tracking-rate property" by
                        // returning false for the second tuple element; treat that as
                        // Unsupported rather than asserting Sidereal.
                        Self::set_mount_availability(
                            &mut availability,
                            mount_status_field::TRACKING_RATE,
                            FieldAvailability::Unsupported,
                        );
                        None
                    };

                    // INDI does not standardise an at-home property, and TIME_LST is
                    // optional — record both as Unsupported until per-driver support
                    // can be added.
                    Self::set_mount_availability(
                        &mut availability,
                        mount_status_field::AT_HOME,
                        FieldAvailability::Unsupported,
                    );
                    Self::set_mount_availability(
                        &mut availability,
                        mount_status_field::SIDEREAL_TIME,
                        FieldAvailability::Unsupported,
                    );
                    Self::set_mount_availability(
                        &mut availability,
                        mount_status_field::SIDE_OF_PIER,
                        if side_of_pier_opt.is_some() {
                            FieldAvailability::Available
                        } else {
                            FieldAvailability::Unsupported
                        },
                    );

                    return Ok(MountStatus {
                        connected: true,
                        tracking,
                        slewing,
                        parked,
                        at_home: None,
                        side_of_pier: side_of_pier_opt,
                        right_ascension: ra,
                        declination: dec,
                        altitude: alt_opt,
                        azimuth: az_opt,
                        sidereal_time: None,
                        tracking_rate: tracking_rate_opt,
                        can_park,
                        can_slew,
                        can_sync,
                        can_pulse_guide,
                        can_set_tracking_rate,
                        availability,
                    });
                }
                Err(DeviceOpError::not_connected(
                    Some(device_id.to_string()),
                    format!("INDI client not connected for {}", server_key),
                ))
            }
            DriverType::Simulator => crate::device_manager::ops::sim_gate::read_mount_status()
                .await
                .map_err(DeviceOpError::driver),
        }
    }

    fn mount_status_availability_map() -> HashMap<String, FieldAvailability> {
        HashMap::with_capacity(6)
    }

    fn set_mount_availability(
        availability: &mut HashMap<String, FieldAvailability>,
        field: &'static str,
        value: FieldAvailability,
    ) {
        availability.insert(field.to_owned(), value);
    }

    /// Convert a `Result<T, NativeError>` into `(Option<T>, FieldAvailability)`,
    /// inserting the availability entry under `field` and returning the value.
    ///
    /// Used by `mount_get_status` so each per-field branch shrinks to one call
    /// instead of duplicating the same availability/log scaffolding.
    fn availability_from_native_result<T>(
        result: Result<T, skotiq_native::traits::NativeError>,
        field: &'static str,
        availability: &mut HashMap<String, FieldAvailability>,
    ) -> Option<T> {
        match result {
            Ok(v) => {
                Self::set_mount_availability(availability, field, FieldAvailability::Available);
                Some(v)
            }
            Err(skotiq_native::traits::NativeError::NotSupported) => {
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
    fn availability_from_string_result<T>(
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

    fn pier_side_from_native(side: skotiq_native::traits::PierSide) -> crate::device::PierSide {
        match side {
            skotiq_native::traits::PierSide::East => crate::device::PierSide::East,
            skotiq_native::traits::PierSide::West => crate::device::PierSide::West,
            skotiq_native::traits::PierSide::Unknown => crate::device::PierSide::Unknown,
        }
    }

    fn pier_side_from_indi_element(element: &str) -> crate::device::PierSide {
        let upper = element.to_ascii_uppercase();
        if upper.contains("EAST") || upper.ends_with("_E") || upper == "PIER_E" {
            crate::device::PierSide::East
        } else if upper.contains("WEST") || upper.ends_with("_W") || upper == "PIER_W" {
            crate::device::PierSide::West
        } else {
            crate::device::PierSide::Unknown
        }
    }

    fn tracking_rate_from_native(rate: skotiq_native::traits::TrackingRate) -> TrackingRate {
        match rate {
            skotiq_native::traits::TrackingRate::Sidereal => TrackingRate::Sidereal,
            skotiq_native::traits::TrackingRate::Lunar => TrackingRate::Lunar,
            skotiq_native::traits::TrackingRate::Solar => TrackingRate::Solar,
            skotiq_native::traits::TrackingRate::King => TrackingRate::King,
            skotiq_native::traits::TrackingRate::Custom => TrackingRate::Custom,
        }
    }
}
