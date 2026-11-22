//! One solver process at a time, across every caller in the process.
//!
//! External solvers write sibling `.ini`/`.wcs` artifacts; allowing
//! overlapping runs can mix or delete another solve's result.

use std::sync::OnceLock;
use std::time::Instant;
use tokio::sync::{Mutex, MutexGuard};

static PLATE_SOLVE_GATE: OnceLock<Mutex<()>> = OnceLock::new();

fn plate_solve_gate() -> &'static Mutex<()> {
    PLATE_SOLVE_GATE.get_or_init(|| Mutex::new(()))
}

/// Take the gate, saying so when the caller has to wait.
///
/// A solve that queues behind another solve looks, from the outside, exactly
/// like a slow solve. Naming the wait is what turns "the solver is slow"
/// into "two callers are solving at once".
pub async fn acquire_solve_gate(label: &str) -> MutexGuard<'static, ()> {
    let gate = plate_solve_gate();
    match gate.try_lock() {
        Ok(guard) => guard,
        Err(_) => {
            let waited = Instant::now();
            let guard = gate.lock().await;
            tracing::info!(
                "Plate solve ({label}): waited {:.1}s for another solve to finish \
                 (one solver process at a time)",
                waited.elapsed().as_secs_f64()
            );
            guard
        }
    }
}
