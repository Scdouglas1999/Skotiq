//! `NativeMount` implementation for `Lx200Mount`.

use super::*;

#[async_trait]
impl NativeMount for Lx200Mount {
    async fn slew_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        tracing::info!("Slewing to RA={:.4}h, Dec={:.4}°", ra_hours, dec_degrees);

        let ra_cmd = format!("{}{}#", commands::SET_TARGET_RA, format_ra(ra_hours));
        if !self.send_command_bool(&ra_cmd)? {
            return Err(NativeError::SdkError("Failed to set RA target".into()));
        }

        let dec_cmd = format!("{}{}#", commands::SET_TARGET_DEC, format_dec(dec_degrees));
        if !self.send_command_bool(&dec_cmd)? {
            return Err(NativeError::SdkError("Failed to set Dec target".into()));
        }

        if let SlewAck::Refused { code, message } = self.send_slew_command()? {
            return Err(NativeError::SdkError(slew_refusal_message(code, &message)));
        }

        *self
            .is_slewing
            .lock()
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = true;

        Ok(())
    }

    async fn get_coordinates(&self) -> Result<(f64, f64), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        let ra_response = self.send_command(commands::GET_RA)?;
        let dec_response = self.send_command(commands::GET_DEC)?;

        let ra = parse_ra(&ra_response)?;
        let dec = parse_dec(&dec_response)?;

        Ok((ra, dec))
    }

    async fn sync_to_coordinates(
        &mut self,
        ra_hours: f64,
        dec_degrees: f64,
    ) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        tracing::info!("Syncing to RA={:.4}h, Dec={:.4}°", ra_hours, dec_degrees);

        // `:CM#` syncs to whatever target the mount holds. If it refused the
        // new one, that is the previous goto's, so syncing anyway moves the
        // mount's idea of where it points to the wrong place and says it
        // worked.
        let ra_cmd = format!("{}{}#", commands::SET_TARGET_RA, format_ra(ra_hours));
        if !self.send_command_bool(&ra_cmd)? {
            return Err(NativeError::SdkError("Mount refused the sync RA".into()));
        }

        let dec_cmd = format!("{}{}#", commands::SET_TARGET_DEC, format_dec(dec_degrees));
        if !self.send_command_bool(&dec_cmd)? {
            return Err(NativeError::SdkError("Mount refused the sync Dec".into()));
        }

        let _ = self.send_command(commands::SYNC)?;

        Ok(())
    }

    async fn park(&mut self) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
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
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = Some(true);
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

    async fn unpark(&mut self) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        tracing::info!("Unparking mount");

        // OnStep uses :hR# for unpark, standard LX200 uses :PO#
        if self.mount_type.is_onstep() {
            self.send_command_no_response(commands::ONSTEP_UNPARK)?;
        } else {
            self.send_command_no_response(commands::UNPARK_MEADE)?;
        }

        *self
            .park_state
            .lock()
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = Some(false);
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

    async fn is_slewing(&self) -> Result<bool, NativeError> {
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

    async fn is_parked(&self) -> Result<bool, NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
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
                .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = Some(is_parked);
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

        // 2) Meade firmware (LX200GPS / LX200ACF / RCX400) exposes park
        //    via :GW#. Older Classic firmware ignores or echoes garbage —
        //    we accept telemetry only when the response shape is one we
        //    recognise; otherwise we fall through to the persisted cache.
        if matches!(self.mount_type, Lx200MountType::Meade) {
            if let Ok(status) = self.send_command(commands::MEADE_GET_STATUS) {
                if let Some(is_parked) = parse_meade_gw_park(&status) {
                    *self
                        .park_state
                        .lock()
                        .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? =
                        Some(is_parked);
                    if let Err(e) = write_persisted_park_state(&self.device_id, is_parked) {
                        tracing::warn!(
                            "Persist Meade park telemetry failed for {}: {}",
                            self.device_id,
                            e
                        );
                    }
                    return Ok(is_parked);
                }
                tracing::debug!(
                    "Meade :GW# response {:?} did not encode park state — falling back to local cache",
                    status
                );
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
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))?;
        match cached {
            Some(parked) => Ok(parked),
            None => Err(NativeError::NotSupported),
        }
    }

    async fn pulse_guide(
        &mut self,
        direction: GuideDirection,
        duration_ms: u32,
    ) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
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

        let cancelled = self.pulse_guide_wait(duration_ms).await;

        let stop_result = self.send_command_no_response(stop_cmd);

        if cancelled {
            tracing::info!(
                "LX200 pulse_guide cancelled mid-sleep; stop {} sent immediately",
                stop_cmd
            );
        }

        stop_result
    }

    async fn abort_slew(&mut self) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
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
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = false;

        Ok(())
    }

    async fn set_tracking(&mut self, enabled: bool) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        // OnStep uses :Te# (enable) and :Td# (disable)
        if self.mount_type.is_onstep() {
            if enabled {
                self.send_command_no_response(commands::ONSTEP_TRACK_ENABLE)?;
            } else {
                self.send_command_no_response(commands::ONSTEP_TRACK_DISABLE)?;
            }
        } else {
            // Standard LX200
            if enabled {
                self.send_command_no_response(commands::SET_TRACK_SIDEREAL)?;
            } else {
                // Standard LX200 doesn't have explicit tracking disable
                // Using stop slew as workaround (not ideal)
                self.send_command_no_response(commands::STOP_SLEW)?;
            }
        }

        *self
            .is_tracking
            .lock()
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = enabled;
        tracing::info!("Tracking {}", if enabled { "enabled" } else { "disabled" });

        Ok(())
    }

    async fn get_tracking(&self) -> Result<bool, NativeError> {
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

    async fn get_side_of_pier(&self) -> Result<PierSide, NativeError> {
        if !self.is_connected() {
            return Ok(PierSide::Unknown);
        }

        // OnStep can query pier side
        if self.mount_type.is_onstep() {
            if let Ok(status) = self.send_command(commands::ONSTEP_GET_STATUS) {
                let (_, _, _, _, pier_side) = self.parse_onstep_status(&status);
                return Ok(pier_side);
            }
        }

        Ok(PierSide::Unknown)
    }

    async fn get_alt_az(&self) -> Result<(f64, f64), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        let alt_response = self.send_command(commands::GET_ALT)?;
        let az_response = self.send_command(commands::GET_AZ)?;

        let alt = parse_dec(&alt_response)?;
        let az = parse_dec(&az_response)?;

        Ok((alt, az.abs()))
    }

    async fn get_site(&self) -> Result<MountSiteInfo, NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        let latitude_deg = parse_dms(&self.send_command(commands::GET_SITE_LATITUDE)?)?;
        let longitude_wire = parse_dms(&self.send_command(commands::GET_SITE_LONGITUDE)?)?;

        if !(-90.0..=90.0).contains(&latitude_deg) {
            return Err(NativeError::SdkError(format!(
                "Mount reported latitude {} outside -90..90",
                latitude_deg
            )));
        }
        let longitude_deg = lx200_longitude_to_east_positive(longitude_wire);
        if !(-180.0..=180.0).contains(&longitude_deg) {
            return Err(NativeError::SdkError(format!(
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

    async fn set_site(&mut self, site: MountSiteInfo) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }
        if !(-90.0..=90.0).contains(&site.latitude_deg)
            || !(-180.0..=180.0).contains(&site.longitude_deg)
        {
            return Err(NativeError::SdkError(format!(
                "Refusing to write site {:.4},{:.4} to the mount: out of range",
                site.latitude_deg, site.longitude_deg
            )));
        }

        // Seconds precision only where the firmware is known to take it.
        // Classic LX200 parses `sDD*MM` and rejects the longer form.
        let with_seconds = self.mount_type.is_onstep();

        let lat = format_dms(site.latitude_deg, 2, with_seconds);
        let lon = format_dms(
            east_positive_to_lx200_longitude(site.longitude_deg),
            3,
            with_seconds,
        );
        tracing::info!(
            "Writing site to mount: lat {} lon {} (east-positive {:.4})",
            lat,
            lon,
            site.longitude_deg
        );

        if !self.send_command_bool(&format!("{}{}#", commands::SET_SITE_LATITUDE, lat))? {
            return Err(NativeError::SdkError(
                "Mount rejected the site latitude".into(),
            ));
        }
        if !self.send_command_bool(&format!("{}{}#", commands::SET_SITE_LONGITUDE, lon))? {
            return Err(NativeError::SdkError(
                "Mount rejected the site longitude".into(),
            ));
        }

        Ok(())
    }

    async fn get_clock(&self) -> Result<MountClock, NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
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

    async fn set_clock(&mut self, clock: MountClock) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        let (date_text, time_text) =
            format_mount_local_datetime(clock.utc_unix_seconds, clock.utc_offset_hours)?;
        let offset_text = format_utc_offset(clock.utc_offset_hours);

        tracing::info!(
            "Writing clock to mount: {} {} UTC offset {}",
            date_text,
            time_text,
            offset_text
        );

        // Offset first: the mount interprets the local time it is about to be
        // given against whatever offset it currently holds.
        if !self.send_command_bool(&format!("{}{}#", commands::SET_UTC_OFFSET, offset_text))? {
            return Err(NativeError::SdkError(
                "Mount rejected the UTC offset".into(),
            ));
        }
        if !self.send_command_bool(&format!("{}{}#", commands::SET_LOCAL_TIME, time_text))? {
            return Err(NativeError::SdkError(
                "Mount rejected the local time".into(),
            ));
        }
        // `:SC#` answers `1` and THEN, on Meade firmware, two `#`-terminated
        // strings ("Updating planetary data..."). Drain them so the next
        // command does not read them as its own reply.
        if !self.send_command_bool(&format!("{}{}#", commands::SET_CALENDAR_DATE, date_text))? {
            return Err(NativeError::SdkError("Mount rejected the date".into()));
        }
        self.drain_calendar_chatter();

        Ok(())
    }

    async fn find_home(&mut self) -> Result<(), NativeError> {
        // `:hF#` is an OnStep extension. Classic Meade/Losmandy firmware has no
        // home command, and sending one blind would either be ignored or
        // interpreted as something else entirely, so those report NotSupported
        // rather than pretending. Checked BEFORE the connection: a protocol
        // without a home command does not acquire one by connecting, and
        // answering NotConnected first would imply that it might.
        if !self.mount_type.is_onstep() {
            return Err(NativeError::NotSupported);
        }

        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        tracing::info!("Finding home");
        self.send_command_no_response(commands::ONSTEP_FIND_HOME)?;

        // Homing is a slew: mark it so callers that poll `is_slewing` wait for
        // the motion instead of reading the mount as idle the instant the
        // command is acknowledged.
        *self
            .is_slewing
            .lock()
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = true;

        Ok(())
    }

    async fn at_home(&self) -> Result<bool, NativeError> {
        if !self.mount_type.is_onstep() {
            return Err(NativeError::NotSupported);
        }

        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        // `:GU#` already carries the home flag and the parser already reads it;
        // it simply had no consumer, which is why mount status reported
        // at-home as unsupported on a mount that knows the answer.
        let status = self.send_command(commands::ONSTEP_GET_STATUS)?;
        let (_, _, _, is_homed, _) = self.parse_onstep_status(&status);
        Ok(is_homed)
    }

    async fn get_sidereal_time(&self) -> Result<f64, NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
        }

        let response = self.send_command(commands::GET_SIDEREAL_TIME)?;
        parse_ra(&response)
    }

    async fn set_tracking_rate(&mut self, rate: TrackingRate) -> Result<(), NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
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
                    return Err(NativeError::NotSupported);
                }
            }
            TrackingRate::Custom => {
                return Err(NativeError::NotSupported);
            }
        };

        self.send_command_no_response(cmd)?;
        *self
            .tracking_rate
            .lock()
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = rate;
        tracing::info!("Set tracking rate to {:?}", rate);

        Ok(())
    }

    async fn get_tracking_rate(&self) -> Result<TrackingRate, NativeError> {
        if !self.is_connected() {
            return Err(NativeError::NotConnected);
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
}
