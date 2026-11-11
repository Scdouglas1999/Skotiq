//! `Lx200Mount` state, inherent helpers and `NativeDevice`.

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

    pub(crate) fn send_command(&self, command: &str) -> Result<String, NativeError> {
        self.link.command(command.as_bytes(), &REPLY)
    }

    pub(crate) fn send_command_bool(&self, command: &str) -> Result<bool, NativeError> {
        let answer = self.link.command_byte(command.as_bytes(), &BOOL_REPLY)?;
        Ok(answer == b'1')
    }

    /// Issue `:MS#` and read the goto acknowledgement.
    ///
    /// Deliberately not `send_command`: that reader returns only on `#`, and an
    /// accepted goto answers with a bare `0` and never sends one. Every
    /// successful slew therefore blocked for the full 5 s deadline and surfaced
    /// as `Timeout` while the mount was already moving — which is what the
    /// polar-alignment run reported as "failed to rotate to point 2".
    pub(crate) fn send_slew_command(&self) -> Result<SlewAck, NativeError> {
        self.link.exchange(|io| {
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

    pub(crate) fn send_command_no_response(&self, command: &str) -> Result<(), NativeError> {
        self.link.command_no_reply(command.as_bytes())
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
impl NativeDevice for Lx200Mount {
    fn id(&self) -> &str {
        &self.device_id
    }

    fn name(&self) -> &str {
        &self.name
    }

    fn vendor(&self) -> NativeVendor {
        self.mount_type.vendor()
    }

    fn is_connected(&self) -> bool {
        *self.connected.lock().unwrap_or_else(|e| e.into_inner())
    }

    async fn connect(&mut self) -> Result<(), NativeError> {
        if self.is_connected() {
            return Ok(());
        }

        let _serial_access = serial_link::serial_mount_access().await;

        let serial = serial_link::open_port(&self.port_name, self.baud_rate).map_err(|e| {
            NativeError::SdkError(serial_open_error_message(&self.port_name, &e.to_string()))
        })?;

        self.link.attach(serial)?;

        match self.send_command(commands::GET_PRODUCT_NAME) {
            Ok(name) => {
                *self
                    .product_name
                    .lock()
                    .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = name.clone();
                self.name = format!("{} ({})", name, self.port_name);
            }
            Err(_) => {
                // Fall back to a :GR# probe. If that ALSO times out the mount
                // isn't really talking to us, so bail — but first release the
                // serial port we opened above. Otherwise the live handle lingers
                // in `self.serial_port` with `connected` still false, so a later
                // `disconnect()` no-ops (it early-returns on `!is_connected()`),
                // leaking the COM port and locking out every subsequent connect
                // attempt (native OR ASCOM) until the process restarts.
                if let Err(e) = self.send_command(commands::GET_RA) {
                    let _ = self.link.detach();
                    return Err(e);
                }
            }
        }

        *self
            .connected
            .lock()
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = true;
        *self
            .is_tracking
            .lock()
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = true;

        tracing::info!("Connected to LX200 mount: {}", self.name);

        Ok(())
    }

    async fn disconnect(&mut self) -> Result<(), NativeError> {
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
            .map_err(|_| NativeError::SdkError("Lock poisoned".into()))? = false;

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
