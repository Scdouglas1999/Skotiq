//! FFI entry points of the sky atlas.
//!
//! The work is in [`skotiq_processing::sky_atlas`].

pub mod frames;
pub mod regions;

/// Sky-atlas dispatcher. `args_json` carries an `"action"` selecting the
/// operation; the remaining fields are the action-specific payload documented in
/// `docs/skotiq_5_0_contracts.md` §2.1. Returns the action's JSON result.
pub fn api_sky_atlas(args_json: String) -> Result<String, String> {
    skotiq_processing::sky_atlas::sky_atlas(args_json)
}
