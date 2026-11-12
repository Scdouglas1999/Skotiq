//! The serial transport shared by the Sky-Watcher, iOptron and LX200 mount
//! drivers: opening a port, exchanging commands over it, scanning the
//! machine's ports for a mount, and the cancellable pulse-guide wait.
//!
//! Each protocol passes its own framing, deadlines, baud rates and probes;
//! nothing here knows a command.

use skotiq_device::DriverError;
use std::io::{Read, Write};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};
use tokio::sync::{Mutex as AsyncMutex, MutexGuard as AsyncMutexGuard, Notify};

pub(crate) type Port = Box<dyn serialport::SerialPort>;

/// Read timeout every mount port is opened with. It bounds one `read`, so it
/// is also how long a reader waits before deciding the mount has gone quiet.
const PORT_READ_TIMEOUT: Duration = Duration::from_millis(500);

/// How long a reply may take before the command fails. Shared by the three
/// protocols; each still names it in its own [`ReplyRule`].
pub(crate) const REPLY_DEADLINE: Duration = Duration::from_secs(5);

/// Pause after closing a probed port so Windows fully releases the COM handle
/// before the next open of it.
const PORT_RELEASE_SETTLE: Duration = Duration::from_millis(50);

/// Pause after a read that returned no bytes without timing out (a port at end
/// of file), so the wait for the deadline does not spin a core.
const EMPTY_READ_PAUSE: Duration = Duration::from_millis(10);

/// The form of a port name used inside device ids, where `/` and `\` would
/// read as separators.
pub fn sanitize_port_name(port: &str) -> String {
    port.replace("/", "_").replace("\\", "_")
}

/// Coordinates short-lived attempts to claim a serial mount port.
///
/// Discovery probes and live connections otherwise race at the OS handle: a
/// discovery sweep can open COM4 between a driver's disconnect and reconnect,
/// causing the real connection to fail with `Access is denied`. The guard is
/// intentionally held only while opening/probing a port, never for the lifetime
/// of a connected mount.
static SERIAL_MOUNT_ACCESS: OnceLock<AsyncMutex<()>> = OnceLock::new();

pub(crate) async fn serial_mount_access() -> AsyncMutexGuard<'static, ()> {
    SERIAL_MOUNT_ACCESS
        .get_or_init(|| AsyncMutex::new(()))
        .lock()
        .await
}

