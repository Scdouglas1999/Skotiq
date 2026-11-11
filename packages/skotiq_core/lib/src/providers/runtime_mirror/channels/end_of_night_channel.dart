import '../../../services/end_of_night_calibration/eon_providers.dart';
import '../../../services/end_of_night_calibration/eon_service.dart';
import '../../host_end_of_night_provider.dart';
import '../../ui_notification_provider.dart';
import '../runtime_mirror_channel.dart';

/// Where the host's end-of-night calibration stands: its phase, what it is
/// doing, and while it waits for a cap, when the darks are skipped. The
/// report stays on the host.
class EndOfNightChannel extends RuntimeMirrorChannel<EonStatus> {
  const EndOfNightChannel();

  @override
  String get key => 'endOfNight';

  @override
  get source => endOfNightCalibrationProvider;

  @override
  Map<String, dynamic>? encode(EonStatus value) =>
      value.toJson()..remove('report');

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (context.networkBackend == null) return;
    final next = EonStatus.fromHostJson(value);
    final notifier = context.read(hostEndOfNightStatusProvider.notifier);
    final previous = notifier.state;
    notifier.state = next;
    // Said once, when the host starts waiting: the darks are skipped if
    // nobody answers. A client that links while the host already waits
    // sees the request on Tonight.
    if (previous != null &&
        previous.phase != EonPhase.waitingForCap &&
        next?.phase == EonPhase.waitingForCap) {
      context
          .read(uiNotificationProvider.notifier)
          .showWarning(
            'The filter wheel has no dark slot. Cap the telescope, then '
            'confirm on Tonight. The darks and bias are skipped if nobody '
            'confirms.',
            title: 'Cap the telescope for darks',
            duration: const Duration(seconds: 30),
          );
    }
  }
}
