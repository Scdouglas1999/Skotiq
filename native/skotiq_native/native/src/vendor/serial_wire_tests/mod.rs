//! Wire transcripts of the serial mount drivers against scripted fake mounts.
//!
//! Each test opens a pseudo-terminal, runs a fake Sky-Watcher, iOptron or
//! LX200 mount on the master side and drives the real driver through the
//! slave. The fake records every byte in both directions, in stream order and
//! without timing, together with the line settings the driver applied to the
//! port. The transcript is compared with the golden file in
//! `tests/fixtures/serial_wire/`, so a change to what a driver writes, the
//! order it writes it in, where it stops reading a reply, or the baud rates it
//! tries shows up as a diff.
//!
//! Set `SERIAL_WIRE_RECORD=<dir>` to write the transcripts into `<dir>`
//! instead of comparing them.
//!
//! What a pseudo-terminal cannot show: modem lines (DTR/RTS), the UDP
//! transport, and Windows `Access is denied` open errors. Sleeps and timeouts
//! are not in the transcripts either; the tests that wait on them assert the
//! elapsed time instead.

mod fakes;
mod sessions;

use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex, Once};
use std::time::{Duration, Instant};

/// Answers one complete command. Gets the command bytes (terminator included)
/// and the baud rate the port is set to; returns the reply bytes, empty for no
/// reply.
pub(super) type Responder = Box<dyn FnMut(&[u8], u32) -> Vec<u8> + Send>;

/// Frame for a note the test writes into the transcript through the port
/// itself, so it lands in stream order after everything the driver wrote.
const MARK_START: u8 = 0x1e;
const MARK_END: u8 = 0x1f;

pub(super) struct FakeMount {
    pub path: String,
    slave: RawFd,
    lines: Arc<Mutex<Vec<(Instant, String)>>>,
    marked: Receiver<()>,
    stop: Arc<AtomicBool>,
}

impl FakeMount {
    /// Opens a pseudo-terminal whose master side answers with `respond`.
    /// `terminator` ends a command (`#` for LX200 and iOptron, CR for SynScan).
    pub(super) fn spawn(terminator: u8, respond: Responder) -> Self {
        let mut master: libc::c_int = 0;
        let mut slave: libc::c_int = 0;
        // SAFETY: openpty writes two descriptors into the provided ints; the
        // optional name, termios and winsize arguments are null.
        let rc = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
            )
        };
        assert_eq!(rc, 0, "openpty failed");

        // Raw from the start: a fresh pty echoes and translates line ends
        // until the driver's own open switches that off.
        // SAFETY: `slave` is a valid tty descriptor and `termios` is fully
        // written by tcgetattr before it is read.
        unsafe {
            let mut termios: libc::termios = std::mem::zeroed();
            assert_eq!(libc::tcgetattr(slave, &mut termios), 0, "tcgetattr failed");
            libc::cfmakeraw(&mut termios);
            assert_eq!(
                libc::tcsetattr(slave, libc::TCSANOW, &termios),
                0,
                "tcsetattr failed"
            );
        }

        let mut name = [0 as libc::c_char; 256];
        // SAFETY: `name` is a writable buffer of the length passed.
        let rc = unsafe { libc::ttyname_r(slave, name.as_mut_ptr(), name.len()) };
        assert_eq!(rc, 0, "ttyname_r failed");
        // SAFETY: ttyname_r succeeded, so `name` is NUL-terminated.
        let path = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) }
            .to_string_lossy()
            .into_owned();

        let lines = Arc::new(Mutex::new(Vec::new()));
        let stop = Arc::new(AtomicBool::new(false));
        let (mark_done, marked) = channel();

        // SAFETY: `master` is a fresh descriptor this function owns.
        let port = unsafe { File::from_raw_fd(master) };
        let thread_lines = lines.clone();
        let thread_stop = stop.clone();
        std::thread::spawn(move || {
            serve(
                port,
                slave,
                terminator,
                respond,
                thread_lines,
                mark_done,
                thread_stop,
            )
        });

        Self {
            path,
            slave,
            lines,
            marked,
            stop,
        }
    }

    /// Adds a note to the transcript after every byte the driver has written
    /// so far, and returns once the fake has processed all of them.
    pub(super) fn mark(&self, note: &str) {
        let mut frame = vec![MARK_START];
        frame.extend_from_slice(note.as_bytes());
        frame.push(MARK_END);
        // SAFETY: `slave` stays open for the life of `self` and `frame` is a
        // valid buffer of the length passed.
        let written = unsafe { libc::write(self.slave, frame.as_ptr().cast(), frame.len()) };
        assert_eq!(written, frame.len() as isize, "short write of a mark");
        self.marked
            .recv_timeout(Duration::from_secs(30))
            .expect("the fake mount never saw the mark");
    }

    pub(super) fn lines(&self) -> Vec<String> {
        self.lines
            .lock()
            .unwrap()
            .iter()
            .map(|(_, line)| line.clone())
            .collect()
    }

    /// Time from the first command the driver wrote to the last transcript
    /// line. Measured here rather than around the driver call because a
    /// connect first queues for the process-wide serial port guard, which
    /// other tests hold for seconds at a time.
    pub(super) fn time_on_the_wire(&self) -> Duration {
        let lines = self.lines.lock().unwrap();
        let first_command = lines
            .iter()
            .find(|(_, line)| line.starts_with("> "))
            .expect("the driver wrote nothing")
            .0;
        lines.last().expect("empty transcript").0 - first_command
    }

    /// Replaces this port's path, and the form the drivers put in device ids,
    /// with fixed tokens: the pty number differs from run to run.
    pub(super) fn scrub(&self, text: &str) -> String {
        let id_form = self.path.replace('/', "_");
        text.replace(&self.path, "<PORT>")
            .replace(&id_form, "<PORT_ID>")
    }
}

