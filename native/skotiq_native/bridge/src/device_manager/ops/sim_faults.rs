//! Fault injection for the device simulators.
//!
//! # Why this exists
//!
//! The simulators were *only* capable of succeeding. Across 1753 lines,
//! `api/devices/simulation.rs` contained nine `Err(` returns, and every one of
//! them was a "you forgot to connect" gate — never a device that connected,
//! answered, and then misbehaved. Real gear misbehaves constantly: an ASCOM
//! driver returns `0x80020009` for a property it does not implement, a USB
//! camera stops answering mid-download, a filter wheel accepts `set_position`
//! and never arrives, a focuser reports the position it was *asked* for rather
//! than the one it reached.
//!
//! A simulator that can only succeed fails in the pass-making direction: the
//! suite stays green while every error path above it goes unexercised. Each
//! fault below corresponds to a failure observed against real hardware —
//! rotator `VT_R4`, the aux heartbeat, ASCOM retry, gain-not-implemented, the
//! INDI BLOB download timeout.
//!
//! # What a fault is
//!
//! A [`FaultSpec`] is a (trigger, effect) pair armed against an operation key
//! such as `"mount.slew"`. The gate helpers in [`super::sim_gate`] consult the
//! registry before doing their normal work, so arming a fault needs no changes
//! at any call site.
//!
//! Faults are **deterministic by default**. `Probability` exists for soak runs
//! and is driven by a seeded xorshift, so a chaos run is replayable from its
//! seed rather than being un-debuggable. Nothing here calls a system RNG or the
//! clock for its decisions.
//!
//! # Arming
//!
//! - From Rust (tests): [`arm`], [`clear`], [`clear_all`].
//! - From a live drive, without a rebuild: the `SKOTIQ_SIM_FAULTS`
//!   environment variable, parsed by [`arm_from_env`]. See [`parse_spec_list`]
//!   for the grammar.
//!
//! # Stalls are not errors
//!
//! [`Effect::Stall`] deliberately returns `Ok(())`. A stalled mount, filter
//! wheel or focuser is the *hardest* real failure for software to handle
//! because nothing reports an error — the command is accepted and the device
//! simply never arrives. The app has to notice via timeout. Returning `Err`
//! here would test the easy path and skip the one that loses a night, so the
//! effect instead sets a latch that the simulator's motion advancers consult
//! (see [`is_stalled`]).

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex as StdMutex, OnceLock};
use std::time::Duration;

/// When a fault fires, relative to the stream of calls against its key.
#[derive(Debug, Clone, PartialEq)]
pub enum Trigger {
    /// Fire on the next `n` calls, then stop. `Times(1)` is the common
    /// "transient glitch the app should retry through" case.
    Times(u32),
    /// Fire on every call until cleared — a hard, persistent failure such as a
    /// property the driver genuinely does not implement.
    Always,
    /// Succeed for `n` calls, then fail on every call after. Models the device
    /// that works during setup and dies an hour into the run, which is the
    /// shape that actually costs a night.
    AfterCalls(u32),
    /// Fire on every `n`-th call. Intermittent faults are worth their own
    /// trigger because "retry once" logic passes `Times(1)` and still cannot
    /// survive a device that fails one call in three.
    EveryNth(u32),
    /// Fire with probability `p` in `[0, 1]`, from a seeded PRNG.
    Probability(f64),
}

/// What the fault does when it fires.
#[derive(Debug, Clone, PartialEq)]
pub enum Effect {
    /// Fail with a driver-style message.
    Error(String),
    /// The driver lost its handle mid-session. Distinct from [`Effect::Error`]
    /// because the app is expected to react differently — surface a
    /// disconnection and attempt reconnect, not retry the operation.
    NotConnected,
    /// Succeed, but only after `ms`. A slow-but-working driver must not be
    /// reported to the user as a failure.
    Delay(u64),
    /// Hang for `ms` and *then* fail. This is the INDI BLOB download timeout
    /// and the ASCOM camera that stops answering mid-read: the operation
    /// consumes the exposure's worth of wall-clock before admitting failure,
    /// so any caller whose own timeout is shorter sees a different (and more
    /// realistic) interleaving than a fast `Err`.
    DelayThenError(u64, String),
    /// Accept the command and never carry it out. Returns `Ok(())`; see the
    /// module note on why this is not an error.
    Stall,
    /// Land `steps` short of the commanded position, in whichever direction the
    /// mechanism was moving. Returns `Ok(())` — like [`Effect::Stall`] this is a
    /// silent mechanical fault, not a driver error, and the only way to detect
    /// it is to re-read the position instead of trusting the command.
    Backlash(i32),
}

