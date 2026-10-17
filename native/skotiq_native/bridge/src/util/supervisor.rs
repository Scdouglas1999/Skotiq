//! Panic-aware supervision for detached `tokio::spawn` tasks.
//!
//! A bare `tokio::spawn(async move { ... })` whose `JoinHandle` is dropped
//! gives no signal when the spawned task panics: the future silently dies,
//! the feature stops working, and no log line is emitted.
//!
//! This module provides two supervisors:
//!
//! * [`spawn_supervised_oneshot`] — wraps a single future. On panic the
//!   payload is logged via `tracing::error!(target = "supervisor", ...)`
//!   and an optional on-panic callback fires before the outer task ends.
//!   Use this for tasks that legitimately run once and finish (e.g.
//!   polar alignment, one-shot imaging operations).
//!
//! * [`spawn_supervised_restart`] — drives a `Fn() -> Future` factory in
//!   a loop. On panic the supervisor sleeps for an exponentially growing
//!   backoff (capped) and re-invokes the factory, up to `max_restarts`
//!   panics before giving up. The optional `on_give_up` callback fires
//!   once when the budget is exhausted. Use this for tasks that must
//!   stay alive for the lifetime of the app (event bridges, device
//!   heartbeats).
//!
//! Both wrappers preserve `JoinHandle::abort()` semantics: when the
//! outer handle is aborted, the currently running supervised future is
//! cancelled at its next `.await` point just like a bare `tokio::spawn`.

use std::future::Future;
use std::time::Duration;

use futures::FutureExt;
use std::panic::AssertUnwindSafe;
use tokio::task::JoinHandle;

/// Restart policy for [`spawn_supervised_restart`].
#[derive(Debug, Clone, Copy)]
pub struct RestartPolicy {
    /// Maximum number of panics tolerated before the supervisor gives up.
    /// Counts panics only; a clean future return always ends supervision.
    pub max_restarts: u32,
    /// Backoff after the first panic.
    pub initial_backoff: Duration,
    /// Upper bound on backoff between panics.
    pub max_backoff: Duration,
    /// Multiplier applied to backoff after each successive panic.
    pub backoff_multiplier: u32,
}

impl RestartPolicy {
    /// Reasonable default for long-lived loops:
    /// 5 panics, 1s -> 2s -> 4s -> 8s -> 16s (capped at 30s).
    pub const DEFAULT: Self = Self {
        max_restarts: 5,
        initial_backoff: Duration::from_secs(1),
        max_backoff: Duration::from_secs(30),
        backoff_multiplier: 2,
    };

    #[allow(dead_code)] // Public constructor — kept for future callers
    pub const fn new(
        max_restarts: u32,
        initial_backoff: Duration,
        max_backoff: Duration,
        backoff_multiplier: u32,
    ) -> Self {
        Self {
            max_restarts,
            initial_backoff,
            max_backoff,
            backoff_multiplier,
        }
    }
}

/// Extract a human-readable message from a panic payload.
fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        (*s).to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "Unknown panic".to_string()
    }
}

/// Spawn a single future under panic supervision.
///
/// On panic the payload is logged at `error` level (target =
/// `"supervisor"`) and `on_panic` — if provided — is invoked with the
/// panic message. The returned `JoinHandle` resolves once the
/// supervised future finishes, panics, or is cancelled.
pub fn spawn_supervised_oneshot<F, P>(
    name: &'static str,
    future: F,
    on_panic: Option<P>,
) -> JoinHandle<()>
where
    F: Future<Output = ()> + Send + 'static,
    P: FnOnce(&str) + Send + 'static,
{
    tokio::spawn(async move {
        match AssertUnwindSafe(future).catch_unwind().await {
            Ok(()) => {
                tracing::debug!(target: "supervisor", "{name} completed normally");
            }
            Err(payload) => {
                let msg = panic_message(&payload);
                tracing::error!(
                    target: "supervisor",
                    "{name} panicked: {msg}"
                );
                if let Some(cb) = on_panic {
                    cb(&msg);
                }
            }
        }
    })
}

