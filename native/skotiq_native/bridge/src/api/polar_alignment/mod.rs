//
// # `as`-cast policy
//
// Numeric casts in this file cluster into:
// - **Image dim u32 → u32** (lines 109, 110, 135, 136, 792, 793): `image.width`
//   and `image.height` are already u32; the `as u32` is a no-op widening
//   useful only for clippy disambiguation when builders accept ambiguous
//   types. Kept as documentation.
// - **PolarAlignmentPoint enum → i32** (lines 302, 326, 335, 385, 401, 403,
//   411): the enum has 3 discriminants {0, 1, 2}; `as i32` extracts the
//   value — SAFE narrowing from default isize repr.
// - **Step size f64 → i32** (line 401): bounded by mount slew step (≤ 90°
//   typical); used only in a display string, not a hardware command.

pub mod entrypoints;
pub mod events;
#[cfg(test)]
mod polar_run_control_tests;
pub mod pole_slew;
pub mod run_control;
pub mod run_loop;
pub mod solve;