/// A fault armed against one operation key.
#[derive(Debug, Clone, PartialEq)]
pub struct FaultSpec {
    pub trigger: Trigger,
    pub effect: Effect,
}

impl FaultSpec {
    pub fn new(trigger: Trigger, effect: Effect) -> Self {
        Self { trigger, effect }
    }

    /// A one-shot transient driver error, the most common real fault.
    #[allow(dead_code)]
    pub fn transient(message: impl Into<String>) -> Self {
        Self::new(Trigger::Times(1), Effect::Error(message.into()))
    }

    /// A property the driver does not implement. `0x80020009`
    /// (`DISP_E_MEMBERNOTFOUND`) is what ASCOM actually returns, and this
    /// project has shipped two separate bugs from treating it as fatal when it
    /// is merely "this camera has no such control".
    pub fn not_implemented() -> Self {
        Self::new(
            Trigger::Always,
            Effect::Error(
                "Exception occurred. (Exception from HRESULT: 0x80020009 \
                 (DISP_E_MEMBERNOTFOUND))"
                    .to_string(),
            ),
        )
    }
}

/// Per-key bookkeeping: the spec plus how many times its key has been called.
#[derive(Debug)]
struct Armed {
    spec: FaultSpec,
    /// Total calls seen against this key, including ones that did not fire.
    calls: u32,
    /// Remaining fires for [`Trigger::Times`].
    remaining: u32,
}

#[derive(Debug, Default)]
struct Registry {
    faults: HashMap<String, Armed>,
    /// Keys currently latched into a stall by [`Effect::Stall`].
    stalled: HashMap<String, bool>,
    /// Backlash, in steps, currently latched on a key by [`Effect::Backlash`].
    backlash: HashMap<String, i32>,
}

fn registry() -> &'static StdMutex<Registry> {
    static REGISTRY: OnceLock<StdMutex<Registry>> = OnceLock::new();
    REGISTRY.get_or_init(|| StdMutex::new(Registry::default()))
}

/// Seeded xorshift64*. A chaos run is reproducible from its seed, which is the
/// difference between a flake you can debug and one you cannot.
fn prng_state() -> &'static AtomicU64 {
    static STATE: OnceLock<AtomicU64> = OnceLock::new();
    STATE.get_or_init(|| AtomicU64::new(0x2545_F491_4F6C_DD1D))
}

/// Re-seed the probability PRNG so a soak run can be replayed exactly.
pub fn seed_prng(seed: u64) {
    // Zero is a fixed point of xorshift, so it would make every draw identical.
    prng_state().store(if seed == 0 { 1 } else { seed }, Ordering::SeqCst);
}

fn next_unit_f64() -> f64 {
    let state = prng_state();
    let mut x = state.load(Ordering::SeqCst);
    x ^= x >> 12;
    x ^= x << 25;
    x ^= x >> 27;
    state.store(x, Ordering::SeqCst);
    // Top 53 bits give a uniform double in [0, 1).
    ((x.wrapping_mul(0x2545_F491_4F6C_DD1D)) >> 11) as f64 / (1u64 << 53) as f64
}

