//! Process-wide persistent single-threaded-apartment (STA) worker for ASCOM COM.
//!
//! # Why one apartment
//!
//! ASCOM drivers are Win32 STA COM objects. Every COM property/method call on a
//! driver MUST happen on the thread that called `CoInitializeEx(STA)` and that
//! thread MUST run a real Windows message pump, because many drivers service
//! their hardware through a hidden message-only window (filter-wheel moves,
//! camera state transitions, async-property completions all arrive as window
//! messages). The desktop GUI gives the process a pump via Flutter's event loop;
//! the headless appliance has none. That single gap is the root cause behind the
//! beta-gap bugs:
//!
//! * a driver pops a modal dialog at connect and nothing is there to dismiss it
//!   (the appliance hangs forever);
//! * `CoCreateInstance` / `Connected = true` run on a pumpless thread;
//! * a property-put (filter-wheel `Position`) is posted to a window that is
//!   never pumped, so the move silently no-ops;
//! * heartbeat reads accumulate failures and the device is marked unhealthy.
//!
//! This module owns ONE apartment for the whole process lifetime. It calls
//! [`init_com`] exactly once, creates a hidden message-only window so the
//! apartment has a real pump target, and runs a single loop that (a) drains the
//! Win32 message queue every tick and (b) round-robins every registered device's
//! command channel. A device's COM object is created on this thread and is only
//! ever touched from this thread; it never crosses an apartment boundary.
//!
//! # Design vs. the per-device-thread predecessor
//!
//! The previous design spawned one `std::thread` per connected device, each with
//! its own `CoInitializeEx`/apartment and its own pump-and-block loop. That left
//! the process with N independent apartments and, crucially, did its
//! `CoCreateInstance` outside any running pump. Collapsing to a single hosted
//! apartment keeps every device's command-handling body byte-identical (each
//! wrapper still owns its typed `mpsc` command channel and its `match cmd`
//! arms) while the head-of-line cost of serialising all COM onto one thread is
//! accepted per the 6.0 plan — the wrappers already use the async ASCOM variants
//! (`SlewToCoordinatesAsync`, poll-based `StartExposure`) so steady-state work
//! per command is short.
//!
//! Everything here is Windows-only; the parent `ascom_wrapper` module is
//! `#[cfg(windows)]`, so this file is never compiled or tested on Linux.

use skotiq_ascom::init_com;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::OnceLock;
use std::time::Duration;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{BOOL, HWND, LPARAM, LRESULT, TRUE, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::WindowsAndMessaging::{
    CreateWindowExW, DefWindowProcW, DispatchMessageW, EnumThreadWindows, IsWindowVisible,
    PeekMessageW, PostMessageW, RegisterClassW, TranslateMessage, HWND_MESSAGE, MSG, PM_REMOVE,
    WINDOW_EX_STYLE, WINDOW_STYLE, WM_CLOSE, WNDCLASSW,
};

/// Result of polling one device's command channel for a single iteration of the
/// worker loop.
pub(crate) enum PumpOutcome {
    /// A command was received and handled this tick.
    DidWork,
    /// The channel was empty this tick.
    Idle,
    /// All senders are gone (the wrapper was dropped); the device has run its
    /// on-thread teardown and must be removed from the worker.
    Finished,
}

/// A device's on-thread command pump. It is created by a [`DeviceFactory`] on
/// the worker thread, owns the typed COM object plus the receiving half of the
/// wrapper's command channel, and is polled once per worker-loop iteration.
pub(crate) type DevicePump = Box<dyn FnMut() -> PumpOutcome>;

/// Builds a [`DevicePump`] on the worker thread. Runs `CoCreateInstance` for the
/// driver (and any other construction-time COM) inside the apartment. Returning
/// `Err` mirrors the legacy `new()` behaviour for wrappers (e.g. the filter
/// wheel) that fail construction when the COM object cannot be created.
type DeviceFactory = Box<dyn FnOnce() -> Result<DevicePump, String> + Send>;

/// A registration handed to the worker thread: the factory to run on-thread and
/// the channel used to report the construction result back to `register_device`.
struct Registration {
    factory: DeviceFactory,
    ready: Sender<Result<(), String>>,
}

/// How long a single worker-loop pass — a device's construction
/// (`CoCreateInstance`) or any one command pump, including `Connected = true` —
/// may run before we assume a driver has popped a modal dialog that is blocking
/// the apartment, and force it closed. Only armed in headless mode.
const DIALOG_WATCHDOG_TIMEOUT: Duration = Duration::from_secs(60);

static WORKER: OnceLock<Sender<Registration>> = OnceLock::new();

/// Whether interactive driver dialogs (e.g. an ASCOM camera `SetupDialog`, or a
/// driver-internal connection chooser) may be shown.
///
/// `false` in headless mode: there is no operator to dismiss a modal dialog, so
/// showing one blocks the connect indefinitely. Headless is detected the same
/// way the Flutter entrypoint decides it (`apps/desktop/lib/main.dart`): the
/// `--headless` process argument or `SKOTIQ_HEADLESS=1`. The native process
/// shares its argv/env with the Dart side, so no extra FFI is needed. Cached —
/// neither signal changes after process start.
pub(crate) fn interactive_dialogs_allowed() -> bool {
    static ALLOWED: OnceLock<bool> = OnceLock::new();
    *ALLOWED.get_or_init(|| {
        let headless = std::env::args().any(|a| a == "--headless")
            || std::env::var("SKOTIQ_HEADLESS")
                .map(|v| v == "1")
                .unwrap_or(false);
        !headless
    })
}

/// Start the process-wide STA worker thread if it is not already running.
///
/// Idempotent and safe to call from any thread (it is invoked once from native
/// init and again, defensively, from every `register_device`).
pub(crate) fn ensure_sta_worker() {
    let _ = worker_sender();
}

/// The registration channel, lazily starting the worker thread on first use.
fn worker_sender() -> &'static Sender<Registration> {
    WORKER.get_or_init(|| {
        let (tx, rx) = mpsc::channel::<Registration>();
        let spawned = std::thread::Builder::new()
            .name("ascom-sta-worker".to_string())
            .spawn(move || worker_main(rx));
        if let Err(e) = spawned {
            // A failed spawn leaves `rx` dropped; every `register_device` will
            // then observe a closed channel and surface a hard error rather
            // than hanging.
            tracing::error!("Failed to spawn ASCOM STA worker thread: {}", e);
        }
        tx
    })
}