/// Run a serial-port scan on a blocking thread.
///
/// Serial mount discovery is entirely synchronous — `serialport` open/read plus
/// the settle sleeps every protocol needs between probes — and costs roughly a
/// second per (port, baud) pair, so a four-port machine spends ~17 s inside one
/// call. Run inline it would freeze whichever Tokio worker picked it up, along
/// with every other task scheduled there.
pub(crate) async fn run_serial_scan<T, F>(vendor: &'static str, scan: F) -> Result<T, DriverError>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T, DriverError> + Send + 'static,
{
    let _serial_access = serial_mount_access().await;
    tokio::task::spawn_blocking(scan).await.unwrap_or_else(|e| {
        Err(DriverError::SdkError(format!(
            "{} mount discovery task failed: {}",
            vendor, e
        )))
    })
}

/// Why a port could not be opened, as the OS worded it.
#[derive(Debug)]
pub(crate) struct PortOpenError {
    message: String,
}

impl PortOpenError {
    /// Whether another application holds the port. Windows reports that as
    /// "Access is denied", Linux as "Permission denied".
    pub(crate) fn is_busy(&self) -> bool {
        is_busy_message(&self.message)
    }
}

impl std::fmt::Display for PortOpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

pub(crate) fn is_busy_message(message: &str) -> bool {
    message.contains("Access is denied")
        || message.contains("access is denied")
        || message.contains("Permission denied")
        || message.contains("permission denied")
}

/// Opens a mount port: 8 data bits, no parity, one stop bit, no flow control
/// (the `serialport` defaults), modem lines left as the OS sets them.
pub(crate) fn open_port(port_name: &str, baud_rate: u32) -> Result<Port, PortOpenError> {
    port_settings(port_name, baud_rate)
        .open()
        .map_err(|e| PortOpenError {
            message: e.to_string(),
        })
}

fn port_settings(port_name: &str, baud_rate: u32) -> serialport::SerialPortBuilder {
    serialport::new(port_name, baud_rate).timeout(PORT_READ_TIMEOUT)
}

/// How one protocol frames a reply.
pub(crate) struct ReplyRule {
    /// Byte that ends a reply.
    pub terminator: u8,
    /// Bytes to drop when they arrive ahead of a reply (line ends a mount
    /// sends after the previous reply's terminator).
    pub leading_framing: &'static [u8],
    /// How long the reply may take.
    pub deadline: Duration,
    /// Text of the timeout error.
    pub timeout_message: &'static str,
}

/// The port of one connected mount. One command and its reply go through the
/// lock together, so concurrent callers cannot interleave on the wire.
pub(crate) struct SerialLink {
    port: Mutex<Option<Port>>,
}

impl SerialLink {
    pub(crate) fn new() -> Self {
        Self {
            port: Mutex::new(None),
        }
    }

    pub(crate) fn attach(&self, port: Port) -> Result<(), DriverError> {
        *self.lock()? = Some(port);
        Ok(())
    }

    /// Closes the port, if one is open.
    pub(crate) fn detach(&self) -> Result<(), DriverError> {
        *self.lock()? = None;
        Ok(())
    }

    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Option<Port>>, DriverError> {
        self.port
            .lock()
            .map_err(|_| DriverError::SdkError("Lock poisoned".into()))
    }

    /// Runs `exchange` with the port held, for replies that take more than
    /// one read shape.
    pub(crate) fn exchange<T>(
        &self,
        exchange: impl FnOnce(&mut Exchange<'_>) -> Result<T, DriverError>,
    ) -> Result<T, DriverError> {
        let mut guard = self.lock()?;
        let port = guard.as_mut().ok_or(DriverError::NotConnected)?;
        exchange(&mut Exchange { port })
    }

    /// Sends `command` and returns the reply up to its terminator.
    pub(crate) fn command(&self, command: &[u8], rule: &ReplyRule) -> Result<String, DriverError> {
        self.exchange(|io| {
            io.send(command)?;
            io.read_reply(rule)
        })
    }

    /// Sends `command` and returns the single byte the mount answers with.
    pub(crate) fn command_byte(&self, command: &[u8], rule: &ReplyRule) -> Result<u8, DriverError> {
        self.exchange(|io| {
            io.send(command)?;
            io.read_reply_byte(rule)
        })
    }

    /// Sends a command the mount does not answer.
    pub(crate) fn command_no_reply(&self, command: &[u8]) -> Result<(), DriverError> {
        self.exchange(|io| io.send(command))
    }
}

/// The port, held for one exchange.
pub(crate) struct Exchange<'a> {
    port: &'a mut Port,
}

impl Exchange<'_> {
    pub(crate) fn send(&mut self, command: &[u8]) -> Result<(), DriverError> {
        self.port.write_all(command).map_err(DriverError::Io)?;
        self.port.flush().map_err(DriverError::Io)
    }

    /// Drops what the device sent that nobody read, such as a reply that came
    /// after its command had timed out, so it cannot pass for the next reply.
    pub(crate) fn discard_input(&mut self) -> Result<(), DriverError> {
        self.port
            .clear(serialport::ClearBuffer::Input)
            .map_err(|e| DriverError::Io(e.into()))
    }

    /// One byte, or `None` when the read brought nothing yet.
    fn read_byte(&mut self) -> Result<Option<u8>, DriverError> {
        let mut buf = [0u8; 1];
        match self.port.read(&mut buf) {
            Ok(1) => Ok(Some(buf[0])),
            Ok(_) => {
                std::thread::sleep(EMPTY_READ_PAUSE);
                Ok(None)
            }
            Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => Ok(None),
            Err(e) => Err(DriverError::Io(e)),
        }
    }

    /// Reads up to the rule's terminator and returns what came before it.
    pub(crate) fn read_reply(&mut self, rule: &ReplyRule) -> Result<String, DriverError> {
        let mut reply = Vec::new();
        let started = Instant::now();

        loop {
            if started.elapsed() > rule.deadline {
                return Err(DriverError::Timeout(rule.timeout_message.to_string()));
            }
            let Some(byte) = self.read_byte()? else {
                continue;
            };
            if reply.is_empty() && rule.leading_framing.contains(&byte) {
                continue;
            }
            if byte == rule.terminator {
                break;
            }
            reply.push(byte);
        }

        Ok(String::from_utf8_lossy(&reply).to_string())
    }

    /// Reads the first byte that is not leading framing. For replies that are
    /// one character with no terminator.
    pub(crate) fn read_reply_byte(&mut self, rule: &ReplyRule) -> Result<u8, DriverError> {
        let started = Instant::now();

        loop {
            if started.elapsed() > rule.deadline {
                return Err(DriverError::Timeout(rule.timeout_message.to_string()));
            }
            match self.read_byte()? {
                Some(byte) if !rule.leading_framing.contains(&byte) => return Ok(byte),
                _ => continue,
            }
        }
    }

    /// Reads what a mount may send after a reply, without waiting for it:
    /// stops after `terminators` terminators, when `window` closes, or as soon
    /// as the port goes quiet for its read timeout. Returns the bytes other
    /// than terminators.
    pub(crate) fn read_trailing(
        &mut self,
        terminator: u8,
        terminators: usize,
        window: Duration,
    ) -> Result<Vec<u8>, DriverError> {
        let mut trailing = Vec::new();
        let mut seen = 0;
        let mut buf = [0u8; 1];
        let started = Instant::now();

        while started.elapsed() < window && seen < terminators {
            match self.port.read(&mut buf) {
                Ok(1) if buf[0] == terminator => seen += 1,
                Ok(1) => trailing.push(buf[0]),
                Ok(_) => break,
                Err(ref e) if e.kind() == std::io::ErrorKind::TimedOut => break,
                Err(e) => return Err(DriverError::Io(e)),
            }
        }

        Ok(trailing)
    }
}