/// Arm `spec` against `key`, replacing any fault already armed there.
///
/// `key` is `"<device>.<operation>"`, e.g. `"camera.download"`,
/// `"mount.slew"`, `"filterwheel.set_position"`. Keys are matched exactly; see
/// [`super::sim_gate`] for the ones the gates consult.
pub fn arm(key: &str, spec: FaultSpec) {
    let remaining = match spec.trigger {
        Trigger::Times(n) => n,
        _ => 0,
    };
    let mut reg = registry().lock().expect("sim fault registry poisoned");
    reg.faults.insert(
        key.to_string(),
        Armed {
            spec,
            calls: 0,
            remaining,
        },
    );
    // Re-arming a key clears the latches left by a previous spec, so tests do
    // not inherit a stuck or backlashed device from an earlier case.
    reg.stalled.remove(key);
    reg.backlash.remove(key);
}

/// Part of the fault-injection CONTROL SURFACE: driven from tests today, and
/// the intended target of a headless/bridge arming endpoint. `#[allow(dead_code)]`
/// rather than deletion because a half-surface is worse than an unused one — a
/// test that can arm a fault but not clear it leaks state into unrelated tests.
/// See `sim_gate::require_focuser_connected` for the same precedent.
/// Disarm `key` and release any stall latched on it.
#[allow(dead_code)]
pub fn clear(key: &str) {
    let mut reg = registry().lock().expect("sim fault registry poisoned");
    reg.faults.remove(key);
    reg.stalled.remove(key);
    reg.backlash.remove(key);
}

/// Disarm everything. Call this between tests: the registry is process-global
/// because the simulators it decorates are, so a leaked fault would surface as
/// an unrelated test failing somewhere else entirely.
#[allow(dead_code)]
pub fn clear_all() {
    let mut reg = registry().lock().expect("sim fault registry poisoned");
    reg.faults.clear();
    reg.stalled.clear();
    reg.backlash.clear();
}

