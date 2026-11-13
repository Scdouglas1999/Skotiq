import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../models/replay_decision.dart';
import '../services/replay_debug_service.dart';
import '../settings/setting.dart';
import '../settings/store_settings.dart';
import 'async_scope.dart';
import 'host_role.dart';
import 'database_provider.dart';
import '../database/daos/settings_dao.dart';
import '../services/logging_service.dart';

/// Replay Debug — Riverpod surface for the structured decision
/// log feeding the retrospective Replay screen.
///
/// Every read/write provider here goes to whichever machine is the imaging
/// host:
///   * This process reads through [ReplayDebugService] and [SettingsDao]
///     against its own database.
///   * A linked client reads the host's decision log and settings through
///     `remoteHost.replayDebug`; its own database is empty and must never be
///     used as the source of truth (or mutated).
///
/// The live event-handling path (sequencer event → DB row) lives in
/// `SequenceExecutor._handleSequencerEvent` and only runs on the host, so
/// the write side of that path stays local-only.

/// Days a decision is kept when the operator has not chosen.
final int replayDebugDefaultRetentionDays =
    StoreSettings.replayDebugRetentionDays.fallback;

/// Whether decisions are logged, as [stored] holds it.
///
/// No row, or an empty one, is the default (on). Text that is neither `true`
/// nor `false` is corruption and throws [FormatException], so the read
/// surfaces as an error instead of reading as on.
bool parseReplayEnabledSetting(String? stored) =>
    StoreSettings.replayDebugEnabled.decodeStrict(stored);

/// Days a decision is kept, as [stored] holds it.
///
/// No row, or an empty one, is the default. Text that is not a whole number,
/// or a number of days no build stores, is corruption and throws
/// [FormatException] rather than reading as the default.
int parseReplayRetentionSetting(String? stored) {
  const setting = StoreSettings.replayDebugRetentionDays;
  final days = setting.decodeStrict(stored);
  if (days != setting.clean(days)) {
    throw FormatException(
      '${setting.key} out of range '
      '${setting.inputMin}..${setting.inputMax}: $days',
    );
  }
  return days;
}

/// Record a rollback that itself failed.
///
/// The aborted-update error the caller receives is still the primary failure,
/// but a rollback that did not land leaves the persisted value out of step
/// with what the caller was just told. Without this line the next read of the
/// setting reports a value the operator never confirmed, with nothing in the
/// log tying it to the update reported as not applied.
void _logFailedReplayRollback(String what, Object error) {
  Log.warning(
    'Failed to roll back $what after an aborted update; the persisted value '
    'may no longer match the result reported to the caller: $error',
    source: 'ReplayDebug',
  );
}

/// Local decision-log service. Only meaningful on the host: the live
/// persist path and the retention prune both run here. Remote clients never
/// read decisions from this (their local `sequence_decisions` table is
/// empty) — they go through the host endpoints instead.
final replayDebugServiceProvider = Provider<ReplayDebugService>((ref) {
  final database = ref.watch(databaseProvider);
  final service = ReplayDebugService(database);
  ref.onDispose(() {
    // Fire-and-forget close — the broadcaster has no IO side-effects.
    service.dispose();
  });
  return service;
});

/// How often a linked client reads a run's decisions from its host, so a
/// run under way keeps arriving.
const Duration _remoteDecisionPollInterval = Duration(seconds: 4);

/// Puts back the value a settings write replaced.
typedef UndoReplaySetting = Future<void> Function();

/// The decision log of whichever machine is the imaging host, and the two
/// settings that govern it. A read that fails is an error, never an empty
/// list, a zero or a default.
abstract interface class ReplayDecisionLog {
  /// A run's decisions, oldest first, as they are written.
  Stream<List<ReplayDecision>> watchByRun(int runId);

  Future<int> countByRun(int runId);

  Future<int> countAll();

  /// Deletes every decision and returns how many went.
  Future<int> deleteAll();

  Future<bool> enabled();

  Future<int> retentionDays();

  Future<UndoReplaySetting> setEnabled(bool value);

