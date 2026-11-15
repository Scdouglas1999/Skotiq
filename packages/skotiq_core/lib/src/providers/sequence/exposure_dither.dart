import '../../models/sequence/sequence_models.dart';
import '../../settings/app_settings_state.g.dart';

/// Frames between dithers for [node] as the run executes it: the node's own
/// value, otherwise the global "dither every" when dithering is on. Null or 0
/// is no dither. Calibration frames never dither, whatever this says.
int? exposureDitherEvery(ExposureNode node, AppSettingsState? settings) =>
    node.ditherEvery ??
    ((settings?.ditherEnabled ?? true) ? settings?.ditherEveryFrames : null);
