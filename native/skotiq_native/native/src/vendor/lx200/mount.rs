//! `Lx200Mount` state, inherent helpers and `DeviceDriver`.

use super::*;

pub struct Lx200Mount {
    pub(crate) device_id: String,
    pub(crate) name: String,
    pub(crate) port_name: String,
    pub(crate) baud_rate: u32,
    pub(crate) mount_type: Lx200MountType,
    pub(crate) link: SerialLink,
    pub(crate) connected: Mutex<bool>,
    pub(crate) is_tracking: Mutex<bool>,
    pub(crate) is_slewing: Mutex<bool>,
    pub(crate) tracking_rate: Mutex<TrackingRate>,
    pub(crate) product_name: Mutex<String>,
    /// The coordinate format the mount was found in at connect, which is the
    /// one it takes goto and sync targets in.
    pub(crate) precision: Mutex<CoordinatePrecision>,
    /// In-memory mirror of the persisted park flag. `None` = no canonical
    /// record exists for this device yet; we return `NotSupported` on
    /// is_parked queries until park/unpark has been called at least once
    /// or telemetry confirms a state.
    pub(crate) park_state: Mutex<Option<bool>>,
    /// Cancellation channel for the standard-LX200 pulse-guide sleep.
    /// Notified by `abort_slew` so the start/stop pair
    /// terminates immediately instead of waiting out the full duration.
    pub(crate) pulse_guide_cancel: Arc<Notify>,
}

impl std::fmt::Debug for Lx200Mount {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Lx200Mount")
            .field("device_id", &self.device_id)
            .field("name", &self.name)
            .finish()
    }
}

impl Lx200Mount {
    pub fn new(port: String, mount_type: Lx200MountType, baud_rate: Option<u32>) -> Self {
        let type_prefix = match &mount_type {
            Lx200MountType::Meade => "meade",
            Lx200MountType::OnStep => "onstep",
            Lx200MountType::Losmandy => "losmandy",
            Lx200MountType::TenMicron => "10micron",
            Lx200MountType::Generic => "lx200",
        };

        let device_id = format!(
            "native:{}:{}",
            type_prefix,
            serial_link::sanitize_port_name(&port)
        );
        let display_name = match &mount_type {
            Lx200MountType::Meade => "Meade LX200",
            Lx200MountType::OnStep => "OnStep Mount",
            Lx200MountType::Losmandy => "Losmandy Gemini",
            Lx200MountType::TenMicron => "10Micron",
            Lx200MountType::Generic => "LX200",
        };

        // Eagerly hydrate the local park flag from disk. A missing or
        // unreadable cache means "no canonical state yet" — is_parked()
        // will return NotSupported until park() or unpark() has run at
        // least once (or telemetry confirms a state). We log read errors
        // because silent fallbacks hide bugs.
        let park_state_initial: Option<bool> = match read_persisted_park_state(&device_id) {
            Ok(state) => state,
            Err(e) => {
                tracing::warn!(
                    "LX200 park-state cache unreadable for {}: {} (treating as unknown)",
                    device_id,
                    e
                );
                None
            }
        };

        Self {
            device_id,
            name: format!("{} ({})", display_name, port),
            port_name: port,
            baud_rate: baud_rate.unwrap_or(LX200_BAUD_RATE),
            mount_type,
            link: SerialLink::new(),
            connected: Mutex::new(false),
            is_tracking: Mutex::new(true),
            is_slewing: Mutex::new(false),
            tracking_rate: Mutex::new(TrackingRate::Sidereal),
            product_name: Mutex::new(String::new()),
            precision: Mutex::new(CoordinatePrecision::High),
            park_state: Mutex::new(park_state_initial),
            pulse_guide_cancel: Arc::new(Notify::new()),
        }
    }

    /// Create an OnStep-based mount (Pegasus NYX-101, DIY OnStep)
    pub fn new_onstep(port: String) -> Self {
        Self::new(port, Lx200MountType::OnStep, None)
    }

    pub fn new_meade(port: String) -> Self {
        Self::new(port, Lx200MountType::Meade, None)
    }

    /// Parse OnStep status response (:GU#)
    /// Returns (is_tracking, is_slewing, is_parked, is_homed, pier_side)
    pub(crate) fn parse_onstep_status(&self, status: &str) -> (bool, bool, bool, bool, PierSide) {
        parse_onstep_status_fields(status)
    }

