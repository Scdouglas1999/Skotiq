part of '../sequencer_handlers.dart';

/// Start at dark, held on this host so the run starts at dark whether or not
/// any client is awake or connected then. A client arms, reads and cancels it
/// here; the host's own Tonight screen uses the same schedule.
extension SequencerScheduledStartHandlers on SequencerHandlers {
  /// GET /api/night/scheduled-start — when the run is scheduled to start.
  Future<Response> handleGetScheduledStart(Request request) async {
    return jsonOk({'at': _scheduledStartIso()});
  }

  /// POST /api/night/scheduled-start — start the loaded run at tonight's
  /// astronomical dark. Refused (409) with the reason when it cannot be armed.
  Future<Response> handleArmScheduledStart(Request request) async {
    _logInfo('[API] POST /api/night/scheduled-start');
    final api = container.read(nightActionApiProvider);
    await api.armStartAtDark();
    final refusal = api.state.error;
    final at = _scheduledStartIso();
    if (at == null) {
      final message = refusal == null
          ? 'Start at dark could not be armed.'
          : refusal.resolve(SkotiqLocalizations(const Locale('en')));
      return jsonConflict({
        'error': 'scheduled_start_refused',
        'message': message,
      });
    }
    return jsonOk({'at': at});
  }

  /// POST /api/night/scheduled-start/cancel — cancel the scheduled start.
  Future<Response> handleCancelScheduledStart(Request request) async {
    _logInfo('[API] POST /api/night/scheduled-start/cancel');
    final wasScheduled = _scheduledStartIso() != null;
    container.read(nightActionApiProvider).cancelArmedStart();
    return jsonOk({'status': 'canceled', 'wasScheduled': wasScheduled});
  }

  String? _scheduledStartIso() =>
      container.read(nightArmedStartProvider)?.toUtc().toIso8601String();
}