/// Currently armed keys and their specs, for diagnostics and for asserting that
/// a drive actually armed what it meant to.
#[allow(dead_code)]
pub fn armed_keys() -> Vec<(String, FaultSpec)> {
    let reg = registry().lock().expect("sim fault registry poisoned");
    let mut out: Vec<(String, FaultSpec)> = reg
        .faults
        .iter()
        .map(|(k, a)| (k.clone(), a.spec.clone()))
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

/// Whether `key` is latched into a stall.
///
/// The simulator's motion advancers consult this to decide whether to move the
/// device at all, which is how a stall stays invisible to the command that
/// caused it and only shows up as "it never got there".
pub fn is_stalled(key: &str) -> bool {
    matches!(
        registry()
            .lock()
            .expect("sim fault registry poisoned")
            .stalled
            .get(key),
        Some(true)
    )
}

/// Release a stall latch without touching the armed spec, so a test can prove
/// the app recovers once the hardware starts moving again.
#[allow(dead_code)]
pub fn release_stall(key: &str) {
    registry()
        .lock()
        .expect("sim fault registry poisoned")
        .stalled
        .remove(key);
}

/// Release a backlash latch, so a test can prove the app converges once the
/// mechanism behaves.
#[allow(dead_code)]
pub fn release_backlash(key: &str) {
    registry()
        .lock()
        .expect("sim fault registry poisoned")
        .backlash
        .remove(key);
}

/// The decision reached under the registry lock, so no lock is held across an
/// `await`.
enum Decision {
    Proceed,
    Fail(String),
    Sleep(u64),
    SleepThenFail(u64, String),
}

fn decide(key: &str) -> Decision {
    let mut reg = registry().lock().expect("sim fault registry poisoned");
    let Some(armed) = reg.faults.get_mut(key) else {
        return Decision::Proceed;
    };

    armed.calls += 1;
    let calls = armed.calls;

    let fires = match armed.spec.trigger {
        Trigger::Times(_) => {
            if armed.remaining > 0 {
                armed.remaining -= 1;
                true
            } else {
                false
            }
        }
        Trigger::Always => true,
        Trigger::AfterCalls(n) => calls > n,
        // 1-based so `EveryNth(3)` fires on calls 3, 6, 9 — the natural reading
        // of "every third call" — rather than on the first.
        Trigger::EveryNth(n) => n > 0 && calls % n == 0,
        Trigger::Probability(p) => next_unit_f64() < p,
    };

    if !fires {
        return Decision::Proceed;
    }

    match armed.spec.effect.clone() {
        Effect::Error(message) => Decision::Fail(message),
        Effect::NotConnected => Decision::Fail(super::sim_gate::not_connected_injected(key)),
        Effect::Delay(ms) => Decision::Sleep(ms),
        Effect::DelayThenError(ms, message) => Decision::SleepThenFail(ms, message),
        Effect::Stall => {
            reg.stalled.insert(key.to_string(), true);
            Decision::Proceed
        }
        Effect::Backlash(steps) => {
            reg.backlash.insert(key.to_string(), steps);
            Decision::Proceed
        }
    }
}

/// Backlash currently latched on `key`, in steps, if any.
///
/// The simulated mechanism consults this when deciding where it actually landed
/// versus where it was told to go.
pub fn backlash_steps(key: &str) -> Option<i32> {
    registry()
        .lock()
        .expect("sim fault registry poisoned")
        .backlash
        .get(key)
        .copied()
}

/// Consult the registry for `key`.
///
/// Returns `Err` when a fault fires with a failing effect, after applying any
/// delay the effect asks for. [`Effect::Stall`] returns `Ok(())` by design.
pub async fn check(key: &str) -> Result<(), String> {
    match decide(key) {
        Decision::Proceed => Ok(()),
        Decision::Fail(message) => {
            tracing::warn!(key, message, "simulator fault injected");
            Err(message)
        }
        Decision::Sleep(ms) => {
            tracing::warn!(key, ms, "simulator fault injected: delay");
            tokio::time::sleep(Duration::from_millis(ms)).await;
            Ok(())
        }
        Decision::SleepThenFail(ms, message) => {
            tracing::warn!(
                key,
                ms,
                message,
                "simulator fault injected: delay then error"
            );
            tokio::time::sleep(Duration::from_millis(ms)).await;
            Err(message)
        }
    }
}

// Environment-variable arming

/// Parse `SKOTIQ_SIM_FAULTS` and arm everything it names.
///
/// Called once during simulator setup so a live drive can inject faults into a
/// release build without a rebuild or a code change.
pub fn arm_from_env() {
    let Ok(raw) = std::env::var("SKOTIQ_SIM_FAULTS") else {
        return;
    };
    match parse_spec_list(&raw) {
        Ok(specs) => {
            if let Ok(seed) = std::env::var("SKOTIQ_SIM_FAULT_SEED") {
                if let Ok(seed) = seed.parse::<u64>() {
                    seed_prng(seed);
                }
            }
            for (key, spec) in specs {
                tracing::warn!(?key, ?spec, "arming simulator fault from environment");
                arm(&key, spec);
            }
        }
        // A typo'd fault spec must not silently mean "no faults" — that would
        // make a drive report a clean pass it never actually earned.
        Err(e) => tracing::error!(
            "SKOTIQ_SIM_FAULTS could not be parsed ({e}); NO faults were armed. \
             Fix the spec rather than trusting this run."
        ),
    }
}

/// Grammar: `key=trigger:effect` entries separated by `,`.
///
/// Triggers: `once`, `times(N)`, `always`, `after(N)`, `every(N)`, `p(0.25)`.
/// Effects: `error`, `error(msg)`, `notconnected`, `delay(MS)`,
/// `delaythenerror(MS)`, `delaythenerror(MS,msg)`, `stall`, `backlash(STEPS)`,
/// `notimplemented`.
///
/// Example: `mount.slew=once:error,camera.download=always:delaythenerror(30000)`
pub fn parse_spec_list(raw: &str) -> Result<Vec<(String, FaultSpec)>, String> {
    let mut out = Vec::new();
    for entry in split_entries(raw) {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        let (key, rest) = entry
            .split_once('=')
            .ok_or_else(|| format!("entry '{entry}' is missing '=' (want key=trigger:effect)"))?;
        let key = key.trim();
        if key.is_empty() {
            return Err(format!("entry '{entry}' has an empty key"));
        }
        let (trigger_raw, effect_raw) = rest
            .split_once(':')
            .ok_or_else(|| format!("entry '{entry}' is missing ':' (want key=trigger:effect)"))?;
        let trigger = parse_trigger(trigger_raw.trim())?;
        let effect = parse_effect(effect_raw.trim())?;
        out.push((key.to_string(), FaultSpec::new(trigger, effect)));
    }
    if out.is_empty() {
        return Err("no fault entries found".to_string());
    }
    Ok(out)
}

/// Split a spec list on commas that separate ENTRIES, ignoring commas nested
/// inside an effect's parentheses.
///
/// A naive `split(',')` breaks `delaythenerror(20,late)` in half, which then
/// surfaces as the confusing "unknown effect 'delaythenerror(20'". The nesting
/// depth is what distinguishes a separator from an argument comma.
fn split_entries(raw: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut start = 0usize;
    for (i, ch) in raw.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => depth = (depth - 1).max(0),
            ',' if depth == 0 => {
                out.push(&raw[start..i]);
                start = i + ch.len_utf8();
            }
            _ => {}
        }
    }
    out.push(&raw[start..]);
    out
}