/// Register a device with the STA worker, blocking until its factory has run on
/// the apartment thread.
///
/// The factory is executed on the worker; on success its [`DevicePump`] is added
/// to the round-robin and `Ok(())` is returned, on failure the factory's error
/// string is propagated (matching the legacy synchronous-construction contract).
pub(crate) fn register_device<F>(factory: F) -> Result<(), String>
where
    F: FnOnce() -> Result<DevicePump, String> + Send + 'static,
{
    let (ready_tx, ready_rx) = mpsc::channel();
    worker_sender()
        .send(Registration {
            factory: Box::new(factory),
            ready: ready_tx,
        })
        .map_err(|_| "ASCOM STA worker thread is not running".to_string())?;
    ready_rx
        .recv()
        .map_err(|_| "ASCOM STA worker dropped the device registration".to_string())?
}

fn worker_main(reg_rx: Receiver<Registration>) {
    if let Err(e) = init_com() {
        tracing::error!("ASCOM STA worker failed to initialize COM: {}", e);
        return;
    }

    // SAFETY: GetCurrentThreadId reads the calling thread's id; no pointers.
    let worker_tid = unsafe { GetCurrentThreadId() };

    if create_message_window().is_none() {
        // A driver that needs a real pump target may misbehave, but the central
        // PeekMessage loop below still drains this thread's queue, so continue.
        tracing::warn!("ASCOM STA worker could not create its message-only window");
    }

    tracing::info!("ASCOM STA worker started (single persistent apartment)");

    let mut pumps: Vec<DevicePump> = Vec::new();

    // In headless mode no operator is present to dismiss a driver's modal
    // dialog. A driver can pop one during construction (`CoCreateInstance`) or,
    // more often, during `Connected = true` inside a device pump below; either
    // runs the dialog's own message loop on this single shared apartment thread
    // and wedges every device forever. The worker kicks this watchdog once per
    // loop pass; a missed kick means it is stuck in such a dialog, so the
    // watchdog force-closes the worker's windows from another thread.
    let watchdog = (!interactive_dialogs_allowed())
        .then(|| arm_dialog_watchdog(worker_tid, DIALOG_WATCHDOG_TIMEOUT));

    loop {
        if let Some(watchdog) = &watchdog {
            watchdog.kick();
        }
        pump_messages();

        loop {
            match reg_rx.try_recv() {
                Ok(reg) => match (reg.factory)() {
                    Ok(pump) => {
                        let _ = reg.ready.send(Ok(()));
                        pumps.push(pump);
                    }
                    Err(e) => {
                        let _ = reg.ready.send(Err(e));
                    }
                },
                Err(mpsc::TryRecvError::Empty) => break,
                // The registration sender lives in a process-lifetime OnceLock,
                // so Disconnected is unreachable; stop draining either way.
                Err(mpsc::TryRecvError::Disconnected) => break,
            }
        }

        let mut did_work = false;
        pumps.retain_mut(|pump| match pump() {
            PumpOutcome::Finished => false,
            PumpOutcome::DidWork => {
                did_work = true;
                true
            }
            PumpOutcome::Idle => true,
        });

        if !did_work {
            // Idle: yield briefly, then pump again. 8 ms keeps driver message
            // latency low while leaving the worker effectively idle.
            std::thread::sleep(Duration::from_millis(8));
        }
    }
}