/// Spawn a long-lived future under panic supervision with restart.
///
/// `factory` is invoked to produce the future. If it panics, the
/// supervisor logs the panic, sleeps for the current backoff, multiplies
/// the backoff (capped at `policy.max_backoff`), and re-invokes the
/// factory. After `policy.max_restarts` panics the supervisor stops and
/// `on_give_up` — if provided — fires with the last panic message.
///
/// A clean completion (`future` returned `()` without panicking) ends
/// supervision immediately without restarting.
pub fn spawn_supervised_restart<F, Fut, G>(
    name: &'static str,
    policy: RestartPolicy,
    factory: F,
    on_give_up: Option<G>,
) -> JoinHandle<()>
where
    F: Fn() -> Fut + Send + Sync + 'static,
    Fut: Future<Output = ()> + Send + 'static,
    G: FnOnce(&str) + Send + 'static,
{
    tokio::spawn(async move {
        let mut on_give_up = on_give_up;
        let mut backoff = policy.initial_backoff;
        let mut panic_count: u32 = 0;

        loop {
            let fut = factory();
            match AssertUnwindSafe(fut).catch_unwind().await {
                Ok(()) => {
                    tracing::debug!(
                        target: "supervisor",
                        "{name} completed normally after {panic_count} panic{}; stopping supervision",
                        if panic_count == 1 { "" } else { "s" }
                    );
                    return;
                }
                Err(payload) => {
                    let msg = panic_message(&payload);
                    panic_count = panic_count.saturating_add(1);
                    tracing::error!(
                        target: "supervisor",
                        "{name} panicked (attempt {panic_count}/{}): {msg}",
                        policy.max_restarts
                    );

                    if panic_count >= policy.max_restarts {
                        tracing::error!(
                            target: "supervisor",
                            "{name} exceeded restart budget ({}); giving up. Last panic: {msg}",
                            policy.max_restarts
                        );
                        if let Some(cb) = on_give_up.take() {
                            cb(&msg);
                        }
                        return;
                    }

                    tracing::warn!(
                        target: "supervisor",
                        "{name} restarting in {:?}",
                        backoff
                    );
                    tokio::time::sleep(backoff).await;
                    backoff = backoff
                        .saturating_mul(policy.backoff_multiplier)
                        .min(policy.max_backoff);
                }
            }
        }
    })
}

#[cfg(test)]
#[allow(
    clippy::type_complexity,
    clippy::await_holding_lock // tests serialise tracing-dependent assertions through a std::Mutex
)]
mod tests {
    use super::*;
    use std::io;
    use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
    use std::sync::{Arc, Mutex, Once};
    use tracing_subscriber::fmt::MakeWriter;
    use tracing_subscriber::layer::SubscriberExt;
    use tracing_subscriber::util::SubscriberInitExt;

    /// A `MakeWriter` whose target buffer can be swapped at runtime so a
    /// single globally-installed subscriber can be reused across tests
    /// while still letting each test capture only its own output.
    #[derive(Clone, Default)]
    struct SwappableWriter {
        active: Arc<Mutex<Option<Arc<Mutex<Vec<u8>>>>>>,
    }

    impl SwappableWriter {
        fn install(&self, buf: Arc<Mutex<Vec<u8>>>) -> WriterGuard {
            *self.active.lock().unwrap() = Some(buf);
            WriterGuard {
                active: self.active.clone(),
            }
        }
    }

    impl<'a> MakeWriter<'a> for SwappableWriter {
        type Writer = SwappableWriterHandle;
        fn make_writer(&'a self) -> Self::Writer {
            SwappableWriterHandle {
                active: self.active.clone(),
            }
        }
    }

