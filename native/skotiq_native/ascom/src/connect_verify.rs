//! Read-back verification policy for ASCOM connects.
//!
//! Setting `Connected = true` on an ASCOM driver and getting no COM exception
//! is **not** evidence that a device is there. ASCOM registers *drivers*, not
//! *hardware*, so a driver for a device the operator does not own is a normal
//! entry in every device list. Measured on real hardware:
//! `ASCOM.ASIMount.Telescope`, with no ASI mount present, accepted
//! `Connected = true` in 54 ms without complaint and then reported
//! `Connected = False`, `Slewing = True`, `SiderealTime = -1` and RA/Dec/Alt/Az
//! all zero — for the full 20 s the probe watched, and after a clean
//! disconnect too. An app that believes the write announces a connected mount
//! and serves `slewing: true` for ever, which hangs any wait-for-slew: slew &
//! centre, meridian flip, and the sequencer's own move steps all block until
//! morning.
//!
//! The policy therefore is: write, then poll the property back until the
//! driver agrees or the budget runs out.
//!
//! This module is deliberately platform-independent and free of COM types so
//! the timing and message policy can be tested on any host. The COM plumbing
//! that feeds it lives in `windows::connection`.

use std::time::Duration;

/// How long to wait for a driver to actually report `Connected = true` after
/// accepting the request.
///
/// The budget is set by how long real hardware may take, not by how long an
/// operator will watch a spinner: the loop returns the instant the driver says
/// `true`, so a healthy device pays only its own latency and the full budget
/// is spent only on a device that is not coming up.
///
/// The ceiling is the transport. Every ASCOM device in the bridge is driven
/// through a worker thread whose `connect` reply is awaited under
/// `Timeouts::connection()` (`skotiq_bridge::timeout_ops`), currently 30 s;
/// a budget that outlasts it means the caller has already given up and the
/// diagnostic this module composes is never read. The budget must therefore
/// cover the whole of `connect()`: the `Connected = true` write, the polling,
/// and the cleanup write on the way out. 20 s leaves ~10 s of that headroom
/// while still standing 60x above the slowest measured real device (315 ms,
/// ASI178MM through the production `connect()`), and `bridge::timeout_ops`
/// carries a test that fails if either side of this relationship drifts.
pub const CONNECT_VERIFY_TIMEOUT: Duration = Duration::from_secs(20);

/// Headroom that must remain between [`CONNECT_VERIFY_TIMEOUT`] and the
/// transport's own connect deadline, to cover the two property writes that
/// bracket the polling loop plus scheduling slop. Asserted in
/// `skotiq_bridge::timeout_ops`, which is the only place that can see both
/// numbers.
pub const CONNECT_VERIFY_TRANSPORT_HEADROOM: Duration = Duration::from_secs(5);

/// Gap between read-backs while waiting. Each read is a COM round trip on the
/// STA thread, so this is not free.
pub const CONNECT_VERIFY_POLL: Duration = Duration::from_millis(150);

/// Poll `read_connected` until it reports `true`, the budget expires, or the
/// caller's clock says we are done.
///
/// Returns `Ok(())` once the driver agrees it is connected. On expiry returns
/// the operator-facing message describing what actually happened — the caller
/// is responsible for putting the driver back down before surfacing it.
///
/// `elapsed` reports time since the connect request; `sleep` waits between
/// polls. Both are injected so the policy can be tested without real time.
///
/// A read that *throws* is treated the same as a read that returns `false` —
/// both mean "the driver has not confirmed" — but the most recent exception is
/// carried into the message, because "still reports Connected = false" and
/// "the read itself failed" send an operator to different places.
pub fn verify_connected_readback<R, S, E>(
    prog_id: &str,
    timeout: Duration,
    poll: Duration,
    mut read_connected: R,
    mut sleep: S,
    mut elapsed: E,
) -> Result<(), String>
where
    R: FnMut() -> Result<bool, String>,
    S: FnMut(Duration),
    E: FnMut() -> Duration,
{
    // Deliberately uninitialised: every path that reaches the read below
    // assigns it first, so there is no placeholder value to mistake for an
    // observation.
    let mut last_err: Option<String>;
    loop {
        match read_connected() {
            Ok(true) => return Ok(()),
            // A successful read of `false` supersedes an earlier exception:
            // the newest observation is the truthful one to report.
            Ok(false) => last_err = None,
            Err(e) => last_err = Some(e),
        }

        if elapsed() >= timeout {
            return Err(not_online_message(prog_id, last_err.as_deref()));
        }

        sleep(poll);
    }
}