  Future<UndoReplaySetting> setRetentionDays(int days);

  /// Forgets what was read of the settings, so the next read asks again.
  void refreshSettings();
}

final replayDecisionLogProvider = hostRoleProvider<ReplayDecisionLog>(
  here: (ref) => _LocalReplayDecisionLog(
    ref.watch(replayDebugServiceProvider),
    ref.watch(settingsDaoProvider),
  ),
  linked: (ref, host) => _HostReplayDecisionLog(host.replayDebug),
);

final class _LocalReplayDecisionLog implements ReplayDecisionLog {
  _LocalReplayDecisionLog(this._service, this._settings);

  final ReplayDebugService _service;
  final SettingsDao _settings;

  @override
  Stream<List<ReplayDecision>> watchByRun(int runId) =>
      _service.watchByRun(runId);

  @override
  Future<int> countByRun(int runId) => _service.countByRun(runId);

  @override
  Future<int> countAll() => _service.countAll();

  @override
  Future<int> deleteAll() => _service.deleteAll();

  @override
  Future<bool> enabled() async => parseReplayEnabledSetting(
    await _settings.getSetting(StoreSettings.replayDebugEnabled.key),
  );

  @override
  Future<int> retentionDays() async => parseReplayRetentionSetting(
    await _settings.getSetting(StoreSettings.replayDebugRetentionDays.key),
  );

  /// The run configuration follows the stored flag (`RunConfigSync` listens
  /// to [replayDebugEnabledProvider]).
  @override
  Future<UndoReplaySetting> setEnabled(bool value) =>
      _write(StoreSettings.replayDebugEnabled, value);

  @override
  Future<UndoReplaySetting> setRetentionDays(int days) =>
      _write(StoreSettings.replayDebugRetentionDays, days);

  Future<UndoReplaySetting> _write<T>(Setting<T> setting, T value) async {
    final previous = await _settings.readRows([setting]);
    await _settings.write(setting, value);
    return () => _settings.restore(setting, previous);
  }

  @override
  void refreshSettings() {}
}

/// The host stores both settings and sends the flag to its own executor.
final class _HostReplayDecisionLog implements ReplayDecisionLog {
  _HostReplayDecisionLog(this._host);

  final HostReplayDebug _host;

  /// One read serves both settings.
  Future<ReplayDebugSettings>? _settings;

  Future<ReplayDebugSettings> _readSettings() =>
      _settings ??= _host.replayGetSettings();

  @override
  Stream<List<ReplayDecision>> watchByRun(int runId) {
    final controller = StreamController<List<ReplayDecision>>();
    Timer? timer;
    var inFlight = false;

    Future<void> tick() async {
      if (controller.isClosed || inFlight) return;
      inFlight = true;
      try {
        final decisions = await _host.replayListDecisions(runId);
        if (!controller.isClosed) controller.add(decisions);
      } catch (error, stack) {
        if (!controller.isClosed) controller.addError(error, stack);
      } finally {
        inFlight = false;
      }
    }

    controller.onListen = () {
      tick();
      timer = Timer.periodic(_remoteDecisionPollInterval, (_) => tick());
    };
    controller.onCancel = () {
      timer?.cancel();
      return controller.close();
    };
    return controller.stream;
  }

  @override
  Future<int> countByRun(int runId) => _host.replayCountDecisions(runId);

  @override
  Future<int> countAll() => _host.replayCountAllDecisions();

  @override
  Future<int> deleteAll() => _host.replayClearHistory();

  @override
  Future<bool> enabled() async => (await _readSettings()).enabled;

  @override
  Future<int> retentionDays() async => (await _readSettings()).retentionDays;

  @override
  Future<UndoReplaySetting> setEnabled(bool value) async {
    await _host.replaySetEnabled(value);
    _settings = null;
    return () async {};
  }

  @override
  Future<UndoReplaySetting> setRetentionDays(int days) async {
    await _host.replaySetRetentionDays(days);
    _settings = null;
    return () async {};
  }

  @override
  void refreshSettings() => _settings = null;
}