    struct SwappableWriterHandle {
        active: Arc<Mutex<Option<Arc<Mutex<Vec<u8>>>>>>,
    }

    impl io::Write for SwappableWriterHandle {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            if let Some(target) = self.active.lock().unwrap().as_ref() {
                target.lock().unwrap().extend_from_slice(buf);
            }
            Ok(buf.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    struct WriterGuard {
        active: Arc<Mutex<Option<Arc<Mutex<Vec<u8>>>>>>,
    }

    impl Drop for WriterGuard {
        fn drop(&mut self) {
            *self.active.lock().unwrap() = None;
        }
    }

    static GLOBAL_INIT: Once = Once::new();
    static GLOBAL_WRITER: std::sync::OnceLock<SwappableWriter> = std::sync::OnceLock::new();
    /// Cross-test serialization: tracing's global dispatcher is process-wide
    /// so two tests installing different per-test buffers concurrently would
    /// see each other's log output. We pin tracing-dependent tests onto one
    /// mutex.
    static TRACING_TEST_LOCK: Mutex<()> = Mutex::new(());

    fn install_global_subscriber() -> &'static SwappableWriter {
        GLOBAL_INIT.call_once(|| {
            let writer = SwappableWriter::default();
            GLOBAL_WRITER.set(writer.clone()).ok();
            let layer = tracing_subscriber::fmt::layer()
                .with_writer(writer.clone())
                .with_ansi(false)
                .with_target(true);
            tracing_subscriber::registry()
                .with(layer)
                .with(tracing_subscriber::filter::LevelFilter::TRACE)
                .init();
        });
        GLOBAL_WRITER.get().expect("global writer installed")
    }

    fn capture_logs() -> (WriterGuard, Arc<Mutex<Vec<u8>>>) {
        let writer = install_global_subscriber();
        let buf = Arc::new(Mutex::new(Vec::new()));
        let guard = writer.install(buf.clone());
        (guard, buf)
    }

    fn captured(buf: &Arc<Mutex<Vec<u8>>>) -> String {
        String::from_utf8_lossy(&buf.lock().unwrap()).into_owned()
    }

    #[tokio::test]
    async fn oneshot_catches_panic_and_logs_error() {
        let _serialize = TRACING_TEST_LOCK.lock().unwrap();
        let (_writer_guard, buf) = capture_logs();
        let on_panic_seen = Arc::new(Mutex::new(None::<String>));
        let on_panic_seen_clone = on_panic_seen.clone();

        let handle = spawn_supervised_oneshot(
            "test_task",
            async {
                panic!("synthetic panic for test");
            },
            Some(move |msg: &str| {
                *on_panic_seen_clone.lock().unwrap() = Some(msg.to_string());
            }),
        );

        let join_result = handle.await;
        assert!(
            join_result.is_ok(),
            "supervisor JoinHandle must resolve cleanly even when its supervised future panics, got: {:?}",
            join_result
        );

        let logs = captured(&buf);
        assert!(
            logs.contains("test_task panicked"),
            "expected panic log line, got: {logs}"
        );
        assert!(
            logs.contains("synthetic panic for test"),
            "expected panic message in log, got: {logs}"
        );
        assert!(
            logs.contains("ERROR"),
            "panic log should be at ERROR level, got: {logs}"
        );

        let cb_msg = on_panic_seen.lock().unwrap().clone();
        assert!(
            cb_msg.as_deref().unwrap_or("").contains("synthetic panic"),
            "on_panic callback must receive panic message, got: {:?}",
            cb_msg
        );
    }

    #[tokio::test]
    async fn oneshot_clean_return_does_not_log_error() {
        let _serialize = TRACING_TEST_LOCK.lock().unwrap();
        let (_writer_guard, buf) = capture_logs();
        let handle = spawn_supervised_oneshot::<_, fn(&str)>("clean_task", async {}, None);

        handle.await.expect("clean task should join");

        let logs = captured(&buf);
        assert!(
            !logs.contains("ERROR"),
            "clean exit must not log at ERROR, got: {logs}"
        );
    }

