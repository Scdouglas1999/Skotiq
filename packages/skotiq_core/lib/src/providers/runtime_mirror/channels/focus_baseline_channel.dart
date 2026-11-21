import '../../equipment/focuser_temp_compensation_provider.dart';
import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The host's focus-compensation reference, for a viewer that does not run
/// the compensator. Host to client only: a client report must not move the
/// reference the host measures from.
class FocusBaselineChannel
    extends RuntimeMirrorChannel<FocuserTempCompensationBaseline?> {
  const FocusBaselineChannel();

  @override
  String get key => 'focusBaseline';

  @override
  get source => focuserTempCompensationBaselineProvider;

  @override
  Map<String, dynamic>? encode(FocuserTempCompensationBaseline? value) {
    if (value == null) return null;
    return {
      'temperature': finiteOrNull(value.temperature),
      'position': value.position,
      'capturedAt': value.capturedAt.toUtc().millisecondsSinceEpoch,
    };
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final notifier = context.read(
      focuserTempCompensationBaselineProvider.notifier,
    );
    if (value == null) {
      notifier.state = null;
      return;
    }
    final temperature = jsonDouble(value['temperature']);
    final position = jsonInt(value['position']);
    final capturedAt = jsonInt(value['capturedAt']);
    if (temperature == null || position == null || capturedAt == null) {
      notifier.state = null;
      return;
    }
    notifier.state = FocuserTempCompensationBaseline(
      temperature: temperature,
      position: position,
      capturedAt: DateTime.fromMillisecondsSinceEpoch(capturedAt, isUtc: true),
    );
  }
}
