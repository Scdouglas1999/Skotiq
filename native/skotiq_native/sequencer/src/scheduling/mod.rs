//! Target scheduling — Rust port of the planetarium scoring math.
//!
//! The executor cannot call Dart, so the `TargetScheduler` logic node needs a
//! native scoring authority. This module ports the multi-factor scoring from
//! `packages/skotiq_planetarium/lib/src/planning/target_scoring.dart` to
//! Rust 1:1 (same weights, same break-points, same airmass formula). The
//! Dart-side service continues to power the planetarium UI; the new Rust
//! module is the runtime authority for in-sequence scheduling decisions.
//!
//! A parity test in `scoring_tests` fixes a representative observer / target /
//! moon / time and asserts that both implementations agree within
//! floating-point tolerance.

pub mod adaptive_exposure;
pub mod adaptive_swap;
pub mod astronomy;
pub mod clock;
pub mod ephemeris;
pub mod frame_context;
pub mod integration_budget;
pub mod scoring;
pub mod target_trigger;

pub use adaptive_exposure::*;
pub use adaptive_swap::*;
pub use astronomy::*;
pub use clock::*;
pub use frame_context::*;
pub use integration_budget::*;
pub use scoring::*;
pub use target_trigger::*;