final decisionsForRunProvider = StreamProvider.autoDispose
    .family<List<ReplayDecision>, int>(
      (ref, runId) => ref.watch(replayDecisionLogProvider).watchByRun(runId),
    );

/// The count on a History row, shown only once it is known.
final decisionCountForRunProvider = FutureProvider.family<int, int>(
  (ref, runId) => ref.watch(replayDecisionLogProvider).countByRun(runId),
);

/// Whether the host logs its decisions. Unset is on; a stored value that
/// cannot be read is an error.
final replayDebugEnabledProvider = FutureProvider<bool>(
  (ref) => ref.watch(replayDecisionLogProvider).enabled(),
);

/// How many days the host keeps decisions. Unset is 90; a stored value that
/// cannot be read or is out of range is an error.
final replayDebugRetentionDaysProvider = FutureProvider<int>(
  (ref) => ref.watch(replayDecisionLogProvider).retentionDays(),
);

/// Changes the decision-log settings and clears the log. One change runs at
/// a time, and a change that finishes after the host was replaced is undone
/// where it was written and reported as failed.
class ReplayDebugSettingsController {
  ReplayDebugSettingsController(this._ref)
    : _scopes = AsyncScopes(_ref.read, replayDecisionLogProvider);

  final Ref _ref;
  final AsyncScopes<ReplayDecisionLog> _scopes;

  Future<void> _mutex = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() task) {
    final result = _mutex.then((_) => task());
    _mutex = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<void> setEnabled(bool value) => _serialize(
    () => _change(
      'the decision-logging flag',
      (log) => log.setEnabled(value),
      replayDebugEnabledProvider,
    ),
  );

  /// Stores the retention window, kept within `1..3650`.
  Future<void> setRetentionDays(int days) => _serialize(() async {
    final current = _ref.read(replayDebugRetentionDaysProvider);
    if (!current.hasValue) {
      throw StateError(
        'Cannot change retention: current value is unavailable '
        '(${current.hasError ? current.error : 'still loading'}).',
      );
    }
    final clamped = StoreSettings.replayDebugRetentionDays.clean(days);
    await _change(
      'the decision-log retention window',
      (log) => log.setRetentionDays(clamped),
      replayDebugRetentionDaysProvider,
    );
  });

  Future<void> _change(
    String what,
    Future<UndoReplaySetting> Function(ReplayDecisionLog log) write,
    ProviderOrFamily shown,
  ) async {
    final scope = _scopes.begin();
    final undo = await write(scope.value);
    if (scope.isStale) {
      try {
        await undo();
      } catch (e) {
        _logFailedReplayRollback(what, e);
      }
    }
    _ref.invalidate(shown);
    scope.ensureCurrent('changing $what');
  }

  /// How many decisions the host holds, or null when that cannot be read (an
  /// older host, a failed read). A caller then says it does not know.
  Future<int?> countAllHistory() => _serialize(() async {
    final scope = _scopes.begin();
    try {
      return await scope.guard((log) async => log.countAll(), ifStale: null);
    } catch (error) {
      Log.warning(
        'Could not count replay history: $error',
        source: 'ReplayDebug',
      );
      return null;
    }
  });

  /// Deletes every decision on the host and returns how many went.
  Future<int> clearAllHistory() => _serialize(() async {
    final scope = _scopes.begin();
    final removed = await scope.value.deleteAll();
    scope.ensureCurrent('clearing the decision log');
    _ref.invalidate(decisionsForRunProvider);
    _ref.invalidate(decisionCountForRunProvider);
    return removed;
  });

  /// Reads both settings again, for Retry after a failed read.
  void invalidateSettings() {
    _ref.read(replayDecisionLogProvider).refreshSettings();
    _ref.invalidate(replayDebugEnabledProvider);
    _ref.invalidate(replayDebugRetentionDaysProvider);
  }
}

final replayDebugSettingsControllerProvider =
    Provider<ReplayDebugSettingsController>((ref) {
      return ReplayDebugSettingsController(ref);
    });
