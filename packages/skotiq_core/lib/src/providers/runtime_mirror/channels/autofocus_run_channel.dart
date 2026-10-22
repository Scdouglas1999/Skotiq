import '../../../models/backend/autofocus_result.dart';
import '../../autofocus_progress_provider.dart';
import '../runtime_mirror_channel.dart';
import 'autofocus_result_channel.dart';

/// How an autofocus run shown on screen ended.
///
/// Both windows draw a run's V-curve from the native progress events, but a
/// run started from a window ends where that window's call returns: only the
/// starting window learned the run was over, and the other one showed it
/// running, with a Cancel button, until restarted. The end of a run is
/// shared both ways; progress stays with the events.
class AutofocusRunChannel extends RuntimeMirrorChannel<AutofocusOverlayState> {
  const AutofocusRunChannel();

  @override
  String get key => 'autofocusRun';

  @override
  get source => autofocusOverlayProvider;

  @override
  bool get clientReports => true;

  @override
  Map<String, dynamic>? encode(AutofocusOverlayState value) {
    if (value.isRunning) return {'running': true};
    final result = value.result;
    if (result != null) {
      return {
        'running': false,
        'outcome': 'completed',
        'result': const AutofocusResultChannel().encode(result),
      };
    }
    if (value.hasError) {
      return {'running': false, 'outcome': 'failed', 'status': value.status};
    }
    if (value.status == 'Autofocus cancelled') {
      return {'running': false, 'outcome': 'cancelled'};
    }
    return {'running': false};
  }

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    if (value == null || value['running'] == true) return;
    final overlay = context.read(autofocusOverlayProvider.notifier);
    if (!context.read(autofocusOverlayProvider).isRunning) return;
    switch (value['outcome']) {
      case 'completed':
        final raw = value['result'];
        AutofocusResult? result;
        if (raw is Map) {
          try {
            result = AutofocusResult.fromJson(Map<String, dynamic>.from(raw));
          } on Object {
            result = null;
          }
        }
        if (result != null) {
          overlay.onAutofocusCompleted(result);
        } else {
          overlay.onAutofocusFailed('Autofocus finished without a result');
        }
      case 'failed':
        final status = jsonString(value['status']);
        overlay.onAutofocusFailed(
          status == null
              ? 'Autofocus failed'
              : status.startsWith('Failed: ')
              ? status.substring(8)
              : status,
        );
      case 'cancelled':
        overlay.onAutofocusCancelled();
    }
  }
}
