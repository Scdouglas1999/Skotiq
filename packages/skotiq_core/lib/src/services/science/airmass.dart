/// The product's one airmass model, reached from science code.
///
/// The implementation is `airmassForTrueAltitude` in `skotiq_planetarium`
/// (`src/astronomy/astronomy_calculations.dart`). It cannot live here: the
/// package dependency edge runs skotiq_core -> skotiq_planetarium, and
/// the planner needs airmass too, so core is not a place every Dart consumer
/// can import from. This file exists only so science code keeps a science-shaped
/// import instead of reaching across into a planetarium library by hand.
///
/// There is no formula in this file, and there must never be one — a local copy
/// here is precisely how the AAVSO exporter, the calibration wizard, the science
/// pipeline and the planner ended up publishing four different atmospheres for
/// the same frame.
library;

export 'package:skotiq_planetarium/skotiq_planetarium.dart'
    show airmassForTrueAltitude;
