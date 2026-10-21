//! Color composites from a target's per-filter masters.
//!
//! * [`filters`] — which filters were used and how they combine.
//! * [`align`] — registering the masters onto one reference grid.
//! * [`mix`] — flux matching, session averaging and the luminance layer.
//!
//! The Darkroom operation `channel_combine@1`
//! ([`crate::recipe::ops::channel_combine`]) is the recipe step built on these.

pub mod align;
pub mod filters;
pub mod mix;

#[cfg(test)]
pub(crate) mod test_scene;

use std::collections::BTreeMap;
use std::sync::Arc;

use crate::recipe::{ImagePyramid, MasterSource, OpImage};

pub use align::{
    alignment_check, overlap_rect, register_onto, star_sigma, warp_window, Affine2, Alignment,
    AlignmentCheck, Rect,
};
pub use filters::{
    classify_filter, plan_filter_set, FilterRole, FilterSetInput, FilterSetPlan, Palette,
    PlannedInput,
};
pub use mix::{apply_luminance, robust_fit, LinearFit};

/// A [`MasterSource`] over pyramids already in memory.
#[derive(Default, Clone)]
pub struct PyramidSources {
    masters: BTreeMap<String, (String, Arc<ImagePyramid>)>,
}

impl PyramidSources {
    /// An empty source.
    pub fn new() -> Self {
        Self::default()
    }

    /// Add the master at `path`, whose bytes are identified by `identity`.
    pub fn insert(
        &mut self,
        path: impl Into<String>,
        identity: impl Into<String>,
        pyramid: Arc<ImagePyramid>,
    ) {
        self.masters.insert(path.into(), (identity.into(), pyramid));
    }

    /// Whether no master is held.
    pub fn is_empty(&self) -> bool {
        self.masters.is_empty()
    }
}

impl MasterSource for PyramidSources {
    fn level(&self, path: &str, level: u32) -> Result<Arc<OpImage>, String> {
        let (_, pyramid) = self
            .masters
            .get(path)
            .ok_or_else(|| format!("the master '{path}' was not loaded for this render"))?;
        pyramid.level(level).cloned().ok_or_else(|| {
            format!(
                "the master '{path}' has {} pyramid level{}, so level {level} does not exist",
                pyramid.level_count(),
                if pyramid.level_count() == 1 { "" } else { "s" }
            )
        })
    }

    fn identity(&self) -> String {
        self.masters
            .iter()
            .map(|(path, (identity, _))| format!("{path}={identity}"))
            .collect::<Vec<_>>()
            .join(";")
    }
}
