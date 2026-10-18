//! LX200 Mount Protocol Implementation
//!
//! Implements the Meade LX200 serial command protocol, which is the de-facto
//! standard for many telescope mounts including:
//! - Meade LX200, LX600, LX850
//! - OnStep-based mounts (Pegasus NYX-101, DIY builds)
//! - Losmandy Gemini (LX200 mode)
//! - 10Micron mounts
//! - Many other compatible mounts

use crate::traits::*;
use crate::NativeVendor;
use async_trait::async_trait;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::Notify;

mod discovery;
mod mount;
mod mount_ops;
mod protocol;

pub use discovery::*;
pub use mount::*;
pub use protocol::*;
#[cfg(test)]
mod onstep_status_tests {
    use super::*;

    #[test]
    fn parse_typical_tracking_parked_idle() {
        // N + P + home + GEM + pier east + rate digits + error 0 (no leading n)
        let (tracking, slewing, parked, homed, pier) = parse_onstep_status_fields("NPHET050");
        assert!(tracking, "N without leading n means tracking");
        assert!(!slewing, "N means no goto (not slewing)");
        assert!(parked);
        assert!(homed);
        assert_eq!(pier, PierSide::East);
    }

    #[test]
    fn parse_not_tracking_idle_unparked() {
        // n + N + p per OnStep wiki example (not tracking, not slewing, not parked)
        let (tracking, slewing, parked, homed, pier) = parse_onstep_status_fields("nNpPH");
        assert!(!tracking);
        assert!(!slewing);
        assert!(!parked);
        assert!(homed);
        assert_eq!(pier, PierSide::Unknown);
    }

    #[test]
    fn parse_slewing_without_no_goto_flag() {
        // No 'N' at prefix position 0/1 => slewing per MountStatus.h
        let (tracking, slewing, _, _, _) = parse_onstep_status_fields("pHET050");
        assert!(tracking);
        assert!(slewing);
    }

    #[test]
    fn leading_n_is_not_slewing_n_flag() {
        // Old bug: contains('N') is false for "n..." but inverted logic treated N as slewing.
        // Positional: 'n' at 0 is not-tracking; next char is park 'p', not slewing.
        let (tracking, slewing, parked, _, _) = parse_onstep_status_fields("np");
        assert!(!tracking);
        assert!(slewing, "no N in prefix means goto/slew active");
        assert!(!parked);
    }

    #[test]
    fn gem_mount_type_e_is_not_pier_east() {
        let (_, _, _, _, pier) = parse_onstep_status_fields("NPE");
        assert_eq!(
            pier,
            PierSide::Unknown,
            "E is mount type GEM, not pier side"
        );
    }

    #[test]
    fn pier_t_is_not_tracking_flag() {
        let (tracking, _, _, _, pier) = parse_onstep_status_fields("NpPHET000");
        assert!(tracking);
        assert_eq!(pier, PierSide::East, "T is pier east, not tracking");
    }

    #[test]
    fn strips_hash_terminator() {
        let (tracking, slewing, parked, homed, pier) = parse_onstep_status_fields("nNpKW000#");
        assert!(!tracking);
        assert!(!slewing);
        assert!(!parked);
        assert!(!homed);
        assert_eq!(pier, PierSide::West);
    }

    #[test]
    fn parking_in_progress_is_not_parked() {
        let (_, _, parked, _, _) = parse_onstep_status_fields("nNI");
        assert!(!parked);
    }

    #[test]
    fn slewing_goto_without_n_or_n_is_still_tracking() {
        let (tracking, slewing, parked, _, pier) = parse_onstep_status_fields("pET000#");
        assert!(tracking);
        assert!(slewing);
        assert!(!parked);
        assert_eq!(pier, PierSide::East);
    }

    #[test]
    fn optional_waiting_flag_w_is_not_pier_west() {
        let (_, _, _, _, pier) = parse_onstep_status_fields("NpHwEo000#");
        assert_eq!(
            pier,
            PierSide::Unknown,
            "lowercase waiting-home flag is not pier west"
        );
    }