    /// Every command starts from an empty input buffer. Firmware answers
    /// some commands this driver does not read (OnStep's `1` after a park, a
    /// reply that arrived after its command timed out), and left in the
    /// buffer that byte becomes the first byte of the next reply: `:GU#` then
    /// read a parked mount as unparked, and `:GR#` an RA of 105 hours.
    pub(crate) fn send_command(&self, command: &str) -> Result<String, DriverError> {
        self.link.exchange(|io| {
            io.discard_input()?;
            io.send(command.as_bytes())?;
            io.read_reply(&REPLY)
        })
    }

    pub(crate) fn send_command_bool(&self, command: &str) -> Result<bool, DriverError> {
        let answer = self.link.exchange(|io| {
            io.discard_input()?;
            io.send(command.as_bytes())?;
            io.read_reply_byte(&BOOL_REPLY)
        })?;
        Ok(answer == b'1')
    }

    pub(crate) fn precision(&self) -> CoordinatePrecision {
        *self.precision.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Writes a goto or sync target in the format the mount takes.
    pub(crate) fn set_target(&self, ra_hours: f64, dec_degrees: f64) -> Result<(), DriverError> {
        let precision = self.precision();
        let ra_cmd = format!(
            "{}{}#",
            commands::SET_TARGET_RA,
            format_ra(ra_hours, precision)
        );
        if !self.send_command_bool(&ra_cmd)? {
            return Err(DriverError::SdkError(format!(
                "Mount refused the target RA {}",
                format_ra(ra_hours, precision)
            )));
        }
        let dec_cmd = format!(
            "{}{}#",
            commands::SET_TARGET_DEC,
            format_dec(dec_degrees, precision)
        );
        if !self.send_command_bool(&dec_cmd)? {
            return Err(DriverError::SdkError(format!(
                "Mount refused the target Dec {}",
                format_dec(dec_degrees, precision)
            )));
        }
        Ok(())
    }

    /// Finds the coordinate format from a `:GR#` reply and asks a mount in
    /// low precision for high precision, as INDI does on connect. A mount
    /// that stays in low precision is given its targets in low precision.
    fn settle_precision(&self, ra_reply: &str) -> Result<(), DriverError> {
        let mut precision = CoordinatePrecision::of_ra_reply(ra_reply);
        if precision == CoordinatePrecision::Low {
            self.send_command_no_response(commands::TOGGLE_PRECISION)?;
            precision = CoordinatePrecision::of_ra_reply(&self.send_command(commands::GET_RA)?);
        }
        if precision == CoordinatePrecision::Low {
            tracing::info!(
                "LX200 {}: the mount stays in low precision; targets go out as HH:MM.T and sDD*MM",
                self.device_id
            );
        }
        *self.precision.lock().unwrap_or_else(|e| e.into_inner()) = precision;
        Ok(())
    }

    /// Issue `:MS#` and read the goto acknowledgement.
    ///
    /// Deliberately not `send_command`: that reader returns only on `#`, and an
    /// accepted goto answers with a bare `0` and never sends one. Every
    /// successful slew therefore blocked for the full 5 s deadline and surfaced
    /// as `Timeout` while the mount was already moving — which is what the
    /// polar-alignment run reported as "failed to rotate to point 2".
    pub(crate) fn send_slew_command(&self) -> Result<SlewAck, DriverError> {
        self.link.exchange(|io| {
            io.discard_input()?;
            io.send(commands::SLEW_TO_TARGET.as_bytes())?;
            let code = io.read_reply_byte(&SLEW_ACK_REPLY)?;

            if code == b'0' {
                return Ok(SlewAck::Accepted);
            }

            // Refused. The reason text arrives back-to-back with the code and
            // ends in `#`; firmwares that send the bare code instead stop the
            // read at the port's own timeout rather than at the goto deadline.
            let mut tail = io.read_trailing(RESPONSE_TERM, 1, SLEW_REFUSAL_TAIL)?;
            tail.retain(|byte| !is_inter_response_framing(*byte));

            Ok(parse_slew_ack(code, &tail))
        })
    }

    /// Discard whatever the mount volunteers after `:SC#`.
    ///
    /// Meade firmware answers the date with `1` and then TWO `#`-terminated
    /// strings ("Updating planetary data..."). Those bytes sit in the buffer
    /// and would be read as the reply to whatever command runs next, so the
    /// damage from skipping this lands somewhere else entirely. OnStep sends
    /// nothing extra, and the short read timeout makes that case cheap.
    pub(crate) fn drain_calendar_chatter(&self) {
        // Best effort: a port that fails here fails the next command, which
        // reports it.
        let _ = self
            .link
            .exchange(|io| io.read_trailing(RESPONSE_TERM, 2, CALENDAR_CHATTER_WINDOW));
    }

    pub(crate) fn send_command_no_response(&self, command: &str) -> Result<(), DriverError> {
        self.link.exchange(|io| {
            io.discard_input()?;
            io.send(command.as_bytes())
        })
    }
}

fn is_inter_response_framing(byte: u8) -> bool {
    INTER_RESPONSE_FRAMING.contains(&byte)
}

/// Windows reports an exclusively-held serial port as "Access is denied",
/// which reads like a permissions problem. Spell out the likely culprit —
/// Pegasus Unity or an ASCOM driver already holding the port.
fn serial_open_error_message(port_name: &str, error_message: &str) -> String {
    if serial_link::is_busy_message(error_message) {
        format!(
            "Serial port {} is already open in another application (Pegasus Unity or an ASCOM driver?). Close it there, or connect this mount through ASCOM instead.",
            port_name
        )
    } else {
        format!("Failed to open serial port: {}", error_message)
    }
}

#[async_trait]
impl DeviceDriver for Lx200Mount {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> Vendor {
        self.mount_type.vendor()
    }