impl Drop for FakeMount {
    fn drop(&mut self) {
        // The serving thread closes the slave once it sees this.
        self.stop.store(true, Ordering::SeqCst);
    }
}

fn serve(
    mut port: File,
    slave: RawFd,
    terminator: u8,
    mut respond: Responder,
    lines: Arc<Mutex<Vec<(Instant, String)>>>,
    mark_done: Sender<()>,
    stop: Arc<AtomicBool>,
) {
    let mut pending: Vec<u8> = Vec::new();
    let mut last_settings = String::new();
    let mut buf = [0u8; 1024];

    while !stop.load(Ordering::SeqCst) {
        // The driver opens the port exclusively, and on a pty that flag
        // outlives the driver's handle because the fake keeps the slave open.
        // A real port forgets it on close; clear it so a reopen works here too.
        // SAFETY: `slave` is a valid tty descriptor for the life of the loop.
        unsafe { libc::ioctl(slave, libc::TIOCNXCL) };

        let mut poll = libc::pollfd {
            fd: port.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: `poll` is one valid pollfd.
        let ready = unsafe { libc::poll(&mut poll, 1, 5) };
        if ready <= 0 || poll.revents & libc::POLLIN == 0 {
            continue;
        }
        let n = match port.read(&mut buf) {
            Ok(0) | Err(_) => continue,
            Ok(n) => n,
        };
        // SAFETY: as above.
        unsafe { libc::ioctl(slave, libc::TIOCNXCL) };
        pending.extend_from_slice(&buf[..n]);

        while let Some(pos) = pending
            .iter()
            .position(|b| *b == terminator || *b == MARK_START)
        {
            if pending[pos] == MARK_START {
                let Some(end) = pending.iter().position(|b| *b == MARK_END) else {
                    break;
                };
                let mut log = lines.lock().unwrap();
                if pos > 0 {
                    log.push((Instant::now(), format!(">? {}", escape(&pending[..pos]))));
                }
                log.push((
                    Instant::now(),
                    String::from_utf8_lossy(&pending[pos + 1..end]).into_owned(),
                ));
                drop(log);
                pending.drain(..=end);
                let _ = mark_done.send(());
                continue;
            }

            let command: Vec<u8> = pending.drain(..=pos).collect();
            let (settings, baud) = port_settings(slave);
            let mut log = lines.lock().unwrap();
            if settings != last_settings {
                log.push((Instant::now(), format!("@ port {settings}")));
                last_settings = settings;
            }
            log.push((Instant::now(), format!("> {}", escape(&command))));
            let reply = respond(&command, baud);
            if !reply.is_empty() {
                log.push((Instant::now(), format!("< {}", escape(&reply))));
                drop(log);
                port.write_all(&reply).expect("write a reply to the pty");
            }
        }
    }

    // SAFETY: nothing uses `slave` after the stop flag is set.
    unsafe { libc::close(slave) };
}

/// The line settings the driver applied, read back from the slave side.
fn port_settings(slave: RawFd) -> (String, u32) {
    // SAFETY: TCGETS2 fills the termios2 it is given; `slave` is a valid tty.
    let termios = unsafe {
        let mut termios: libc::termios2 = std::mem::zeroed();
        assert_eq!(
            libc::ioctl(slave, libc::TCGETS2, &mut termios),
            0,
            "TCGETS2 failed"
        );
        termios
    };

    let data_bits = match termios.c_cflag & libc::CSIZE {
        libc::CS5 => 5,
        libc::CS6 => 6,
        libc::CS7 => 7,
        _ => 8,
    };
    let parity = if termios.c_cflag & libc::PARENB == 0 {
        "none"
    } else if termios.c_cflag & libc::PARODD != 0 {
        "odd"
    } else {
        "even"
    };
    let stop_bits = if termios.c_cflag & libc::CSTOPB != 0 {
        2
    } else {
        1
    };
    let flow = if termios.c_cflag & libc::CRTSCTS != 0 {
        "hardware"
    } else if termios.c_iflag & (libc::IXON | libc::IXOFF) != 0 {
        "software"
    } else {
        "none"
    };

    (
        format!(
            "baud={} data={} parity={} stop={} flow={}",
            termios.c_ospeed, data_bits, parity, stop_bits, flow
        ),
        termios.c_ospeed,
    )
}

fn escape(bytes: &[u8]) -> String {
    let mut out = String::new();
    for &b in bytes {
        match b {
            b'\r' => out.push_str("\\r"),
            b'\n' => out.push_str("\\n"),
            b'\\' => out.push_str("\\\\"),
            0x20..=0x7e => out.push(b as char),
            _ => out.push_str(&format!("\\x{b:02x}")),
        }
    }
    out
}

/// The LX200 driver keeps its park flag in a file under `SKOTIQ_HOME`. Point
/// that at a scratch directory so the tests never touch the user's own.
///
/// The file is one JSON map for every mount, rewritten whole on each park and
/// unpark, so two sessions writing at once corrupt it. Hold the returned guard
/// for the length of any test that parks an LX200 mount.
pub(super) async fn isolate_park_state() -> tokio::sync::MutexGuard<'static, ()> {
    static ONCE: Once = Once::new();
    static ONE_AT_A_TIME: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    ONCE.call_once(|| {
        let dir = std::env::temp_dir().join(format!("skotiq-serial-wire-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create the scratch park-state directory");
        std::env::set_var("SKOTIQ_HOME", &dir);
    });
    ONE_AT_A_TIME.lock().await
}

/// Compares `lines` with the golden transcript `name`, or writes it out when
/// `SERIAL_WIRE_RECORD` names a directory.
pub(super) fn check_transcript(name: &str, lines: &[String]) {
    let mut actual = lines.join("\n");
    actual.push('\n');

    if let Ok(dir) = std::env::var("SERIAL_WIRE_RECORD") {
        let dir = std::path::PathBuf::from(dir);
        std::fs::create_dir_all(&dir).expect("create the record directory");
        std::fs::write(dir.join(format!("{name}.txt")), &actual).expect("write the transcript");
        return;
    }

    let golden_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures/serial_wire")
        .join(format!("{name}.txt"));
    let golden = std::fs::read_to_string(&golden_path)
        .unwrap_or_else(|e| panic!("read golden transcript {}: {e}", golden_path.display()));

    if golden != actual {
        let first_difference = golden
            .lines()
            .zip(actual.lines())
            .position(|(want, got)| want != got)
            .unwrap_or_else(|| golden.lines().count().min(actual.lines().count()));
        panic!(
            "wire transcript `{name}` differs from {} at line {}:\n  golden: {:?}\n  actual: {:?}\n\nfull actual transcript:\n{actual}",
            golden_path.display(),
            first_difference + 1,
            golden.lines().nth(first_difference),
            actual.lines().nth(first_difference),
        );
    }
}