    #[test]
    fn format_lx200_firmware_version_combines_number_date_and_time() {
        assert_eq!(
            format_firmware_version(Some("4.2g"), Some("Oct 10 2010"), Some("12:34:56")).as_deref(),
            Some("LX200 firmware v4.2g (Oct 10 2010 12:34:56)")
        );
    }

    #[test]
    fn format_lx200_firmware_version_accepts_partial_metadata() {
        assert_eq!(
            format_firmware_version(Some("4.2g"), None, None).as_deref(),
            Some("LX200 firmware v4.2g")
        );
        assert_eq!(
            format_firmware_version(None, Some("Oct 10 2010"), None).as_deref(),
            Some("LX200 firmware Oct 10 2010")
        );
    }

    #[test]
    fn format_lx200_firmware_version_rejects_empty_metadata() {
        assert_eq!(format_firmware_version(Some(""), Some(""), Some("")), None);
    }
}

#[cfg(test)]
mod home_tests {
    use super::*;

    /// The trait default for both methods is `NotSupported`, so a mount that
    /// answers `NotConnected` is proof the LX200 driver overrides them — this
    /// test fails if the implementation is ever lost to a refactor.
    #[tokio::test]
    async fn onstep_implements_home_rather_than_inheriting_the_default() {
        let mut mount = Lx200Mount::new_onstep("TEST_PORT".to_string());
        assert!(
            matches!(mount.find_home().await, Err(NativeError::NotConnected)),
            "OnStep find_home should reach the connection check, not the trait default"
        );
        assert!(
            matches!(mount.at_home().await, Err(NativeError::NotConnected)),
            "OnStep at_home should reach the connection check, not the trait default"
        );
    }

    /// `:hF#` is an OnStep extension. A Meade mount must say it cannot home
    /// instead of sending a command its firmware never defined.
    #[tokio::test]
    async fn meade_reports_no_home_command() {
        let mut mount = Lx200Mount::new_meade("TEST_PORT".to_string());
        assert!(matches!(
            mount.find_home().await,
            Err(NativeError::NotSupported)
        ));
        assert!(matches!(
            mount.at_home().await,
            Err(NativeError::NotSupported)
        ));
    }

    /// The capability flag the UI gates the Home button on must agree with
    /// whether `find_home` can do anything.
    #[test]
    fn only_onstep_advertises_a_home_command() {
        assert!(Lx200Mount::new_onstep("TEST_PORT".to_string()).can_find_home());
        assert!(!Lx200Mount::new_meade("TEST_PORT".to_string()).can_find_home());
    }

    #[test]
    fn find_home_uses_the_onstep_home_command() {
        assert_eq!(commands::ONSTEP_FIND_HOME, ":hF#");
    }
}

/// A Meade-protocol mount on a pseudo-terminal, answering the way the classic
/// firmware does, so the driver can be run end to end without hardware.
#[cfg(all(test, target_os = "linux"))]
mod meade_pty_tests {
    use super::*;
    use std::io::{Read, Write};
    use std::os::fd::FromRawFd;
    use std::sync::atomic::{AtomicU32, Ordering};

    /// Opens a pty whose master answers Meade commands. `:D#` (the distance
    /// bar) reports a slew in progress for the first `bar_polls` asks after a
    /// goto, then an empty bar. Returns the slave path.
    fn spawn_meade_pty(bar_polls: u32) -> String {
        spawn_meade_pty_logged(bar_polls, b"1").0
    }