/// Split `name(arg)` into its parts, or return `(input, None)`.
fn split_call(raw: &str) -> (&str, Option<&str>) {
    match raw.split_once('(') {
        Some((name, rest)) => match rest.strip_suffix(')') {
            Some(arg) => (name.trim(), Some(arg)),
            // Unbalanced parens fall through as a bare name so the caller
            // reports "unknown trigger/effect" against the whole token.
            None => (raw, None),
        },
        None => (raw, None),
    }
}

fn parse_u32_arg(name: &str, arg: Option<&str>) -> Result<u32, String> {
    let arg = arg.ok_or_else(|| format!("{name} needs an argument, e.g. {name}(3)"))?;
    arg.trim()
        .parse::<u32>()
        .map_err(|_| format!("{name} argument '{arg}' is not a non-negative integer"))
}

fn parse_trigger(raw: &str) -> Result<Trigger, String> {
    let (name, arg) = split_call(raw);
    match name.to_ascii_lowercase().as_str() {
        "once" => Ok(Trigger::Times(1)),
        "times" => Ok(Trigger::Times(parse_u32_arg("times", arg)?)),
        "always" => Ok(Trigger::Always),
        "after" => Ok(Trigger::AfterCalls(parse_u32_arg("after", arg)?)),
        "every" => {
            let n = parse_u32_arg("every", arg)?;
            if n == 0 {
                return Err("every(0) would never fire".to_string());
            }
            Ok(Trigger::EveryNth(n))
        }
        "p" | "prob" | "probability" => {
            let arg = arg.ok_or_else(|| "p needs an argument, e.g. p(0.25)".to_string())?;
            let p = arg
                .trim()
                .parse::<f64>()
                .map_err(|_| format!("probability '{arg}' is not a number"))?;
            if !(0.0..=1.0).contains(&p) {
                return Err(format!("probability {p} is outside [0, 1]"));
            }
            Ok(Trigger::Probability(p))
        }
        other => Err(format!(
            "unknown trigger '{other}' (want once/times(N)/always/after(N)/every(N)/p(F))"
        )),
    }
}

/// The message used when an `error` effect is armed without explicit text.
const DEFAULT_INJECTED_ERROR: &str = "Injected simulator fault: the driver reported a failure";

