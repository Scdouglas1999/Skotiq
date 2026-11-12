//! `MountDriver` implementation for `Lx200Mount`.

use super::*;

#[async_trait]
impl MountDriver for Lx200Mount {
    async fn slew_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Slewing to RA={:.4}h, Dec={:.4}°", ra_hours, dec_degrees);

        self.set_target(ra_hours, dec_degrees)?;

        if let SlewAck::Refused { code, message } = self.send_slew_command()? {
            return Err(DriverError::SdkError(slew_refusal_message(
                &self.mount_type,
                code,
                &message,
            )));
        }

        *self
            .is_slewing
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = true;

        Ok(())
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let ra_response = self.send_command(commands::GET_RA)?;
        let dec_response = self.send_command(commands::GET_DEC)?;

        let ra = parse_sexagesimal(&ra_response)?;
        let dec = parse_sexagesimal(&dec_response)?;

        Ok((ra, dec))
    }

    async fn sync_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Syncing to RA={:.4}h, Dec={:.4}°", ra_hours, dec_degrees);

        // `:CM#` syncs to whatever target the mount holds. If it refused the
        // new one, that is the previous goto's, so syncing anyway moves the
        // mount's idea of where it points to the wrong place and says it
        // worked.
        self.set_target(ra_hours, dec_degrees)?;

        // Meade answers the name of the object it synced on, OnStep `N/A`;
        // 10Micron says `Match fail: dist. too large` when it refuses.
        let reply = self.send_command(commands::SYNC)?;
        if reply.trim_start().starts_with("Match fail") {
            return Err(DriverError::SdkError(format!(
                "Mount refused the sync: {}",
                reply.trim()
            )));
        }

        Ok(())
    }

    async fn park(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Parking mount");
        self.send_command_no_response(commands::PARK)?;

        // Snapshot the canonical state. For OnStep / Meade this will be
        // re-confirmed on the next is_parked() telemetry round-trip; for
        // mounts without telemetry this is the only authoritative source
        // of truth across an app restart.
        *self
            .park_state
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = Some(true);
        if let Err(e) = write_persisted_park_state(&self.device_id, true) {
            // Persistence failure must not silently mask a real park — log
            // loudly and propagate so the operator knows the cache is broken.
            tracing::error!(
                "Failed to persist LX200 park state for {}: {}",
                self.device_id,
                e
            );
            return Err(e);
        }

        Ok(())
    }

    async fn unpark(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Unparking mount");

        self.send_command_no_response(self.mount_type.unpark_command())?;

        *self
            .park_state
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = Some(false);
        if let Err(e) = write_persisted_park_state(&self.device_id, false) {
            tracing::error!(
                "Failed to persist LX200 unpark state for {}: {}",
                self.device_id,
                e
            );
            return Err(e);
        }

        Ok(())
    }

    async fn is_slewing(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Ok(false);
        }

        // OnStep can query actual status
        if self.mount_type.is_onstep() {
            if let Ok(status) = self.send_command(commands::ONSTEP_GET_STATUS) {
                let (_, is_slewing, _, _, _) = self.parse_onstep_status(&status);
                *self.is_slewing.lock().unwrap_or_else(|e| e.into_inner()) = is_slewing;
                return Ok(is_slewing);
            }
        }

        // Every other LX200 flavour: ask the distance bar while a goto is
        // latched. Without it the latch was only ever cleared by an abort, so
        // a Meade, Losmandy or 10Micron mount read as slewing forever after its
        // first goto and every sequencer slew waited out its limit and failed.
        // A mount that does not answer keeps the latched value, as before.
        let latched = *self.is_slewing.lock().unwrap_or_else(|e| e.into_inner());
        if latched && !self.mount_type.is_onstep() {
            if let Ok(bars) = self.send_command(commands::DISTANCE_BARS) {
                let is_slewing = !bars.trim().is_empty();
                *self.is_slewing.lock().unwrap_or_else(|e| e.into_inner()) = is_slewing;
                return Ok(is_slewing);
            }
        }

        Ok(latched)
    }

    async fn is_parked(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        // 1) OnStep exposes parked-ness directly via :GU#. Trust telemetry,
        //    refresh the local cache, and persist so cross-restart state
        //    survives. A serial error here propagates — we will not lie
        //    about park state to the sequencer.
        if self.mount_type.is_onstep() {
            let status = self.send_command(commands::ONSTEP_GET_STATUS)?;
            let (_, _, is_parked, _, _) = self.parse_onstep_status(&status);
            *self
                .park_state
                .lock()
                .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = Some(is_parked);
            // Best-effort persist: a write failure logs but does not mask
            // a successful telemetry read.
            if let Err(e) = write_persisted_park_state(&self.device_id, is_parked) {
                tracing::warn!(
                    "Persist OnStep park telemetry failed for {}: {}",
                    self.device_id,
                    e
                );
            }
            return Ok(is_parked);
        }

        // 2) Meade `:GW#` carries no park flag, only whether the mount
        //    tracks. A tracking mount is not parked; one that does not track
        //    is parked if we parked it. A mount that answers in the
        //    documented shape and was never parked by us reads unparked, as
        //    it always has. Any other answer falls through to the cache.
        if matches!(self.mount_type, Lx200MountType::Meade) {
            if let Ok(status) = self.send_command(commands::MEADE_GET_STATUS) {
                match parse_meade_gw_tracking(&status) {
                    Some(true) => {
                        *self
                            .park_state
                            .lock()
                            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? =
                            Some(false);
                        if let Err(e) = write_persisted_park_state(&self.device_id, false) {
                            tracing::warn!(
                                "Persist Meade park telemetry failed for {}: {}",
                                self.device_id,
                                e
                            );
                        }
                        return Ok(false);
                    }
                    Some(false) => {
                        let cached = *self
                            .park_state
                            .lock()
                            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))?;
                        return Ok(cached.unwrap_or(false));
                    }
                    None => tracing::debug!(
                        "Meade :GW# response {:?} is not <mount><tracking><alignment> — falling back to local cache",
                        status
                    ),
                }
            }
            // Fall through to persisted-state path on serial error or
            // unparseable response. A connection-level failure has already
            // been surfaced by send_command above on Ok-path; we only
            // suppress per-command parse mismatches here.
        }

        // 3) Losmandy / 10Micron / Generic LX200, plus any Meade firmware
        //    that did not answer :GW# usefully: the local cache (kept in
        //    sync by park()/unpark()) is the canonical source. If we have
        //    no cache entry, the state is genuinely unknown — surface it
        //    as NotSupported rather than fabricate `false`.
        let cached = *self
            .park_state
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))?;
        match cached {
            Some(parked) => Ok(parked),
            None => Err(DriverError::NotSupported),
        }
    }

    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        // OnStep has native pulse guide command: :Mgdnnnn#
        // where d = direction (n/s/e/w), nnnn = duration in ms (20-16399)
        if self.mount_type.is_onstep() {
            let dir_char = match direction {
                GuideDirection::North => 'n',
                GuideDirection::South => 's',
                GuideDirection::East => 'e',
                GuideDirection::West => 'w',
            };

            // Clamp duration to OnStep's valid range (20-16399ms)
            let clamped_ms = duration_ms.clamp(20, 16399);
            let cmd = format!(
                "{}{}{}#",
                commands::ONSTEP_PULSE_GUIDE_PREFIX,
                dir_char,
                clamped_ms
            );
            self.send_command_no_response(&cmd)?;

            return Ok(());
        }

        // Standard LX200: set guide rate, start move, wait, stop move.
        // the wait must be cancellable so abort_slew
        // terminates the pulse immediately. Notify::notified() only
        // observes notifications that fire after the future is created,
        // so building it fresh per pulse_guide call is sufficient — no
        // drain needed.
        self.send_command_no_response(commands::SET_RATE_GUIDE)?;

        let start_cmd = match direction {
            GuideDirection::North => commands::MOVE_NORTH,
            GuideDirection::South => commands::MOVE_SOUTH,
            GuideDirection::East => commands::MOVE_EAST,
            GuideDirection::West => commands::MOVE_WEST,
        };
        let stop_cmd = match direction {
            GuideDirection::North => commands::STOP_MOVE_NORTH,
            GuideDirection::South => commands::STOP_MOVE_SOUTH,
            GuideDirection::East => commands::STOP_MOVE_EAST,
            GuideDirection::West => commands::STOP_MOVE_WEST,
        };
        self.send_command_no_response(start_cmd)?;

        let cancelled = serial_link::pulse_guide_wait(
            Duration::from_millis(duration_ms as u64),
            &self.pulse_guide_cancel,
        )
        .await;

        let stop_result = self.send_command_no_response(stop_cmd);

        if cancelled {
            tracing::info!(
                "LX200 pulse_guide cancelled mid-sleep; stop {} sent immediately",
                stop_cmd
            );
        }

        stop_result
    }

    async fn abort_slew(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Aborting slew");
        // Wake any in-flight standard-LX200 pulse_guide so it stops the
        // motors immediately instead of waiting out the duration_ms timer.
        // notify_waiters wakes only currently-parked
        // futures; if no pulse is active this is a cheap no-op.
        self.pulse_guide_cancel.notify_waiters();
        self.send_command_no_response(commands::STOP_SLEW)?;
        *self
            .is_slewing
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = false;

        Ok(())
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        // Without a tracking-off command the answer is NotSupported, never a
        // stand-in such as `:Q#`: that stops slews, not tracking, and the
        // mount would track on while the app reported it stopped.
        let tracking = self
            .mount_type
            .tracking_command(enabled)
            .ok_or(DriverError::NotSupported)?;
        if tracking.answers {
            if !self.send_command_bool(tracking.command)? {
                return Err(DriverError::SdkError(format!(
                    "Mount refused to turn tracking {}",
                    if enabled { "on" } else { "off" }
                )));
            }
        } else {
            self.send_command_no_response(tracking.command)?;
        }

        *self
            .is_tracking
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = enabled;
        tracing::info!("Tracking {}", if enabled { "enabled" } else { "disabled" });

        Ok(())
    }

    async fn get_tracking(&self) -> Result<bool, DriverError> {
        if !self.is_connected() {
            return Ok(false);
        }

        // OnStep can query actual tracking status
        if self.mount_type.is_onstep() {
            if let Ok(status) = self.send_command(commands::ONSTEP_GET_STATUS) {
                let (is_tracking, _, _, _, _) = self.parse_onstep_status(&status);
                *self.is_tracking.lock().unwrap_or_else(|e| e.into_inner()) = is_tracking;
                return Ok(is_tracking);
            }
        }

        Ok(*self.is_tracking.lock().unwrap_or_else(|e| e.into_inner()))
    }

    async fn get_side_of_pier(&self) -> Result<PierSide, DriverError> {
        if !self.is_connected() {
            return Ok(PierSide::Unknown);
        }

        match self.mount_type {
            Lx200MountType::OnStep => {
                if let Ok(status) = self.send_command(commands::ONSTEP_GET_STATUS) {
                    let (_, _, _, _, pier_side) = self.parse_onstep_status(&status);
                    return Ok(pier_side);
                }
                Ok(PierSide::Unknown)
            }
            Lx200MountType::TenMicron => {
                let reply = self.send_command(commands::TENMICRON_PIER_SIDE)?;
                Ok(match reply.trim() {
                    "East" => PierSide::East,
                    "West" => PierSide::West,
                    _ => PierSide::Unknown,
                })
            }
            _ => Ok(PierSide::Unknown),
        }
    }

    async fn get_alt_az(&self) -> Result<(f64, f64), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let alt_response = self.send_command(commands::GET_ALT)?;
        let az_response = self.send_command(commands::GET_AZ)?;

        let alt = parse_sexagesimal(&alt_response)?;
        let az = parse_sexagesimal(&az_response)?;

        Ok((alt, az.abs()))
    }

    async fn get_site(&self) -> Result<MountSiteInfo, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let latitude_deg = parse_sexagesimal(&self.send_command(commands::GET_SITE_LATITUDE)?)?;
        let longitude_wire = parse_sexagesimal(&self.send_command(commands::GET_SITE_LONGITUDE)?)?;

        if !(-90.0..=90.0).contains(&latitude_deg) {
            return Err(DriverError::SdkError(format!(
                "Mount reported latitude {} outside -90..90",
                latitude_deg
            )));
        }
        let longitude_deg = lx200_longitude_to_east_positive(longitude_wire);
        if !(-180.0..=180.0).contains(&longitude_deg) {
            return Err(DriverError::SdkError(format!(
                "Mount reported longitude {} outside -180..180",
                longitude_deg
            )));
        }

        Ok(MountSiteInfo {
            latitude_deg,
            longitude_deg,
            // No LX200 command carries elevation. `None` says "not carried"
            // rather than claiming sea level.
            elevation_m: None,
        })
    }

    async fn set_site(&mut self, site: MountSiteInfo) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }
        if !(-90.0..=90.0).contains(&site.latitude_deg)
            || !(-180.0..=180.0).contains(&site.longitude_deg)
        {
            return Err(DriverError::SdkError(format!(
                "Refusing to write site {:.4},{:.4} to the mount: out of range",
                site.latitude_deg, site.longitude_deg
            )));
        }

        // Seconds only where the firmware is known to take them (OnStep, the
        // NYX-101). The Meade command set is `sDD*MM` and an unsigned
        // `DDD*MM`; 10Micron documents `:SgsDDD*MM#` with east negative
        // (protocol 2.14.11), so it gets the sign rather than 0-360.
        let (lat, lon) = match self.mount_type {
            Lx200MountType::OnStep => (
                format_dms(site.latitude_deg, 2, true),
                format_dms(
                    east_positive_to_lx200_longitude(site.longitude_deg),
                    3,
                    true,
                ),
            ),
            Lx200MountType::TenMicron => (
                format_dms(site.latitude_deg, 2, false),
                format_dms(
                    east_positive_to_lx200_longitude(site.longitude_deg),
                    3,
                    false,
                ),
            ),
            Lx200MountType::Meade | Lx200MountType::Losmandy | Lx200MountType::Generic => (
                format_dms(site.latitude_deg, 2, false),
                format_meade_longitude(site.longitude_deg),
            ),
        };
        tracing::info!(
            "Writing site to mount: lat {} lon {} (east-positive {:.4})",
            lat,
            lon,
            site.longitude_deg
        );

        if !self.send_command_bool(&format!("{}{}#", commands::SET_SITE_LATITUDE, lat))? {
            return Err(DriverError::SdkError(
                "Mount rejected the site latitude".into(),
            ));
        }
        if !self.send_command_bool(&format!("{}{}#", commands::SET_SITE_LONGITUDE, lon))? {
            return Err(DriverError::SdkError(
                "Mount rejected the site longitude".into(),
            ));
        }

        Ok(())
    }

    async fn get_clock(&self) -> Result<MountClock, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let time_text = self.send_command(commands::GET_LOCAL_TIME)?;
        let date_text = self.send_command(commands::GET_CALENDAR_DATE)?;
        let utc_offset_hours = parse_utc_offset(&self.send_command(commands::GET_UTC_OFFSET)?)?;

        let (utc_unix_seconds, _) =
            parse_mount_local_datetime(&date_text, &time_text, utc_offset_hours)?;

        Ok(MountClock {
            utc_unix_seconds,
            utc_offset_hours,
        })
    }

    async fn set_clock(&mut self, clock: MountClock) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let (date_text, time_text) =
            format_mount_local_datetime(clock.utc_unix_seconds, clock.utc_offset_hours)?;
        let offset_text = format_utc_offset(clock.utc_offset_hours, &self.mount_type);

        tracing::info!(
            "Writing clock to mount: {} {} UTC offset {}",
            date_text,
            time_text,
            offset_text
        );

        // Offset first: the mount interprets the local time it is about to be
        // given against whatever offset it currently holds.
        if !self.send_command_bool(&format!("{}{}#", commands::SET_UTC_OFFSET, offset_text))? {
            return Err(DriverError::SdkError(
                "Mount rejected the UTC offset".into(),
            ));
        }
        if !self.send_command_bool(&format!("{}{}#", commands::SET_LOCAL_TIME, time_text))? {
            return Err(DriverError::SdkError(
                "Mount rejected the local time".into(),
            ));
        }
        // `:SC#` answers `1` and THEN, on Meade firmware, two `#`-terminated
        // strings ("Updating planetary data..."). Drain them so the next
        // command does not read them as its own reply.
        if !self.send_command_bool(&format!("{}{}#", commands::SET_CALENDAR_DATE, date_text))? {
            return Err(DriverError::SdkError("Mount rejected the date".into()));
        }
        self.drain_calendar_chatter();

        Ok(())
    }

    async fn find_home(&mut self) -> Result<(), DriverError> {
        // `:hC#` is an OnStep extension. Classic Meade/Losmandy firmware has no
        // home command, and sending one blind would either be ignored or
        // interpreted as something else entirely, so those report NotSupported
        // rather than pretending. Checked BEFORE the connection: a protocol
        // without a home command does not acquire one by connecting, and
        // answering NotConnected first would imply that it might.
        if !self.mount_type.is_onstep() {
            return Err(DriverError::NotSupported);
        }

        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Finding home");
        self.send_command_no_response(commands::ONSTEP_GO_HOME)?;

        // Homing is a slew: mark it so callers that poll `is_slewing` wait for
        // the motion instead of reading the mount as idle the instant the
        // command is acknowledged.
        *self
            .is_slewing
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = true;

        Ok(())
    }

    async fn set_park(&mut self) -> Result<(), DriverError> {
        // `:hQ#` is an OnStep extension, refused on classic Meade/Losmandy for
        // the same reason as `find_home`, and checked before the connection.
        if !self.mount_type.is_onstep() {
            return Err(DriverError::NotSupported);
        }

        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        tracing::info!("Setting park position to the current position");
        if !self.send_command_bool(commands::ONSTEP_SET_PARK)? {
            return Err(DriverError::SdkError(
                "Mount refused to store the park position".into(),
            ));
        }
        Ok(())
    }

    async fn at_home(&self) -> Result<bool, DriverError> {
        if !self.mount_type.is_onstep() {
            return Err(DriverError::NotSupported);
        }

        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        // `:GU#` already carries the home flag and the parser already reads it;
        // it simply had no consumer, which is why mount status reported
        // at-home as unsupported on a mount that knows the answer.
        let status = self.send_command(commands::ONSTEP_GET_STATUS)?;
        let (_, _, _, is_homed, _) = self.parse_onstep_status(&status);
        Ok(is_homed)
    }

    async fn get_sidereal_time(&self) -> Result<f64, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        let response = self.send_command(commands::GET_SIDEREAL_TIME)?;
        parse_sexagesimal(&response)
    }

    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        // OnStep and standard LX200 use the same commands for tracking rates
        let cmd = match rate {
            TrackingRate::Sidereal => commands::SET_TRACK_SIDEREAL,
            TrackingRate::Lunar => commands::SET_TRACK_LUNAR,
            TrackingRate::Solar => commands::SET_TRACK_SOLAR,
            TrackingRate::King => {
                // King rate is only supported by OnStep
                if self.mount_type.is_onstep() {
                    commands::ONSTEP_SET_RATE_KING
                } else {
                    return Err(DriverError::NotSupported);
                }
            }
            TrackingRate::Custom => {
                return Err(DriverError::NotSupported);
            }
        };

        self.send_command_no_response(cmd)?;
        *self
            .tracking_rate
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = rate;
        tracing::info!("Set tracking rate to {:?}", rate);

        Ok(())
    }

    async fn get_tracking_rate(&self) -> Result<TrackingRate, DriverError> {
        if !self.is_connected() {
            return Err(DriverError::NotConnected);
        }

        Ok(*self.tracking_rate.lock().unwrap_or_else(|e| e.into_inner()))
    }

    fn can_slew(&self) -> bool {
        true
    }

    fn can_sync(&self) -> bool {
        true
    }

    fn can_pulse_guide(&self) -> bool {
        true
    }

    fn can_set_tracking_rate(&self) -> bool {
        true
    }

    fn can_find_home(&self) -> bool {
        // Only OnStep has a home command (`:hC#`); see `find_home`.
        self.mount_type.is_onstep()
    }

    fn can_set_park(&self) -> bool {
        // Only OnStep can store a park position (`:hQ#`); see `set_park`.
        self.mount_type.is_onstep()
    }
}