    #[tokio::test]
    async fn restart_retries_until_budget_then_invokes_give_up() {
        let _serialize = TRACING_TEST_LOCK.lock().unwrap();
        let (_writer_guard, buf) = capture_logs();
        let attempt_count = Arc::new(AtomicU32::new(0));
        let attempt_count_clone = attempt_count.clone();
        let gave_up = Arc::new(Mutex::new(None::<String>));
        let gave_up_clone = gave_up.clone();

        let policy = RestartPolicy {
            max_restarts: 3,
            initial_backoff: Duration::from_millis(1),
            max_backoff: Duration::from_millis(4),
            backoff_multiplier: 2,
        };

        let handle = spawn_supervised_restart(
            "flaky_task",
            policy,
            move || {
                let n = attempt_count_clone.fetch_add(1, Ordering::SeqCst) + 1;
                async move {
                    panic!("attempt {n} bombed");
                }
            },
            Some(move |msg: &str| {
                *gave_up_clone.lock().unwrap() = Some(msg.to_string());
            }),
        );

        handle.await.expect("supervisor outer join should succeed");

        let attempts = attempt_count.load(Ordering::SeqCst);
        assert_eq!(
            attempts, policy.max_restarts,
            "factory should be invoked exactly max_restarts times before give-up, got {attempts}"
        );

        let gave_up_msg = gave_up.lock().unwrap().clone();
        assert!(
            gave_up_msg.is_some(),
            "on_give_up callback must fire when budget exhausted"
        );
        assert!(
            gave_up_msg.as_deref().unwrap().contains("attempt 3"),
            "give-up message should reflect last panic, got: {:?}",
            gave_up_msg
        );

        let logs = captured(&buf);
        assert!(
            logs.contains("exceeded restart budget"),
            "expected give-up log, got: {logs}"
        );
    }

    #[tokio::test]
    async fn restart_stops_on_clean_completion() {
        let _serialize = TRACING_TEST_LOCK.lock().unwrap();
        let (_writer_guard, _buf) = capture_logs();
        let calls = Arc::new(AtomicU32::new(0));
        let calls_clone = calls.clone();

        let handle = spawn_supervised_restart::<_, _, fn(&str)>(
            "clean_loop",
            RestartPolicy::DEFAULT,
            move || {
                let n = calls_clone.fetch_add(1, Ordering::SeqCst);
                async move {
                    if n == 0 {
                        panic!("first attempt fails");
                    }
                }
            },
            None,
        );

        handle.await.expect("supervisor must complete");
        assert_eq!(
            calls.load(Ordering::SeqCst),
            2,
            "factory should be invoked twice: once panicking, once clean"
        );
    }

    /// Property test for the requirement directly:
    /// when a supervised future panics, the outer `JoinHandle` MUST resolve
    /// successfully (the supervisor swallows the JoinError), and the
    /// on_panic hook MUST fire — so a caller can never end up with a
    /// silently-dead background task.
    #[tokio::test]
    async fn supervisor_never_propagates_join_error_on_panic() {
        let _serialize = TRACING_TEST_LOCK.lock().unwrap();
        let (_writer_guard, _buf) = capture_logs();
        let fired = Arc::new(AtomicBool::new(false));
        let fired_clone = fired.clone();

        let handle = spawn_supervised_oneshot(
            "panic_guard",
            async { panic!("boom") },
            Some(move |_msg: &str| {
                fired_clone.store(true, Ordering::SeqCst);
            }),
        );

        let outcome = handle.await;
        assert!(
            outcome.is_ok(),
            "outer JoinHandle must be Ok even after inner panic, got: {:?}",
            outcome
        );
        assert!(
            fired.load(Ordering::SeqCst),
            "on_panic hook must fire when inner future panics"
        );
    }
}
