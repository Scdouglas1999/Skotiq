//! ASCOM STA-thread wrappers grouped by device class.
//!
//! Each submodule wraps one ICamera/IMount/etc. interface with the
//! single-threaded apartment marshalling required for Win32 COM. See
//! the per-file module-level docs for the as-cast / unwrap_or policy
//! that applies to that interface.

pub mod camera;
pub mod covercalibrator;
pub mod dome;
pub mod filterwheel;
pub mod focuser;
pub mod mount;
pub mod rotator;
pub mod safetymonitor;
pub mod sta_worker;
pub mod switch;
pub mod weather;

/// Blocking receive that keeps this STA thread's Win32 message queue pumped
/// while it waits for the next command.
///
/// ASCOM drivers are STA COM objects. Many service their hardware through a
/// hidden message-only window: filter-wheel moves, camera state transitions,
/// and other async property completions arrive as window messages. The desktop
/// GUI drains those via its own event loop, but a headless worker thread parked
/// in [`tokio::sync::mpsc::Receiver::blocking_recv`] never pumps messages — so
/// those operations stall, silently no-op, or surface as `DISP_E_EXCEPTION`
/// (`0x80020009`). Draining the queue on a short poll restores GUI-equivalent
/// behaviour WITHOUT weakening the single-threaded-apartment invariant: the
/// driver is still only ever touched from this one thread.
///
/// Returns `None` when the command channel is closed (all senders dropped),
/// matching [`tokio::sync::mpsc::Receiver::blocking_recv`] so callers keep
/// their `while let Some(cmd) = ...` loop shape unchanged.
///
/// TEST-ONLY. On a production path each wrapper hands [`sta_worker`] a closure
/// that does a single non-blocking `try_recv` and reports
/// [`sta_worker::PumpOutcome::Idle`], and the one STA worker owns the message
/// pump for every device (see `sta_worker::pump_messages`). This helper exists
/// only to give the wrapper unit tests that loop shape without standing up a
/// worker; a second pump on a production path would drain messages the central
/// worker is responsible for dispatching.
#[cfg(test)]
pub(crate) fn pump_blocking_recv<T>(rx: &mut tokio::sync::mpsc::Receiver<T>) -> Option<T> {
    use tokio::sync::mpsc::error::TryRecvError;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        DispatchMessageW, PeekMessageW, TranslateMessage, MSG, PM_REMOVE,
    };

    loop {
        // SAFETY: PeekMessage/Translate/Dispatch act only on this thread's own
        // message queue with a stack-local `MSG`; no borrowed pointer escapes
        // the unsafe block.
        unsafe {
            let mut msg = MSG::default();
            while PeekMessageW(&mut msg, HWND::default(), 0, 0, PM_REMOVE).as_bool() {
                // TranslateMessage's BOOL only reports whether a WM_CHAR was
                // posted; irrelevant here, so it's discarded as a bare
                // statement like DispatchMessageW below.
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }

        match rx.try_recv() {
            Ok(cmd) => return Some(cmd),
            // Nothing queued: yield briefly, then pump again. 8 ms keeps driver
            // message latency low while leaving the worker effectively idle.
            Err(TryRecvError::Empty) => {
                std::thread::sleep(std::time::Duration::from_millis(8));
            }
            Err(TryRecvError::Disconnected) => return None,
        }
    }
}
