//! Image Grading: live image grading + auto-reject.
//!
//! See [`image_grading`] for the grading types and entry point.

pub mod filter_baseline;
pub mod forensics;
pub mod image_grading;

pub use filter_baseline::{airmass, filter_baseline_key, FilterBaseline, FilterBaselines};
pub use forensics::{
    analyze_rejection, EnvironmentSnapshot, ForensicInputs, ForensicVerdict, LikelyCause,
    RecentFrameSample, FORENSIC_HISTORY_LEN,
};
pub use image_grading::*;