/// The operator-facing failure text.
///
/// It names the three things that actually produce this state on a real rig,
/// in the order an operator can check them, because the bare COM error this
/// replaces ("Exception occurred. (0x80020009)") is accurate and useless.
pub fn not_online_message(prog_id: &str, last_error: Option<&str>) -> String {
    let detail = match last_error {
        Some(e) => format!("; last read failed: {e}"),
        None => " and still reports Connected = false".to_string(),
    };
    // Plain ASCII only: this string reaches Windows console logs, which are not
    // UTF-8 by default and turn an em dash into mojibake.
    format!(
        "{prog_id} accepted the connect request but did not come online{detail}. \
         The driver is installed, but the device is not responding - check that \
         it is powered, plugged in, and not already open in another application."
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    /// A deterministic stand-in for the wall clock: `sleep` advances it, so the
    /// policy's own poll cadence drives time forward and no test ever waits.
    struct FakeClock {
        now: Cell<Duration>,
    }

    impl FakeClock {
        fn new() -> Self {
            Self {
                now: Cell::new(Duration::ZERO),
            }
        }
        fn advance(&self, d: Duration) {
            self.now.set(self.now.get() + d);
        }
        fn elapsed(&self) -> Duration {
            self.now.get()
        }
    }

    #[test]
    fn phantom_driver_that_never_comes_online_is_rejected() {
        // The measured ASI Mount behaviour: the write is accepted, then
        // `Connected` reads false for ever. This must not be reported as a
        // connected device.
        let clock = FakeClock::new();
        let reads = Cell::new(0usize);

        let result = verify_connected_readback(
            "ASCOM.ASIMount.Telescope",
            Duration::from_secs(30),
            Duration::from_millis(150),
            || {
                reads.set(reads.get() + 1);
                Ok(false)
            },
            |d| clock.advance(d),
            || clock.elapsed(),
        );

        let err = result.expect_err("a driver that never reports Connected=true must fail");
        assert!(
            err.contains("ASCOM.ASIMount.Telescope"),
            "message must name the driver: {err}"
        );
        assert!(
            err.contains("did not come online"),
            "message must say it did not come online: {err}"
        );
        assert!(
            err.contains("still reports Connected = false"),
            "message must report the read-back state: {err}"
        );
        assert!(
            err.contains("already open in another application"),
            "message must list the real causes: {err}"
        );
        // It actually polled for the whole budget rather than giving up at once.
        assert!(
            reads.get() > 100,
            "expected ~200 polls across 30 s at 150 ms, got {}",
            reads.get()
        );
    }

    #[test]
    fn device_that_is_ready_immediately_returns_without_sleeping() {
        // A healthy device must pay no added latency: the very first read-back
        // succeeds and the policy returns before any sleep.
        let clock = FakeClock::new();
        let slept = Cell::new(0usize);

        let result = verify_connected_readback(
            "ASCOM.PegasusAstroNYX101.Telescope",
            CONNECT_VERIFY_TIMEOUT,
            CONNECT_VERIFY_POLL,
            || Ok(true),
            |_| slept.set(slept.get() + 1),
            || clock.elapsed(),
        );

        assert!(result.is_ok(), "a ready device must connect: {result:?}");
        assert_eq!(slept.get(), 0, "must not sleep when the device is ready");
    }

    #[test]
    fn slow_but_genuine_device_is_accepted_not_rejected() {
        // The failure mode this check risks introducing. A device that takes
        // 5 s to come up — longer than an impatient budget, well inside a
        // hardware-shaped one — must still connect.
        let clock = FakeClock::new();
        let reads = Cell::new(0usize);

        let result = verify_connected_readback(
            "ASCOM.SlowFilterWheel.FilterWheel",
            CONNECT_VERIFY_TIMEOUT,
            CONNECT_VERIFY_POLL,
            || {
                reads.set(reads.get() + 1);
                // ~5 s at a 150 ms cadence.
                Ok(reads.get() > 33)
            },
            |d| clock.advance(d),
            || clock.elapsed(),
        );

        assert!(
            result.is_ok(),
            "a device that comes up in ~5 s must be accepted, not rejected: {result:?}"
        );
        assert!(
            clock.elapsed() >= Duration::from_secs(4),
            "sanity: the fake clock should have advanced ~5 s, got {:?}",
            clock.elapsed()
        );
    }

    #[test]
    fn a_throwing_read_is_reported_with_its_exception() {
        // Distinguishes "driver says no" from "driver blew up when asked",
        // which send an operator to different places.
        let clock = FakeClock::new();

        let err = verify_connected_readback(
            "ASCOM.Broken.Camera",
            Duration::from_secs(1),
            Duration::from_millis(150),
            || Err("Exception occurred. (0x80020009)".to_string()),
            |d| clock.advance(d),
            || clock.elapsed(),
        )
        .expect_err("a driver whose Connected read throws must not be reported connected");

        assert!(
            err.contains("last read failed: Exception occurred. (0x80020009)"),
            "message must carry the driver's own exception: {err}"
        );
        assert!(
            !err.contains("still reports Connected = false"),
            "must not also claim a clean false read: {err}"
        );
    }

    #[test]
    fn a_recovered_read_supersedes_an_earlier_exception() {
        // If the driver throws once and then answers cleanly (false), the
        // message should describe the newest observation, not the stale error.
        let clock = FakeClock::new();
        let reads = Cell::new(0usize);

        let err = verify_connected_readback(
            "ASCOM.Flaky.Focuser",
            Duration::from_millis(500),
            Duration::from_millis(150),
            || {
                reads.set(reads.get() + 1);
                if reads.get() == 1 {
                    Err("transient".to_string())
                } else {
                    Ok(false)
                }
            },
            |d| clock.advance(d),
            || clock.elapsed(),
        )
        .expect_err("never reported true, so must fail");

        assert!(
            err.contains("still reports Connected = false"),
            "newest observation should win: {err}"
        );
        assert!(
            !err.contains("transient"),
            "stale exception should not be reported: {err}"
        );
    }

    #[test]
    fn read_back_is_attempted_at_least_once_even_with_a_zero_budget() {
        // Guards the loop's ordering: the deadline is checked *after* a read,
        // so a device that is already up cannot be rejected by an expired
        // budget it never got a chance to satisfy.
        let clock = FakeClock::new();

        let result = verify_connected_readback(
            "ASCOM.Instant.Rotator",
            Duration::ZERO,
            CONNECT_VERIFY_POLL,
            || Ok(true),
            |d| clock.advance(d),
            || clock.elapsed(),
        );

        assert!(
            result.is_ok(),
            "an already-connected device must be accepted even with no budget: {result:?}"
        );
    }
}
