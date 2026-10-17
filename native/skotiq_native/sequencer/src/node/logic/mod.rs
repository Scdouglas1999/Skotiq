//! Container / logic node implementations.
//!
//! These nodes need `&mut self.children` (and, for Loop, `&mut self.current_iteration`)
//! access on `RuntimeNode`, which makes them awkward to push through a trait-object
//! dispatch. Each logic file exposes a free-standing `execute_*(node, config, context)`
//! function that takes a `&mut RuntimeNode`, so the implementations live
//! outside the dispatch match without owning RuntimeNode's internals.

pub mod conditional;
pub mod loop_node;
pub mod parallel;
pub mod recovery;
pub mod sequential;
pub mod target_header;
// TargetScheduler — dynamic target picker.
pub mod target_scheduler;