fn parse_effect(raw: &str) -> Result<Effect, String> {
    let (name, arg) = split_call(raw);
    match name.to_ascii_lowercase().as_str() {
        "error" => Ok(Effect::Error(match arg {
            Some(m) if !m.trim().is_empty() => m.trim().to_string(),
            _ => DEFAULT_INJECTED_ERROR.to_string(),
        })),
        "notimplemented" => Ok(FaultSpec::not_implemented().effect),
        "notconnected" => Ok(Effect::NotConnected),
        "delay" => Ok(Effect::Delay(parse_u32_arg("delay", arg)? as u64)),
        "delaythenerror" => {
            let arg = arg.ok_or_else(|| "delaythenerror needs at least a duration".to_string())?;
            let (ms_raw, message) = match arg.split_once(',') {
                Some((ms, msg)) => (ms, msg.trim().to_string()),
                None => (arg, DEFAULT_INJECTED_ERROR.to_string()),
            };
            let ms = ms_raw
                .trim()
                .parse::<u64>()
                .map_err(|_| format!("delaythenerror duration '{ms_raw}' is not milliseconds"))?;
            Ok(Effect::DelayThenError(ms, message))
        }
        "stall" => Ok(Effect::Stall),
        "backlash" => {
            let arg =
                arg.ok_or_else(|| "backlash needs a step count, e.g. backlash(40)".to_string())?;
            let steps = arg
                .trim()
                .parse::<i32>()
                .map_err(|_| format!("backlash argument '{arg}' is not a step count"))?;
            Ok(Effect::Backlash(steps))
        }
        other => Err(format!(
            "unknown effect '{other}' (want error(msg)/notimplemented/notconnected/\
             delay(MS)/delaythenerror(MS,msg)/stall)"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The registry is process-global, so every test arms under its own key
    /// prefix and clears afterwards. Without this a leaked fault surfaces as an
    /// unrelated test failing elsewhere.
    ///
    /// Clearing its own keys is not enough on its own: the simulator tests in
    /// `sim_gate` and `cover` call [`clear_all`], which wipes the whole
    /// registry, so a concurrent run can disarm a fault between the `arm` and
    /// the `check`. The global PRNG behind `Trigger::Probability` is shared the
    /// same way.
    ///
    /// The guard therefore also holds the lock those tests take. Acquiring it
    /// is what serialises the registry; the per-key clear only keeps a leaked
    /// fault from outliving the test that armed it.
    struct Guard {
        keys: &'static [&'static str],
        _serialized: tokio::sync::MutexGuard<'static, ()>,
    }

    impl Guard {
        async fn new(keys: &'static [&'static str]) -> Self {
            let serialized = crate::api::devices::simulation::sim_singleton_test_lock()
                .lock()
                .await;
            for key in keys {
                clear(key);
            }
            Self {
                keys,
                _serialized: serialized,
            }
        }
    }

    impl Drop for Guard {
        fn drop(&mut self) {
            for key in self.keys {
                clear(key);
            }
        }
    }

    #[tokio::test]
    async fn an_unarmed_key_always_proceeds() {
        assert!(check("test.unarmed.nothing_here").await.is_ok());
    }

    #[tokio::test]
    async fn times_one_fires_exactly_once() {
        let _g = Guard::new(&["test.times1"]).await;
        arm("test.times1", FaultSpec::transient("boom"));
        assert_eq!(check("test.times1").await, Err("boom".to_string()));
        assert!(
            check("test.times1").await.is_ok(),
            "a Times(1) fault fired twice, so 'retry once' logic could never pass"
        );
    }

    #[tokio::test]
    async fn always_keeps_firing() {
        let _g = Guard::new(&["test.always"]).await;
        arm("test.always", FaultSpec::not_implemented());
        for _ in 0..5 {
            let err = check("test.always").await.expect_err("must keep failing");
            assert!(err.contains("0x80020009"), "got {err}");
        }
    }

    #[tokio::test]
    async fn after_calls_succeeds_then_dies() {
        let _g = Guard::new(&["test.after"]).await;
        arm(
            "test.after",
            FaultSpec::new(Trigger::AfterCalls(2), Effect::Error("usb gone".into())),
        );
        assert!(check("test.after").await.is_ok());
        assert!(check("test.after").await.is_ok());
        assert!(check("test.after").await.is_err());
        assert!(check("test.after").await.is_err());
    }

    /// `every(3)` must fire on the 3rd call, not the 1st — an off-by-one here
    /// would silently turn an intermittent fault into an immediate one.
    #[tokio::test]
    async fn every_nth_fires_on_the_nth_call() {
        let _g = Guard::new(&["test.every"]).await;
        arm(
            "test.every",
            FaultSpec::new(Trigger::EveryNth(3), Effect::Error("flake".into())),
        );
        let outcomes: Vec<bool> = {
            let mut v = Vec::new();
            for _ in 0..6 {
                v.push(check("test.every").await.is_err());
            }
            v
        };
        assert_eq!(outcomes, vec![false, false, true, false, false, true]);
    }

    #[tokio::test]
    async fn not_connected_names_the_key_it_came_from() {
        let _g = Guard::new(&["test.notconnected"]).await;
        arm(
            "test.notconnected",
            FaultSpec::new(Trigger::Always, Effect::NotConnected),
        );
        let err = check("test.notconnected").await.expect_err("must fail");
        assert!(
            err.contains("not connected"),
            "the app distinguishes disconnection from operation failure: {err}"
        );
    }

    /// A stall must NOT surface as an error — that is the entire point. It has
    /// to look like a successful command whose device never arrives.
    #[tokio::test]
    async fn stall_reports_success_and_latches() {
        let _g = Guard::new(&["test.stall"]).await;
        arm("test.stall", FaultSpec::new(Trigger::Always, Effect::Stall));
        assert!(!is_stalled("test.stall"));
        assert!(
            check("test.stall").await.is_ok(),
            "a stalled device accepts the command; only a timeout can detect it"
        );
        assert!(is_stalled("test.stall"));
        release_stall("test.stall");
        assert!(!is_stalled("test.stall"));
    }

    #[tokio::test]
    async fn delay_then_error_waits_before_failing() {
        let _g = Guard::new(&["test.dte"]).await;
        arm(
            "test.dte",
            FaultSpec::new(
                Trigger::Times(1),
                Effect::DelayThenError(60, "download timed out".into()),
            ),
        );
        let started = std::time::Instant::now();
        let err = check("test.dte").await.expect_err("must fail");
        assert_eq!(err, "download timed out");
        assert!(
            started.elapsed() >= Duration::from_millis(50),
            "returned in {:?}; a download timeout that fails instantly does not \
             exercise the caller's own timeout",
            started.elapsed()
        );
    }

    /// Backlash, like a stall, must report success — the mechanism moved, just
    /// not to where it was told. Only re-reading the position can catch it.
    #[tokio::test]
    async fn backlash_reports_success_and_latches_its_step_count() {
        let _g = Guard::new(&["test.backlash"]).await;
        assert_eq!(backlash_steps("test.backlash"), None);
        arm(
            "test.backlash",
            FaultSpec::new(Trigger::Always, Effect::Backlash(40)),
        );
        assert!(check("test.backlash").await.is_ok());
        assert_eq!(backlash_steps("test.backlash"), Some(40));
        release_backlash("test.backlash");
        assert_eq!(backlash_steps("test.backlash"), None);
    }

    #[tokio::test]
    async fn re_arming_clears_a_latched_stall() {
        let _g = Guard::new(&["test.rearm"]).await;
        arm("test.rearm", FaultSpec::new(Trigger::Always, Effect::Stall));
        assert!(check("test.rearm").await.is_ok());
        assert!(is_stalled("test.rearm"));
        arm("test.rearm", FaultSpec::transient("different fault"));
        assert!(
            !is_stalled("test.rearm"),
            "a test inherited a stuck device from the previous case"
        );
    }

    #[tokio::test]
    async fn probability_is_reproducible_from_its_seed() {
        let _g = Guard::new(&["test.prob"]).await;
        let run = || async {
            seed_prng(12345);
            arm(
                "test.prob",
                FaultSpec::new(Trigger::Probability(0.5), Effect::Error("chaos".into())),
            );
            let mut v = Vec::new();
            for _ in 0..24 {
                v.push(check("test.prob").await.is_err());
            }
            v
        };
        let first = run().await;
        let second = run().await;
        assert_eq!(
            first, second,
            "a chaos run must be replayable from its seed"
        );
        assert!(
            first.iter().any(|f| *f) && first.iter().any(|f| !*f),
            "p=0.5 produced {first:?}, which is not a mix"
        );
    }

    #[tokio::test]
    async fn armed_keys_reports_what_is_armed() {
        // One guard for both keys: two would deadlock on the same lock.
        let _g = Guard::new(&["test.list.a", "test.list.b"]).await;
        arm("test.list.a", FaultSpec::transient("a"));
        arm("test.list.b", FaultSpec::not_implemented());
        let keys: Vec<String> = armed_keys().into_iter().map(|(k, _)| k).collect();
        assert!(keys.contains(&"test.list.a".to_string()));
        assert!(keys.contains(&"test.list.b".to_string()));
    }

    // -- spec parsing ------------------------------------------------------

    #[test]
    fn parses_the_documented_example() {
        let specs =
            parse_spec_list("mount.slew=once:error,camera.download=always:delaythenerror(30000)")
                .expect("documented example must parse");
        assert_eq!(specs.len(), 2);
        assert_eq!(specs[0].0, "mount.slew");
        assert_eq!(specs[0].1.trigger, Trigger::Times(1));
        assert_eq!(specs[1].0, "camera.download");
        assert_eq!(specs[1].1.trigger, Trigger::Always);
        match &specs[1].1.effect {
            Effect::DelayThenError(ms, _) => assert_eq!(*ms, 30_000),
            other => panic!("expected DelayThenError, got {other:?}"),
        }
    }

    #[test]
    fn parses_every_trigger_and_effect_form() {
        let raw = "a=once:error,b=times(4):notconnected,c=always:stall,\
                   d=after(7):notimplemented,e=every(2):delay(15),\
                   f=p(0.5):delaythenerror(20,late),g=once:error(custom text)";
        let specs = parse_spec_list(raw).expect("all documented forms must parse");
        let by_key: HashMap<String, FaultSpec> = specs.into_iter().collect();
        assert_eq!(by_key["a"].trigger, Trigger::Times(1));
        assert_eq!(by_key["b"].trigger, Trigger::Times(4));
        assert_eq!(by_key["b"].effect, Effect::NotConnected);
        assert_eq!(by_key["c"].effect, Effect::Stall);
        assert_eq!(by_key["d"].trigger, Trigger::AfterCalls(7));
        assert_eq!(by_key["e"].trigger, Trigger::EveryNth(2));
        assert_eq!(by_key["e"].effect, Effect::Delay(15));
        assert_eq!(by_key["f"].trigger, Trigger::Probability(0.5));
        assert_eq!(
            by_key["f"].effect,
            Effect::DelayThenError(20, "late".to_string())
        );
        assert_eq!(
            by_key["g"].effect,
            Effect::Error("custom text".to_string()),
            "a custom message must survive parsing"
        );
    }

    /// An effect argument may itself contain a comma, so entry splitting has to
    /// respect parenthesis depth. Splitting naively cut `delaythenerror(20,late)`
    /// in half and reported the nonsensical "unknown effect 'delaythenerror(20'".
    #[test]
    fn a_comma_inside_an_effect_argument_is_not_an_entry_separator() {
        let specs = parse_spec_list(
            "camera.download=once:delaythenerror(30000,BLOB read timed out),mount.slew=always:stall",
        )
        .expect("a comma inside parentheses must not split the entry");
        assert_eq!(specs.len(), 2, "got {specs:?}");
        assert_eq!(specs[0].0, "camera.download");
        assert_eq!(
            specs[0].1.effect,
            Effect::DelayThenError(30_000, "BLOB read timed out".to_string())
        );
        assert_eq!(specs[1].0, "mount.slew");
        assert_eq!(specs[1].1.effect, Effect::Stall);
    }

    /// A malformed spec must be a loud parse error. Treating it as "no faults"
    /// would let a drive report a clean pass it never earned.
    #[test]
    fn malformed_specs_are_rejected_not_ignored() {
        for bad in [
            "",
            "no_equals_sign",
            "key=missing_colon",
            "=always:error",
            "key=bogus:error",
            "key=always:bogus",
            "key=times:error",
            "key=every(0):error",
            "key=p(2.0):error",
            "key=delay(notanumber):x",
        ] {
            assert!(
                parse_spec_list(bad).is_err(),
                "'{bad}' parsed successfully but is not a valid spec"
            );
        }
    }
}
