use super::*;

/// Track whether polar alignment is running
pub(crate) static POLAR_ALIGN_RUNNING: OnceLock<PolarAtomicBool> = OnceLock::new();
pub(crate) static POLAR_ALIGN_CANCEL: OnceLock<PolarAtomicBool> = OnceLock::new();

/// Monotonic per-run generation. Bumped when a run is admitted; the spawned
/// task carries the value it was born with and treats a mismatch as "a newer
/// run now owns the hardware — exit silently without clearing its flag or
/// emitting over its status". This is the belt-and-suspenders that makes a
/// stale, force-aborted task unable to corrupt a subsequent run.
pub(crate) static POLAR_ALIGN_GENERATION: AtomicU64 = AtomicU64::new(0);

/// The currently-owned alignment task handle. [`api_stop_polar_alignment`]
/// takes and awaits it (bounded) so stop returns only once the run is actually
/// terminated — never while the old task can still touch the camera/mount.
pub(crate) static POLAR_ALIGN_TASK: OnceLock<Mutex<Option<JoinHandle<()>>>> = OnceLock::new();

/// Serializes start setup with stop teardown. The running atomic alone cannot
/// protect the interval between admitting a run and storing its task handle:
/// without this lock, Stop can observe `running=true`, find no handle yet,
/// clear the flag, and return while Start subsequently launches an orphaned
/// camera/mount task.
pub(crate) static POLAR_ALIGN_CONTROL: OnceLock<Mutex<()>> = OnceLock::new();

/// Bounded grace for a cooperative stop before we force-abort the task.
pub(crate) const POLAR_STOP_CLEAN_GRACE_SECS: u64 = 6;
/// Bounded grace to confirm the task unwound after a force-abort.
pub(crate) const POLAR_STOP_ABORT_GRACE_SECS: u64 = 4;

pub(crate) fn get_polar_align_flag() -> &'static PolarAtomicBool {
    POLAR_ALIGN_RUNNING.get_or_init(|| PolarAtomicBool::new(false))
}

pub(crate) fn get_polar_align_cancel() -> &'static PolarAtomicBool {
    POLAR_ALIGN_CANCEL.get_or_init(|| PolarAtomicBool::new(false))
}

pub(crate) fn polar_generation() -> &'static AtomicU64 {
    &POLAR_ALIGN_GENERATION
}

pub(crate) fn polar_task_slot() -> &'static Mutex<Option<JoinHandle<()>>> {
    POLAR_ALIGN_TASK.get_or_init(|| Mutex::new(None))
}

pub(crate) fn polar_control_lock() -> &'static Mutex<()> {
    POLAR_ALIGN_CONTROL.get_or_init(|| Mutex::new(()))
}

/// Atomically admit a new run. Returns `None` when another run already owns
/// the hardware. A load-then-store check is insufficient because two FRB calls
/// may execute concurrently on Tokio and both observe `false`.
pub(crate) fn try_admit_polar_run() -> Option<u64> {
    get_polar_align_flag()
        .compare_exchange(false, true, PolarOrdering::AcqRel, PolarOrdering::Acquire)
        .ok()?;
    get_polar_align_cancel().store(false, PolarOrdering::Relaxed);
    // fetch_add returns the previous value; our generation is that + 1.
    Some(polar_generation().fetch_add(1, PolarOrdering::Relaxed) + 1)
}

/// Clear the running flag only if `generation` is still the current run. A
/// task that has been superseded must not clear a newer run's flag.
pub(crate) fn release_polar_run_if_current(generation: u64) {
    if polar_generation().load(PolarOrdering::Relaxed) == generation {
        get_polar_align_flag().store(false, PolarOrdering::Relaxed);
    }
}

/// Store the owning task handle for the current run, replacing (and dropping)
/// any finished handle left from a prior run.
pub(crate) async fn store_polar_task(handle: JoinHandle<()>) {
    *polar_task_slot().lock().await = Some(handle);
}

/// Outcome of a per-iteration stop check inside a running alignment task.
pub(crate) enum PolarLoopControl {
    /// Keep running — this task still owns the run and no cancel is pending.
    Continue,
    /// A newer run has taken the generation; exit silently so we neither stomp
    /// its status nor clear its running flag.
    Superseded,
    /// The user cancelled this run; exit and emit an idle status.
    Cancelled,
}

/// Combined generation + cancellation checkpoint. Prefer this over a bare
/// cancel-flag read inside alignment loops so a superseded task bails without
/// emitting over a newer run.
pub(crate) fn polar_loop_control(generation: u64) -> PolarLoopControl {
    if polar_generation().load(PolarOrdering::Relaxed) != generation {
        PolarLoopControl::Superseded
    } else if get_polar_align_cancel().load(PolarOrdering::Relaxed) {
        PolarLoopControl::Cancelled
    } else {
        PolarLoopControl::Continue
    }
}
