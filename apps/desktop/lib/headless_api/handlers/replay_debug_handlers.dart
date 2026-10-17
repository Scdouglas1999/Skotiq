// Replay Debug — host-side REST surface for the retrospective
// decision log so a remote client can open the same Replay timeline for a
// host sequence run.
//
// Endpoints (all under /api/sequencer/replay-debug so they inherit the
// `sequencer` auth resource — GET → view, POST → control):
//
//   GET  /api/sequencer/replay-debug/decisions?runId=N   chronological rows
//   GET  /api/sequencer/replay-debug/decisions/count[?runId=N]  count badge,
//                                                        or every row when the
//                                                        runId is omitted
//   GET  /api/sequencer/replay-debug/settings            {enabled, retentionDays}
//   POST /api/sequencer/replay-debug/settings/enabled    persist + executor
//   POST /api/sequencer/replay-debug/settings/retention  persist retention
//   POST /api/sequencer/replay-debug/clear               delete every row
//
// The read side reads the host's `sequence_decisions` table via
// [ReplayDebugService]; the settings read/write goes through [SettingsDao].
// No host filesystem path or secret is returned — only decision rows and the
// two numeric/boolean settings.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:shelf/shelf.dart';

import '../response_helpers.dart';
import '../validation.dart';

/// Replay Debug handlers. Reaches the host decision log + settings through the
/// shared [ProviderContainer].
class ReplayDebugHandlers {
  final ProviderContainer container;

  ReplayDebugHandlers(this.container);

  LoggingService get _logger => container.read(loggingServiceProvider);
  void _logInfo(String message) =>
      _logger.info(message, source: 'ReplayDebugHandlers');

  /// GET /api/sequencer/replay-debug/decisions?runId=N
  ///
  /// Chronological decision rows for [runId]. `{ items: [...], total: N }`.
  Future<Response> handleListDecisions(Request request) async {
    final runId = requireQueryInt(request.url.queryParameters, 'runId', min: 1);
    final service = container.read(replayDebugServiceProvider);
    final decisions = await service.listByRun(runId);
    return jsonOk({
      'items': decisions.map((d) => d.toWireJson()).toList(),
      'total': decisions.length,
    });
  }

  /// GET /api/sequencer/replay-debug/decisions/count[?runId=N]
  ///
  /// Authoritative one-shot count. `{ count: N }`. With no `runId` this counts
  /// every decision on the host, which is what the "Clear all replay history"
  /// confirmation needs to state how much it is about to delete.
  Future<Response> handleCountDecisions(Request request) async {
    final params = request.url.queryParameters;
    final service = container.read(replayDebugServiceProvider);
    if (!params.containsKey('runId')) {
      return jsonOk({'count': await service.countAll()});
    }
    final runId = requireQueryInt(params, 'runId', min: 1);
    final count = await service.countByRun(runId);
    return jsonOk({'count': count});
  }

  /// GET /api/sequencer/replay-debug/settings
  ///
  /// The host's authoritative replay settings. Strictly parsed: a corrupt
  /// stored value fails loud (500) rather than shipping a fabricated default
  /// that a remote client would read as truth.
  Future<Response> handleGetSettings(Request request) async {
    final dao = container.read(settingsDaoProvider);
    final enabledRaw = await dao.getSetting(replayDebugEnabledKey);
    final retentionRaw = await dao.getSetting(replayDebugRetentionDaysKey);
    final bool enabled;
    final int retentionDays;
    try {
      enabled = parseReplayEnabledSetting(enabledRaw);
      retentionDays = parseReplayRetentionSetting(retentionRaw);
    } on FormatException catch (error, stack) {
      throw HandlerFailure(
        code: 'replay_settings_corrupt',
        message: 'Replay settings are corrupt on the host and must be reset.',
        statusCode: 500,
        cause: error,
        stackTrace: stack,
      );
    }
    return jsonOk(
      ReplayDebugSettings(
        enabled: enabled,
        retentionDays: retentionDays,
      ).toWireJson(),
    );
  }

  /// POST /api/sequencer/replay-debug/settings/enabled  { enabled: bool }
  ///
  /// Persists the host `replay_debug.enabled` setting AND mirrors the flag
  /// into the host executor as one authority-preserving operation. If the
  /// executor update fails the persisted value is rolled back so the DB and
  /// runtime can never silently disagree (a failure returns non-2xx, never a
  /// false success).
  Future<Response> handleSetEnabled(Request request) async {
    _logInfo('[API] POST /api/sequencer/replay-debug/settings/enabled');
    final payload = await readJsonObject(request);
    final enabled = requireBool(payload, 'enabled');
    final dao = container.read(settingsDaoProvider);
    final backend = container.read(sequencerBackendProvider);

    // Snapshot the prior raw value (may be null/absent) so a rollback restores
    // exactly what was there — not a re-normalized guess.
    final priorRaw = await dao.getSetting(replayDebugEnabledKey);

    // 1) Persist the new value.
    await dao.setSetting(replayDebugEnabledKey, enabled.toString());

    // 2) Mirror into the executor; roll the persist back on failure.
    try {
      await backend.sequencerSetDecisionLoggingEnabled(enabled);
    } catch (error, stack) {
      try {
        if (priorRaw == null) {
          await dao.deleteSetting(replayDebugEnabledKey);
        } else {
          await dao.setSetting(replayDebugEnabledKey, priorRaw);
        }
      } catch (rollbackError) {
        // Rollback itself failed; the surfaced failure below is still the
        // primary error the caller must see, but the stranded persisted flag
        // is a diagnosable condition — record it rather than swallowing.
        _logger.warning(
          'Replay-debug rollback failed after sequencer rejection; the '
          'persisted enabled flag may be stale: $rollbackError',
          source: 'ReplayDebugHandlers',
        );
      }
      throw HandlerFailure(
        code: 'replay_set_enabled_failed',
        message:
            'Could not apply decision logging to the sequencer; the persisted '
            'setting was rolled back.',
        statusCode: 500,
        cause: error,
        stackTrace: stack,
      );
    }
    return jsonOk({'status': 'ok', 'enabled': enabled});
  }

  /// POST /api/sequencer/replay-debug/settings/retention  { days: int }
  ///
  /// Persists the host retention window. Range 1..3650. No executor side, so
  /// no rollback is required.
  Future<Response> handleSetRetention(Request request) async {
    _logInfo('[API] POST /api/sequencer/replay-debug/settings/retention');
    final payload = await readJsonObject(request);
    final days = requireInt(payload, 'days', min: 1, max: 3650);
    final dao = container.read(settingsDaoProvider);
    await dao.setSetting(replayDebugRetentionDaysKey, days.toString());
    return jsonOk({'status': 'ok', 'retentionDays': days});
  }

  /// POST /api/sequencer/replay-debug/clear
  ///
  /// Delete every decision row on the host. `{ removed: N }`.
  Future<Response> handleClear(Request request) async {
    _logInfo('[API] POST /api/sequencer/replay-debug/clear');
    final service = container.read(replayDebugServiceProvider);
    final removed = await service.deleteAll();
    return jsonOk({'removed': removed});
  }
}
