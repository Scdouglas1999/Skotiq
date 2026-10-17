/// The dawn autopilot: the Darkroom half of "wake up to a finished image".
///
/// Read in this order:
///
///  * [DarkroomSeam] — the injectable boundary over the Darkroom FFI entry
///    points, and the typed cancelled outcome both it and the post-session
///    surface report.
///  * [DawnMasterResolver] — which linear masters a night produced, derived
///    from the database so a resumed job reads the same inputs as a fresh one.
///  * [DawnPhotometryResolver] — the catalogue stars the colour calibration
///    regresses against, or the stated reason there are none.
///  * [DawnDraftBuilder] — the first-draft recipe, composed from the registry's
///    own measurements with the background retry and the full-resolution colour
///    proof on top.
///  * [DawnJobReport] — the morning report, and the calibration account read
///    back out of the master's own row.
///  * [DawnAutopilotService] — the durable job that runs all of it.
library;

export 'darkroom_seam.dart';
export 'dawn_autopilot_providers.dart';
export 'dawn_autopilot_service.dart';
export 'dawn_draft_builder.dart';
export 'dawn_job_report.dart';
export 'dawn_master_resolver.dart';
export 'dawn_morning_notifier.dart';
export 'dawn_photometry.dart';