/// Drain this thread's Win32 message queue. Driver hidden-window messages that
/// drive async property completion are dispatched here.
fn pump_messages() {
    // SAFETY: PeekMessage/Translate/Dispatch act only on this thread's own
    // message queue with a stack-local `MSG`; no borrowed pointer escapes.
    unsafe {
        let mut msg = MSG::default();
        while PeekMessageW(&mut msg, HWND::default(), 0, 0, PM_REMOVE).as_bool() {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

/// Create the apartment's hidden message-only window. Mirrors the window setup
/// in [`crate::hotplug`]; `HWND_MESSAGE` as the parent makes it message-only
/// (no taskbar/Z-order presence) while still owning a real message queue.
fn create_message_window() -> Option<HWND> {
    unsafe extern "system" fn wnd_proc(
        hwnd: HWND,
        msg: u32,
        wparam: WPARAM,
        lparam: LPARAM,
    ) -> LRESULT {
        // SAFETY: forwarding to DefWindowProcW is the documented default
        // window-procedure path.
        unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
    }

    // SAFETY: all Win32 pointers here are either default handles or static
    // UTF-16 strings created by `w!`; the class/window are owned by this thread.
    unsafe {
        let Ok(module) = GetModuleHandleW(None) else {
            return None;
        };
        let hinstance = module.into();
        let class_name = w!("SkotiqAscomStaWindow");
        let wnd_class = WNDCLASSW {
            hInstance: hinstance,
            lpszClassName: class_name,
            lpfnWndProc: Some(wnd_proc),
            ..Default::default()
        };
        // RegisterClassW returning 0 is tolerated: the worker is a singleton, so
        // the only failure that matters (a genuinely bad class) surfaces as a
        // null window below.
        let _ = RegisterClassW(&wnd_class);

        let hwnd = CreateWindowExW(
            WINDOW_EX_STYLE::default(),
            class_name,
            PCWSTR::null(),
            WINDOW_STYLE::default(),
            0,
            0,
            0,
            0,
            HWND_MESSAGE,
            None,
            hinstance,
            None,
        );
        (hwnd.0 != 0).then_some(hwnd)
    }
}

/// Handle to the headless dialog watchdog. The worker [`kick`](Self::kick)s it
/// once per loop pass; a kick that does not arrive within the timeout means the
/// worker is wedged in a driver's modal message loop and cannot dismiss it
/// itself, so the watchdog closes its windows from another thread.
struct DialogWatchdog {
    beat: Sender<()>,
}

impl DialogWatchdog {
    fn kick(&self) {
        let _ = self.beat.send(());
    }
}

/// Arm the watchdog: a thread that force-closes every visible top-level window
/// owned by `worker_tid` whenever a heartbeat is missed for `timeout`.
///
/// A driver that pops a modal during `CoCreateInstance` or `Connected = true`
/// runs the dialog's own message loop on the worker thread, so the worker stops
/// kicking and cannot dismiss the dialog itself — the close must come from
/// another thread via `WM_CLOSE`. The watchdog keeps monitoring after firing in
/// case the worker recovers (or a later connect pops another modal).
fn arm_dialog_watchdog(worker_tid: u32, timeout: Duration) -> DialogWatchdog {
    let (beat_tx, beat_rx) = mpsc::channel::<()>();
    std::thread::spawn(move || loop {
        match beat_rx.recv_timeout(timeout) {
            Ok(()) => {}
            Err(mpsc::RecvTimeoutError::Timeout) => {
                tracing::error!(
                    "ASCOM STA worker stalled for {}s in headless mode (a driver likely showed a UI dialog); closing windows it owns",
                    timeout.as_secs()
                );
                close_thread_windows(worker_tid);
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    });
    DialogWatchdog { beat: beat_tx }
}

/// Post `WM_CLOSE` to every visible top-level window owned by `thread_id`.
fn close_thread_windows(thread_id: u32) {
    unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
        // SAFETY: `lparam` carries the `*mut Vec<HWND>` passed to
        // EnumThreadWindows below; it outlives the enumeration.
        unsafe {
            if IsWindowVisible(hwnd).as_bool() {
                let windows = &mut *(lparam.0 as *mut Vec<HWND>);
                windows.push(hwnd);
            }
        }
        TRUE
    }

    let mut windows: Vec<HWND> = Vec::new();
    // SAFETY: `collect` only writes through the pointer we hand it, which points
    // at the stack-local `windows` that outlives the synchronous call.
    unsafe {
        let _ = EnumThreadWindows(
            thread_id,
            Some(collect),
            LPARAM(&mut windows as *mut Vec<HWND> as isize),
        );
        for hwnd in windows {
            let _ = PostMessageW(hwnd, WM_CLOSE, WPARAM(0), LPARAM(0));
        }
    }
}
