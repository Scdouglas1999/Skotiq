//! Whether a connected device's status reads are still succeeding.
//!
//! # Why this exists
//!
//! The heartbeat asks each driver one cheap question (an ASCOM mount's
//! `Tracking`, a camera's connected flag). On the reference rig (Nov 8 2026)
//! the NYX-101's ASCOM driver kept answering that question while every
//! position read failed with `Failed to get RA ... Starting the driver is
//! required ... 0x80040401`. The heartbeat stayed healthy, the device list said
//! connected, and every screen kept showing the last position it had read as if
//! it were current, all night.
//!
//! The status reads the app actually shows are the better liveness signal, so
//! every status read records its outcome here, and the heartbeat counts a run
//! of failed reads as a failed poll even when its own probe passed. The device
//! then goes through the normal path for a lost device: an error with the
//! driver's own reason, then the reconnection loop, which keeps trying until
//! reads succeed again.

use crate::device_manager::DeviceManager;
use crate::dispatch::error::DeviceOpError;
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Failed status reads in a row, with no success between them, after which the
/// heartbeat treats the device as not answering.
pub(crate) const STATUS_READ_FAILURE_LIMIT: u32 = 3;

/// How recent the last failed read must be to count. A device nobody has read
/// for a while is judged by its heartbeat probe alone.
const STATUS_READ_FAILURE_WINDOW: Duration = Duration::from_secs(60);

/// The run of failed status reads for one device.
#[derive(Debug, Clone)]
pub(crate) struct StatusReadRun {
    pub consecutive_failures: u32,
    pub last_error: String,
    pub last_failure_at: Instant,
}

/// Per-device status-read outcomes, keyed by device id.
#[derive(Default)]
pub(crate) struct StatusReadHealth(Mutex<HashMap<String, StatusReadRun>>);

impl StatusReadHealth {
    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, StatusReadRun>> {
        self.0.lock().unwrap_or_else(|p| p.into_inner())
    }

    pub(crate) fn record_success(&self, device_id: &str) {
        self.lock().remove(device_id);
    }

    pub(crate) fn record_failure(&self, device_id: &str, error: &str, at: Instant) {
        let mut runs = self.lock();
        let run = runs
            .entry(device_id.to_string())
            .or_insert_with(|| StatusReadRun {
                consecutive_failures: 0,
                last_error: String::new(),
                last_failure_at: at,
            });
        run.consecutive_failures += 1;
        run.last_error = error.to_string();
        run.last_failure_at = at;
    }

    pub(crate) fn forget(&self, device_id: &str) {
        self.lock().remove(device_id);
    }

    /// The reason to treat the device as not answering, when its reads have
    /// failed [`STATUS_READ_FAILURE_LIMIT`] times in a row and the last
    /// failure is recent.
    pub(crate) fn failing(&self, device_id: &str, now: Instant) -> Option<String> {
        let runs = self.lock();
        let run = runs.get(device_id)?;
        if run.consecutive_failures < STATUS_READ_FAILURE_LIMIT
            || now.saturating_duration_since(run.last_failure_at) > STATUS_READ_FAILURE_WINDOW
        {
            return None;
        }
        Some(format!(
            "the last {} status reads failed: {}",
            run.consecutive_failures, run.last_error
        ))
    }
}

/// Whether a failed read says anything about the device. An id the manager
/// does not know or cannot parse is a caller mistake, not a device problem.
fn counts_against_device(error: &DeviceOpError) -> bool {
    !matches!(
        error,
        DeviceOpError::DeviceNotFound(_) | DeviceOpError::InvalidDeviceId { .. }
    )
}

impl DeviceManager {
    /// Record how a status read of `device_id` went.
    pub(crate) fn note_status_read<T>(&self, device_id: &str, result: &Result<T, DeviceOpError>) {
        match result {
            Ok(_) => self.status_reads.record_success(device_id),
            Err(e) if counts_against_device(e) => {
                self.status_reads
                    .record_failure(device_id, &e.to_string(), Instant::now())
            }
            Err(_) => {}
        }
    }

    /// See [`StatusReadHealth::failing`].
    pub(crate) fn failing_status_reads(&self, device_id: &str) -> Option<String> {
        self.status_reads.failing(device_id, Instant::now())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn three_failures_in_a_row_count_and_a_success_clears_them() {
        let health = StatusReadHealth::default();
        let t = Instant::now();
        health.record_failure("m", "Failed to get RA", t);
        health.record_failure("m", "Failed to get RA", t);
        assert_eq!(health.failing("m", t), None);
        health.record_failure("m", "Failed to get RA: 0x80040401", t);
        let reason = health.failing("m", t).expect("three failures count");
        assert!(reason.contains("0x80040401"), "{reason}");

        health.record_success("m");
        assert_eq!(health.failing("m", t), None);
    }

    #[test]
    fn old_failures_do_not_count() {
        let health = StatusReadHealth::default();
        let t = Instant::now();
        for _ in 0..5 {
            health.record_failure("m", "x", t);
        }
        let later = t + STATUS_READ_FAILURE_WINDOW + Duration::from_secs(1);
        assert_eq!(health.failing("m", later), None);
    }

    #[test]
    fn devices_are_tracked_separately() {
        let health = StatusReadHealth::default();
        let t = Instant::now();
        for _ in 0..3 {
            health.record_failure("mount", "x", t);
        }
        assert!(health.failing("mount", t).is_some());
        assert_eq!(health.failing("camera", t), None);
    }

    #[test]
    fn unknown_ids_are_not_device_failures() {
        assert!(!counts_against_device(&DeviceOpError::DeviceNotFound(
            "x".into()
        )));
        assert!(counts_against_device(&DeviceOpError::NotConnected {
            device_id: None,
            detail: "ASCOM mount not connected".into(),
        }));
    }
}