/// What a scan does with the remaining baud rates of a port it could not
/// open.
#[derive(Clone, Copy, PartialEq, Eq)]
pub(crate) enum OnOpenFailure {
    /// Give the port up.
    NextPort,
    /// Try to open it at the next baud rate.
    NextBaudRate,
}

/// How one protocol looks for its mounts.
pub(crate) struct ScanPlan {
    /// Protocol name for log lines.
    pub protocol: &'static str,
    /// Baud rates to try on each port, in order.
    pub baud_rates: &'static [u32],
    pub on_open_failure: OnOpenFailure,
}

/// One question put to a port during a scan.
pub(crate) struct Probe<'a> {
    pub command: &'a [u8],
    /// Wait between writing the command and the single read of its reply.
    pub settle: Duration,
    /// Size of that read. Anything longer stays in the port's buffer.
    pub reply_capacity: usize,
}

/// A port opened by a scan at one baud rate.
pub(crate) struct ProbedPort<'a> {
    pub name: &'a str,
    pub baud_rate: u32,
    port: Port,
}

impl ProbedPort<'_> {
    /// Writes the probe, waits its settle time and reads once. `None` when the
    /// write or the read failed (a silent port times the read out).
    pub(crate) fn ask(&mut self, probe: &Probe<'_>) -> Option<String> {
        if self.port.write_all(probe.command).is_err() {
            return None;
        }
        let _ = self.port.flush();

        let mut buf = vec![0u8; probe.reply_capacity];
        std::thread::sleep(probe.settle);
        let n = self.port.read(&mut buf).ok()?;
        Some(String::from_utf8_lossy(&buf[..n]).into_owned())
    }
}

