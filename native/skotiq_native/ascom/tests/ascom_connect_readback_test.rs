//! Hardware-fixture test for the connect read-back check (finding L4).
//!
//! The pure timing/message policy is unit-tested in `connect_verify`, but those
//! tests pass whether or not `AscomDeviceConnection::connect` actually *calls*
//! it. This file covers that gap: it drives the real production `connect()`
//! against a real COM driver and asserts the connect is refused. Revert the
//! read-back in `windows::connection` and this test fails, because `connect()`
//! goes back to returning `Ok(())`.
//!
//! ## The fixture
//!
//! It needs an ASCOM driver that is *installed but has no hardware behind it* —
//! the exact situation that produced the bug, and one that is completely normal
//! because ASCOM registers drivers independently of devices. On the reference
//! imaging laptop that is `ASCOM.ASIMount.Telescope`: the owner has ZWO
//! cameras, so the ASI mount driver is installed, but there is no ASI mount.
//! Measured 2026-08-09, it accepts `Connected = true` in 54 ms and then reports
//! `Connected = False` indefinitely.
//!
//! Because that fixture is machine-specific, the test is `#[ignore]`d and the
//! ProgID is overridable. Run it on a machine that has such a driver:
//!
//! ```text
//! cargo test -p skotiq_ascom --test ascom_connect_readback_test -- --ignored --nocapture
//! SKOTIQ_PHANTOM_PROGID=ASCOM.Something.Telescope cargo test ... -- --ignored
//! ```
//!
//! Do NOT point it at a driver whose hardware is present and powered: that
//! device will connect, and the test will correctly fail.

// Why cfg(windows): `AscomDeviceConnection` and the COM entry points live under
// `#[cfg(windows)]`. On other targets this file compiles to nothing.
#![cfg(windows)]

use skotiq_ascom::{init_com, uninit_com, AscomDeviceConnection};

/// The driver-with-no-hardware used as the fixture.
fn phantom_prog_id() -> String {
    std::env::var("SKOTIQ_PHANTOM_PROGID")
        .unwrap_or_else(|_| "ASCOM.ASIMount.Telescope".to_string())
}

#[test]
#[ignore = "needs an ASCOM driver installed with no hardware behind it; see module docs"]
fn connect_refuses_a_driver_that_never_reports_connected() {
    init_com().expect("COM init failed");

    let prog_id = phantom_prog_id();
    let mut device = match AscomDeviceConnection::new(&prog_id) {
        Ok(d) => d,
        Err(e) => {
            uninit_com();
            panic!("could not create COM object for fixture driver {prog_id}: {e}");
        }
    };

    let started = std::time::Instant::now();
    let result = device.connect();
    let elapsed = started.elapsed();

    println!("connect({prog_id}) took {elapsed:?} and returned {result:?}");

    let err = match result {
        Ok(()) => {
            uninit_com();
            panic!(
                "REGRESSION: connect() reported success for {prog_id}, a driver with no hardware \
                 behind it. This is finding L4: the app announces a connected device and then \
                 serves latched garbage telemetry (the ASI mount reports slewing=true for ever), \
                 which hangs any wait-for-slew for the rest of the night."
            );
        }
        Err(e) => e,
    };

    // The operator-facing message has to name the driver and the real causes,
    // not just surface the driver's own "Exception occurred. (0x80020009)".
    assert!(
        err.contains(&prog_id),
        "failure message must name the driver: {err}"
    );
    assert!(
        err.contains("did not come online"),
        "failure message must say the device never came online: {err}"
    );
    assert!(
        err.contains("powered"),
        "failure message must point at the real causes: {err}"
    );

    // The check must actually have waited rather than failing on the first
    // read: a driver is allowed a moment to come up.
    assert!(
        elapsed >= std::time::Duration::from_secs(5),
        "expected connect() to poll for the verify budget before giving up, took only {elapsed:?}"
    );

    // ...and it must finish INSIDE the transport's own connect deadline. Every
    // ASCOM wrapper in the bridge awaits this call under
    // `Timeouts::connection()` (30 s). Overrun it and the caller has already
    // dropped the receiver, so the operator sees a bare
    // "<device> connect timed out after 30s" and every message asserted above
    // is composed and thrown away. Measured 2026-08-09 with the budget set to
    // 30 s, this call returned at 30.064 s and did exactly that.
    assert!(
        elapsed < std::time::Duration::from_secs(30),
        "connect() took {elapsed:?}, at or past the bridge's Timeouts::connection() deadline of \
         30s. The phantom is still refused, but the operator gets a generic timeout instead of \
         the message above. Lower CONNECT_VERIFY_TIMEOUT."
    );

    // The health monitor must not go on vouching for it either. `connect()`
    // calls `HealthMonitor::reset()` on entry, which stores `is_healthy = true`
    // and zeroes `last_success`; a single `record_failure()` afterwards is
    // swallowed by the 3-strike `max_failures` threshold, so `get_health()`
    // returns `Unknown` and `is_healthy()` — which treats `Unknown` as fine —
    // answers `true` for a device that just demonstrably failed to come up.
    // That is the same "the app states something untrue" shape as the bug this
    // whole check exists to kill, one layer down.
    assert!(
        !device.is_healthy(),
        "REGRESSION: is_healthy() still reports true after a failed connect \
         (health = {:?}); the health monitor is vouching for a phantom.",
        device.get_health()
    );

    // And it must have put the driver back down rather than leaving a
    // half-open handle for the next attempt to fight.
    match device.is_connected() {
        Ok(false) => {}
        Ok(true) => panic!("failed connect left the driver reporting Connected = true"),
        Err(e) => println!("note: post-failure Connected read threw (acceptable): {e}"),
    }

    uninit_com();
}