    fn is_connected(&self) -> bool {
        *self.connected.lock().unwrap_or_else(|e| e.into_inner())
    }

    async fn connect(&mut self) -> Result<(), DriverError> {
        if self.is_connected() {
            return Ok(());
        }

        let _serial_access = serial_link::serial_mount_access().await;

        let serial = serial_link::open_port(&self.port_name, self.baud_rate).map_err(|e| {
            DriverError::SdkError(serial_open_error_message(&self.port_name, &e.to_string()))
        })?;

        self.link.attach(serial)?;

        if let Ok(name) = self.send_command(commands::GET_PRODUCT_NAME) {
            *self
                .product_name
                .lock()
                .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = name.clone();
            self.name = format!("{} ({})", name, self.port_name);
        }

        // A mount that answers no product name must at least answer `:GR#`,
        // or it is not talking to us. Either way the port is released on
        // failure: `connected` is still false, so `disconnect()` would skip
        // it and the COM port would stay held until the process restarts.
        let ra_reply = match self.send_command(commands::GET_RA) {
            Ok(reply) => reply,
            Err(e) => {
                let _ = self.link.detach();
                return Err(e);
            }
        };
        if let Err(e) = self.settle_precision(&ra_reply) {
            let _ = self.link.detach();
            return Err(e);
        }

        *self
            .connected
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = true;
        *self
            .is_tracking
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = true;

        tracing::info!("Connected to LX200 mount: {}", self.name);

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), DriverError> {
        if !self.is_connected() {
            return Ok(());
        }

        // Halt any motion before we drop the port. The port is released either way —
        // holding it open would strand the mount — but a mount that did not take the
        // halt keeps slewing with nothing left connected to stop it, so the failure
        // is reported instead of dropped.
        if let Err(e) = self.send_command_no_response(commands::STOP_SLEW) {
            tracing::error!(
                "LX200 {}: stop-slew ({}) failed while disconnecting: {}. The mount may still be moving — stop it at the hand controller.",
                self.device_id,
                commands::STOP_SLEW,
                e
            );
        }

        self.link.detach()?;
        *self
            .connected
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))? = false;

        tracing::info!("Disconnected from LX200 mount");

        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::{is_inter_response_framing, serial_open_error_message};

    #[test]
    fn nyx_crlf_between_responses_is_framing() {
        assert!(is_inter_response_framing(b'\r'));
        assert!(is_inter_response_framing(b'\n'));
        assert!(is_inter_response_framing(b'\0'));
        assert!(!is_inter_response_framing(b'1'));
        assert!(!is_inter_response_framing(b'+'));
    }

    #[test]
    fn access_denied_open_error_names_the_port_holder() {
        for raw in [
            "Access is denied.",
            "Access is denied. (os error 5)",
            "Permission denied (os error 13)",
        ] {
            let msg = serial_open_error_message("COM4", raw);
            assert!(
                msg.contains("COM4 is already open in another application"),
                "access-denied variant {raw:?} must map to the held-port message, got {msg:?}"
            );
            assert!(msg.contains("through ASCOM instead"));
        }
    }

    #[test]
    fn other_open_errors_keep_the_generic_message() {
        let msg = serial_open_error_message("COM4", "The device does not recognize the command.");
        assert_eq!(
            msg,
            "Failed to open serial port: The device does not recognize the command."
        );
    }
}