/// Scans every serial port of the machine for one protocol's mounts.
pub(crate) fn scan_ports<T>(
    plan: &ScanPlan,
    identify: impl FnMut(&mut ProbedPort<'_>) -> Option<T>,
) -> Result<Vec<T>, DriverError> {
    let ports = serialport::available_ports()
        .map_err(|e| DriverError::SdkError(format!("Failed to enumerate ports: {}", e)))?;

    tracing::info!(
        "{} discovery: found {} serial ports to scan",
        plan.protocol,
        ports.len()
    );

    let mounts = scan_port_list(plan, ports, identify);

    tracing::debug!(
        "{} discovery complete: found {} mounts",
        plan.protocol,
        mounts.len()
    );
    Ok(mounts)
}

/// Probes `ports` in order. Each port is opened at the plan's baud rates in
/// turn until `identify` recognizes a mount on it.
pub(crate) fn scan_port_list<T>(
    plan: &ScanPlan,
    ports: Vec<serialport::SerialPortInfo>,
    mut identify: impl FnMut(&mut ProbedPort<'_>) -> Option<T>,
) -> Vec<T> {
    let mut mounts = Vec::new();

    for port_info in ports {
        let name = port_info.port_name.as_str();
        tracing::debug!(
            "Checking port {} ({}) for {}",
            name,
            describe_port_type(&port_info.port_type),
            plan.protocol
        );

        for &baud_rate in plan.baud_rates {
            tracing::debug!(
                "Trying {} at {} baud for {}",
                name,
                baud_rate,
                plan.protocol
            );

            let port = match open_port(name, baud_rate) {
                Ok(port) => port,
                Err(e) => {
                    if e.is_busy() {
                        tracing::debug!(
                            "Port {} is held by another application (an ASCOM driver?), skipping it for {} detection: {}",
                            name,
                            plan.protocol,
                            e
                        );
                    } else {
                        tracing::debug!(
                            "Could not open port {} at {} baud for {} detection: {}",
                            name,
                            baud_rate,
                            plan.protocol,
                            e
                        );
                    }
                    match plan.on_open_failure {
                        OnOpenFailure::NextPort => break,
                        OnOpenFailure::NextBaudRate => continue,
                    }
                }
            };

            let mut probed = ProbedPort {
                name,
                baud_rate,
                port,
            };
            let found = identify(&mut probed);

            drop(probed);
            std::thread::sleep(PORT_RELEASE_SETTLE);

            if let Some(mount) = found {
                mounts.push(mount);
                break;
            }
        }
    }

    mounts
}

fn describe_port_type(port_type: &serialport::SerialPortType) -> String {
    match port_type {
        serialport::SerialPortType::UsbPort(usb) => format!(
            "USB (VID:{:04X} PID:{:04X} {})",
            usb.vid,
            usb.pid,
            usb.product.as_deref().unwrap_or("unknown")
        ),
        serialport::SerialPortType::PciPort => "PCI".to_string(),
        serialport::SerialPortType::BluetoothPort => "Bluetooth".to_string(),
        serialport::SerialPortType::Unknown => "Unknown".to_string(),
    }
}

/// Waits out a pulse-guide `duration`, or until `cancel` is notified.
/// Returns `true` when cancelled.
///
/// `Notify::notified` only sees notifications sent after the future is
/// created, so a cancel from before this call does not end the wait.
pub(crate) async fn pulse_guide_wait(duration: Duration, cancel: &Notify) -> bool {
    tokio::select! {
        _ = tokio::time::sleep(duration) => false,
        _ = cancel.notified() => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    #[tokio::test(flavor = "current_thread")]
    async fn serial_scan_leaves_the_async_runtime_free_to_make_progress() {
        // The single runtime thread must service a 20 ms timer while a 200 ms
        // synchronous scan is in flight. Run the scan inline and it cannot.
        let order = Arc::new(Mutex::new(Vec::new()));

        let timer_order = order.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(20)).await;
            timer_order.lock().unwrap().push("timer");
        });

        let scan_order = order.clone();
        let scanned = run_serial_scan("test", move || {
            std::thread::sleep(Duration::from_millis(200));
            scan_order.lock().unwrap().push("scan");
            Ok(7u32)
        })
        .await
        .expect("scan failed");

        assert_eq!(scanned, 7);
        assert_eq!(
            order.lock().unwrap().as_slice(),
            &["timer", "scan"],
            "the runtime was blocked for the duration of the serial scan"
        );
    }

    #[tokio::test]
    async fn serial_scan_propagates_the_scan_error() {
        let err = run_serial_scan("test", || {
            Err::<(), _>(DriverError::SdkError("no ports".to_string()))
        })
        .await
        .expect_err("expected the scan error to surface");
        assert!(err.to_string().contains("no ports"));
    }

    #[tokio::test]
    async fn serial_scans_do_not_overlap() {
        let first_running = Arc::new(AtomicBool::new(false));
        let overlap = Arc::new(AtomicBool::new(false));

        let first_flag = Arc::clone(&first_running);
        let first = tokio::spawn(async move {
            run_serial_scan("first", move || {
                first_flag.store(true, Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(100));
                first_flag.store(false, Ordering::SeqCst);
                Ok(())
            })
            .await
        });

        tokio::time::sleep(Duration::from_millis(20)).await;
        let observed_running = Arc::clone(&first_running);
        let observed_overlap = Arc::clone(&overlap);
        let second = tokio::spawn(async move {
            run_serial_scan("second", move || {
                observed_overlap.store(observed_running.load(Ordering::SeqCst), Ordering::SeqCst);
                Ok(())
            })
            .await
        });

        first.await.unwrap().unwrap();
        second.await.unwrap().unwrap();
        assert!(!overlap.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn pulse_guide_wait_wakes_on_cancel_notify() {
        let cancel = Arc::new(Notify::new());
        let notifier = Arc::clone(&cancel);

        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            notifier.notify_waiters();
        });

        let started = tokio::time::Instant::now();
        assert!(pulse_guide_wait(Duration::from_secs(5), &cancel).await);
        assert!(
            started.elapsed() < Duration::from_secs(1),
            "cancel notification should end the guide wait promptly"
        );
    }

    #[tokio::test]
    async fn pulse_guide_wait_runs_its_full_duration_without_a_cancel() {
        let cancel = Notify::new();
        // A notification from before the wait must not cut it short.
        cancel.notify_waiters();

        let started = tokio::time::Instant::now();
        assert!(!pulse_guide_wait(Duration::from_millis(60), &cancel).await);
        assert!(started.elapsed() >= Duration::from_millis(60));
    }

    #[test]
    fn port_names_lose_their_path_separators_in_device_ids() {
        assert_eq!(sanitize_port_name("/dev/ttyUSB0"), "_dev_ttyUSB0");
        assert_eq!(sanitize_port_name("COM4"), "COM4");
        assert_eq!(sanitize_port_name("\\\\.\\COM12"), "__._COM12");
    }

    #[test]
    fn a_port_another_application_holds_reads_as_busy() {
        for message in [
            "Access is denied.",
            "Access is denied. (os error 5)",
            "Permission denied (os error 13)",
        ] {
            assert!(is_busy_message(message), "{message:?}");
        }
        assert!(!is_busy_message("No such file or directory"));
    }

    /// A pseudo-terminal has no modem lines, so the wire transcripts cannot
    /// show DTR or RTS. What they depend on is that the port is opened with
    /// the `serialport` defaults and nothing else: no `dtr_on_open`, no flow
    /// control, 8N1.
    #[test]
    fn a_port_is_opened_with_the_library_defaults_and_a_500_ms_read_timeout() {
        assert_eq!(
            port_settings("COM4", 115200),
            serialport::new("COM4", 115200).timeout(Duration::from_millis(500))
        );
    }

    #[test]
    fn a_link_without_a_port_reports_not_connected() {
        let link = SerialLink::new();
        assert!(matches!(
            link.command_no_reply(b":Q#"),
            Err(DriverError::NotConnected)
        ));
    }
}
