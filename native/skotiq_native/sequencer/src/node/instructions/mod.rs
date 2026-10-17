//! Per-instruction `InstructionNode` implementations.
//!
//! One file per `NodeType` instruction variant. Each file holds a zero-sized
//! unit struct and an `#[async_trait] impl InstructionNode` block that:
//!   1. Unwraps the relevant `NodeType` variant to its config.
//!   2. Builds an `InstructionContext` from the `ExecutionContext`.
//!   3. Constructs a progress-forwarding closure that calls
//!      `context.send_progress(ProgressUpdate::instruction_progress(...))`.
//!   4. Invokes the matching `crate::instructions::execute_*` (or sibling)
//!      function and converts the `InstructionResult` to a `NodeStatus`.
//!
//! The container/logic variants (TargetHeader, Loop, Parallel, Conditional,
//! Recovery) are NOT here — they live in `node::logic` because they need
//! `&mut self.children` access from RuntimeNode.

pub mod autofocus;
pub mod calibrator_off;
pub mod calibrator_on;
pub mod center;
pub mod change_filter;
pub mod close_cover;
pub mod close_dome;
pub mod cool_camera;
pub mod delay;
pub mod dither;
pub mod expose;
pub mod flat_wizard;
// LiveStacking — EAA / outreach broadcast node.
pub mod live_stacking;
pub mod meridian_flip;
pub mod mosaic;
pub mod move_rotator;
pub mod notification;
// PluginNode — Rust↔Dart roundtrip dispatcher for
// plugin-contributed sequence nodes.
pub mod open_cover;
pub mod open_dome;
pub mod park;
pub mod park_dome;
pub mod plugin_node;
pub mod polar_alignment;
pub mod run_script;
// Science: SciencePhotometry — cadence-enforced photometric capture
// that delegates to TakeExposure and layers in per-frame photometric
// reduction + transparency-adaptive coordination.
pub mod science_photometry;
pub mod slew;
// SmartExposure — one-row-per-filter automation that
// delegates to ChangeFilter + TakeExposure internally.
pub mod smart_exposure;
pub mod start_guiding;
pub mod stop_guiding;
pub mod temperature_compensation;
pub mod unpark;
pub mod wait_for_time;
pub mod warm_camera;
