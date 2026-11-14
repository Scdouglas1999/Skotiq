import '../../database/database.dart' show DbCapturedImage;
import 'gain_kind.dart';

/// A recorded frame's gain, read the way the frame recorded it.
extension FrameGain on DbCapturedImage {
  GainKind get recordedGainKind => GainKind.fromRecord(gainKind);

  /// The gain this frame is matched by; null when its ISO is unknown (an
  /// older DSLR frame that stored the position in the camera's ISO list).
  int? get comparableGain => recordedGainKind.isKnown ? gain : null;

  /// Whether this frame's gain is a DSLR ISO-list position, not an ISO.
  bool get hasUnknownIso => gain != null && !recordedGainKind.isKnown;

  /// "gain 100", "ISO 800", or the ISO-list position; null when no gain was
  /// recorded.
  String? get gainText =>
      gain == null ? null : recordedGainKind.describe(gain!);
}