/// The positive control, and the one that matters most for an unattended run:
/// the read-back must not reject hardware that is genuinely there.
///
/// Point `SKOTIQ_REAL_PROGID` at a driver whose device is present and
/// powered, and that nothing else currently holds open. On the reference rig
/// `ASCOM.ASICamera2_2.Camera` (the ASI178MM in the second ZWO slot) is real,
/// attached, and not claimed by the running appliance.
///
/// **Caveat, observed 2026-08-09:** "not claimed" has to mean the whole COM
/// server, not just the ProgID. ZWO serves `ASCOM.ASICamera2.Camera` and
/// `ASCOM.ASICamera2_2.Camera` from one shared local server, so running this
/// test against slot 2 while an appliance holds slot 1 drops the appliance's
/// camera — it silently vanished from `/api/devices/connected` and had to be
/// reconnected by hand. Run this against a vendor family nothing else is
/// using, or expect to restore the other process afterwards.
///
/// ```text
/// SKOTIQ_REAL_PROGID=ASCOM.ASICamera2_2.Camera \
///   cargo test -p skotiq_ascom --test ascom_connect_readback_test -- --ignored --nocapture
/// ```
#[test]
#[ignore = "needs a real, attached, unclaimed ASCOM device; set SKOTIQ_REAL_PROGID"]
fn connect_still_accepts_a_real_attached_device() {
    let Ok(prog_id) = std::env::var("SKOTIQ_REAL_PROGID") else {
        panic!("set SKOTIQ_REAL_PROGID to a driver whose hardware is present");
    };

    init_com().expect("COM init failed");

    let mut device = match AscomDeviceConnection::new(&prog_id) {
        Ok(d) => d,
        Err(e) => {
            uninit_com();
            panic!("could not create COM object for {prog_id}: {e}");
        }
    };

    let started = std::time::Instant::now();
    let result = device.connect();
    let elapsed = started.elapsed();

    println!("connect({prog_id}) took {elapsed:?} and returned {result:?}");

    // Always put real hardware back down, even if the assertion below fails.
    let disconnect = device.disconnect();

    assert!(
        result.is_ok(),
        "REGRESSION: the read-back check rejected a real attached device after {elapsed:?}: \
         {result:?}. A false rejection costs the night just as surely as a false accept."
    );
    println!("disconnect returned {disconnect:?}");

    uninit_com();
}