    /// As [`spawn_meade_pty`], answering `:Sr`/`:Sd` with `target_reply`
    /// (`1` accepted, `0` refused), and recording every command received.
    fn spawn_meade_pty_logged(
        bar_polls: u32,
        target_reply: &'static [u8],
    ) -> (String, Arc<Mutex<Vec<String>>>) {
        let received = Arc::new(Mutex::new(Vec::new()));
        let log = received.clone();
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
        let mut name = [0 as libc::c_char; 256];
        // SAFETY: `name` is a writable buffer of the length passed.
        let rc = unsafe { libc::ttyname_r(slave, name.as_mut_ptr(), name.len()) };
        assert_eq!(rc, 0, "ttyname_r failed");
        // SAFETY: ttyname_r succeeded, so `name` is NUL-terminated.
        let path = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        // The slave stays open (leaked) so the pty outlives the driver's handle.

        // SAFETY: `master` is a fresh descriptor this function owns.
        let mut port = unsafe { std::fs::File::from_raw_fd(master) };
        let bars_left = AtomicU32::new(0);
        std::thread::spawn(move || {
            let mut pending = String::new();
            let mut buf = [0u8; 64];
            loop {
                let n = match port.read(&mut buf) {
                    Ok(0) | Err(_) => return,
                    Ok(n) => n,
                };
                pending.push_str(&String::from_utf8_lossy(&buf[..n]));
                while let Some(end) = pending.find('#') {
                    let command: String = pending.drain(..=end).collect();
                    log.lock().unwrap().push(command.clone());
                    let reply: &[u8] = if command.starts_with(":GVP") {
                        b"LX200 Classic#"
                    } else if command.starts_with(":Sr") || command.starts_with(":Sd") {
                        target_reply
                    } else if command.starts_with(":CM") {
                        b" M31 EX GAL MAG 3.5 SZ178.0'#"
                    } else if command.starts_with(":MS") {
                        bars_left.store(bar_polls, Ordering::SeqCst);
                        b"0"
                    } else if command.starts_with(":D") {
                        let left = bars_left.load(Ordering::SeqCst);
                        if left > 0 {
                            bars_left.store(left - 1, Ordering::SeqCst);
                            b"\x7f#"
                        } else {
                            b"#"
                        }
                    } else if command.starts_with(":GR") {
                        b"05:30:00#"
                    } else if command.starts_with(":GD") {
                        b"+20*00:00#"
                    } else {
                        b""
                    };
                    if !reply.is_empty() && port.write_all(reply).is_err() {
                        return;
                    }
                }
            }
        });
        (path, received)
    }

    /// A sync writes the target and then `:CM#` syncs to whatever target the
    /// mount holds. When the mount refused the new target, that is the
    /// previous goto's, so the mount was synced to the wrong place and the
    /// sync reported success.
    #[tokio::test]
    async fn a_sync_to_a_target_the_mount_refused_fails_and_is_not_sent() {
        let (path, received) = spawn_meade_pty_logged(0, b"0");
        let mut mount = Lx200Mount::new(path, Lx200MountType::Meade, Some(9600));
        mount
            .connect()
            .await
            .expect("connect to the fake Meade mount");

        let result = mount.sync_to_coordinates(5.5, 20.0).await;

        assert!(
            result.is_err(),
            "a sync whose target the mount refused reported success"
        );
        assert!(
            !received
                .lock()
                .unwrap()
                .iter()
                .any(|command| command.starts_with(":CM")),
            "the sync was sent against the mount's previous target"
        );
    }

    /// A goto on a Meade-protocol mount used to latch "slewing" with nothing
    /// that ever cleared it except an abort, so every sequencer slew waited
    /// out its 30-minute limit and failed although the mount had arrived.
    #[tokio::test]
    async fn a_meade_goto_stops_reading_as_slewing_once_the_mount_arrives() {
        let path = spawn_meade_pty(2);
        let mut mount = Lx200Mount::new(path, Lx200MountType::Meade, Some(9600));
        mount
            .connect()
            .await
            .expect("connect to the fake Meade mount");

        mount
            .slew_to_coordinates(5.5, 20.0)
            .await
            .expect("goto on the fake Meade mount");

        assert!(
            mount.is_slewing().await.expect("slew state"),
            "the mount reported the goto in progress, so is_slewing must too"
        );

        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        loop {
            if !mount.is_slewing().await.expect("slew state") {
                break;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "is_slewing stayed true after the mount's distance bar went empty"
            );
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    }
}
