/// The single source of truth for how deep the bundled HYG star catalog
/// actually goes.
///
/// Kept in a leaf library (no imports) so every surface that states the
/// catalog's depth quotes the same number: the catalog-package "Depth" chip,
/// the Layers panel subtitle, the deep-star tier copy and the HYG/deep-tier
/// merge seam.
library;

/// Magnitude to which the bundled HYG catalog is COMPLETE.
///
/// Not the faintest row it contains: the loader admits entries down to mag 15,
/// but counting the installed file (119,626 rows) the per-magnitude gain turns
/// over after 9 — 25,690 stars in 7-8, 41,975 in 8-9, then only 24,814 in 9-10
/// and 7,580 in 10-11. HYG is Hipparcos-derived, so 9 is where the sky it can
/// draw runs out. Stating the faintest row instead told the user that the
/// empty field on screen was the real sky.
const double kHygFaintFloorMag = 9.0;
