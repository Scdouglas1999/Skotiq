import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/remote_host.dart';
import '../models/replay_decision.dart';
import '../services/replay_debug_service.dart';
import '../settings/store_settings.dart';
import 'async_scope.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

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
  developer.log(
    'Failed to roll back $what after an aborted update; the persisted value '
    'may no longer match the result reported to the caller: $error',
    name: 'ReplayDebug',
    level: 900,
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

/// Polling cadence for the remote decision timeline. Bounded so a currently
/// running host sequence still streams fresh decisions to a remote client
/// without hammering the host.
const Duration _remoteDecisionPollInterval = Duration(seconds: 4);

/// Live chronological decision list for a sequence run id.
///
/// Local: a reactive stream from [ReplayDebugService.watchByRun] that emits a
/// fresh snapshot on every persist/delete.
///
/// Remote: bounded polling of the host endpoint with cancellation tied to
/// this (auto-dispose) provider's lifecycle. A failed poll is surfaced as a
/// stream error — never downgraded to an empty list — so the timeline shows
/// a real failure instead of a false "No decisions recorded".
final decisionsForRunProvider = StreamProvider.autoDispose
    .family<List<ReplayDecision>, int>((ref, runId) {
      final remote = ref.watch(backendProvider).remoteHost?.replayDebug;
      if (remote == null) {
        final service = ref.watch(replayDebugServiceProvider);
        return service.watchByRun(runId);
      }

      final controller = StreamController<List<ReplayDecision>>();
      Timer? timer;
      var inFlight = false;

      Future<void> tick() async {
        if (controller.isClosed || inFlight) return;
        inFlight = true;
        try {
          final decisions = await remote.replayListDecisions(runId);
          if (!controller.isClosed) controller.add(decisions);
        } catch (error, stack) {
          // Surface network / parse failures; do NOT replace a prior state
          // with false-empty data.
          if (!controller.isClosed) controller.addError(error, stack);
        } finally {
          inFlight = false;
        }
      }

      controller.onListen = () {
        tick();
        timer = Timer.periodic(_remoteDecisionPollInterval, (_) => tick());
      };
      ref.onDispose(() {
        timer?.cancel();
        if (!controller.isClosed) controller.close();
      });
      return controller.stream;
    });

/// Authoritative one-shot count of decisions for a run (the History-row
/// badge). Local reads the service; remote reads the host count endpoint.
/// Surfaces failures rather than a false zero — the history tab renders the
/// badge only on a real data value.
final decisionCountForRunProvider = FutureProvider.family<int, int>((
  ref,
  runId,
) async {
  final remote = ref.watch(backendProvider).remoteHost?.replayDebug;
  if (remote != null) return remote.replayCountDecisions(runId);
  final service = ref.watch(replayDebugServiceProvider);
  return service.countByRun(runId);
});

/// Remote-only fetch of the host's replay settings, deduped so
/// [replayDebugEnabledProvider] and [replayDebugRetentionDaysProvider] share
/// a single round-trip and stay consistent. Throws off the host when talking
/// to a local backend (callers must branch on authority first).
final _replayHostSettingsProvider = FutureProvider<ReplayDebugSettings>((
  ref,
) async {
  final remote = ref.watch(backendProvider).remoteHost?.replayDebug;
  if (remote == null) {
    throw StateError(
      'Replay host settings are only available while connected to a host.',
    );
  }
  return remote.replayGetSettings();
});

/// Replay Debug — runtime decision-logging toggle.
///
/// Local: strict parse of the `replay_debug.enabled` app-setting (unset →
/// default `true`; a corrupt value throws → AsyncError). Remote: the host's
/// authoritative value. Corruption/host failure surfaces as an error, never
/// a silent `true`.
final replayDebugEnabledProvider = FutureProvider<bool>((ref) async {
  if (ref.watch(backendProvider).remoteHost != null) {
    final settings = await ref.watch(_replayHostSettingsProvider.future);
    return settings.enabled;
  }
  final dao = ref.watch(settingsDaoProvider);
  return parseReplayEnabledSetting(
    await dao.getSetting(StoreSettings.replayDebugEnabled.key),
  );
});

/// Replay Debug — retention window in days. Local strict parse
/// (unset → 90; corrupt/out-of-range throws → AsyncError); remote reads the
/// host's authoritative value.
final replayDebugRetentionDaysProvider = FutureProvider<int>((ref) async {
  if (ref.watch(backendProvider).remoteHost != null) {
    final settings = await ref.watch(_replayHostSettingsProvider.future);
    return settings.retentionDays;
  }
  final dao = ref.watch(settingsDaoProvider);
  return parseReplayRetentionSetting(
    await dao.getSetting(StoreSettings.replayDebugRetentionDays.key),
  );
});

/// Replay Debug — write-side controller for the enabled toggle,
/// retention, and "clear all". Every mutation is serialized (so a rapid
/// enable→retention→clear burst can't interleave a persist with a runtime
/// push or a rollback), captures the active DAO/backend authority up front,
/// and re-verifies identity after each await before invalidating reads.
class ReplayDebugSettingsController {
  ReplayDebugSettingsController(this._ref);

  final Ref _ref;

  /// Serialization chain. Each mutation waits for the previous one to settle
  /// (success or failure) before it runs.
  Future<void> _mutex = Future<void>.value();

  Future<T> _serialize<T>(Future<T> Function() task) {
    final result = _mutex.then((_) => task());
    _mutex = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Enable/disable decision logging.
  ///
  /// Remote: a single host endpoint persists the host setting, and the host
  /// sends it to its executor. The remote client's local database is never
  /// touched.
  ///
  /// Local: persist the setting; the run configuration follows it
  /// (`RunConfigSync` listens to [replayDebugEnabledProvider]).
  Future<void> setEnabled(bool value) => _serialize(() async {
    final host = _ref.backendScope();
    final backend = host.value;
    final remote = backend.remoteHost?.replayDebug;
    if (remote != null) {
      await remote.replaySetEnabled(value);
      if (host.isStale) {
        throw StateError(
          'Replay settings host changed while applying the update.',
        );
      }
      _ref.invalidate(_replayHostSettingsProvider);
      _ref.invalidate(replayDebugEnabledProvider);
      return;
    }

    final dao = _ref.read(settingsDaoProvider);
    const setting = StoreSettings.replayDebugEnabled;
    final previousRows = await dao.readRows([setting]);
    if (!identical(_ref.read(settingsDaoProvider), dao) || host.isStale) {
      throw StateError('Replay settings authority changed before the update.');
    }

    await dao.write(setting, value);

    // Authority may have swapped while awaiting the write: the value belongs
    // to a database that is no longer this host's.
    if (!identical(_ref.read(settingsDaoProvider), dao) || host.isStale) {
      try {
        await dao.restore(setting, previousRows);
      } catch (e) {
        _logFailedReplayRollback('the decision-logging flag', e);
      }
      _ref.invalidate(replayDebugEnabledProvider);
      throw StateError('Replay settings authority changed during the update.');
    }
    _ref.invalidate(replayDebugEnabledProvider);
  });

  /// Persist the retention window (clamped to `1..3650`) against the active
  /// authority. If that authority swaps while the database write is pending,
  /// the old raw value is restored before the operation reports failure.
  Future<void> setRetentionDays(int days) => _serialize(() async {
    final clamped = StoreSettings.replayDebugRetentionDays.clean(days);
    final host = _ref.backendScope();
    final backend = host.value;
    final remote = backend.remoteHost?.replayDebug;
    if (remote != null) {
      await remote.replaySetRetentionDays(clamped);
      if (host.isStale) {
        throw StateError(
          'Replay settings host changed while applying the update.',
        );
      }
      _ref.invalidate(_replayHostSettingsProvider);
      _ref.invalidate(replayDebugRetentionDaysProvider);
      return;
    }

    final currentAsync = _ref.read(replayDebugRetentionDaysProvider);
    if (!currentAsync.hasValue) {
      throw StateError(
        'Cannot change retention: current value is unavailable '
        '(${currentAsync.hasError ? currentAsync.error : 'still loading'}).',
      );
    }
    final dao = _ref.read(settingsDaoProvider);
    const setting = StoreSettings.replayDebugRetentionDays;
    final previousRows = await dao.readRows([setting]);
    if (!identical(_ref.read(settingsDaoProvider), dao) || host.isStale) {
      throw StateError('Replay settings authority changed before the update.');
    }
    await dao.write(setting, clamped);
    if (!identical(_ref.read(settingsDaoProvider), dao) || host.isStale) {
      try {
        await dao.restore(setting, previousRows);
      } catch (e) {
        _logFailedReplayRollback('the decision-log retention window', e);
      }
      _ref.invalidate(replayDebugRetentionDaysProvider);
      throw StateError('Replay settings authority changed during the update.');
    }
    _ref.invalidate(replayDebugRetentionDaysProvider);
  });

  /// How many decision rows the active authority currently holds.
  ///
  /// Returns null when the number cannot be established (an older host without
  /// the unfiltered count endpoint, or a read failure). Callers must then say
  /// they do not know rather than implying zero.
  Future<int?> countAllHistory() => _serialize(() async {
    final host = _ref.backendScope();
    final backend = host.value;
    final remote = backend.remoteHost?.replayDebug;
    try {
      if (remote != null) {
        final count = await remote.replayCountAllDecisions();
        if (host.isStale) return null;
        return count;
      }
      final service = _ref.read(replayDebugServiceProvider);
      final count = await service.countAll();
      if (host.isStale ||
          !identical(_ref.read(replayDebugServiceProvider), service)) {
        return null;
      }
      return count;
    } catch (error) {
      developer.log(
        'Could not count replay history: $error',
        name: 'ReplayDebug',
        level: 900,
      );
      return null;
    }
  });

  /// Delete every persisted decision row on the active authority. Returns the
  /// number of rows removed. Remote clears the host log; local clears the
  /// host's own database.
  Future<int> clearAllHistory() => _serialize(() async {
    final host = _ref.backendScope();
    final backend = host.value;
    final remote = backend.remoteHost?.replayDebug;
    if (remote != null) {
      final removed = await remote.replayClearHistory();
      if (host.isStale) {
        throw StateError('Replay history host changed while clearing history.');
      }
      _ref.invalidate(decisionsForRunProvider);
      _ref.invalidate(decisionCountForRunProvider);
      return removed;
    }
    final service = _ref.read(replayDebugServiceProvider);
    final removed = await service.deleteAll();
    if (host.isStale ||
        !identical(_ref.read(replayDebugServiceProvider), service)) {
      throw StateError(
        'Replay history authority changed while clearing history.',
      );
    }
    return removed;
  });

  /// Re-fetch the settings for the active authority. Used by the settings
  /// page's error-state Retry so a corrupt-local or failed-host read can be
  /// retried without the caller having to know which providers to poke (the
  /// host-settings fetch is private to this file).
  void invalidateSettings() {
    if (_ref.read(backendProvider).remoteHost != null) {
      _ref.invalidate(_replayHostSettingsProvider);
    }
    _ref.invalidate(replayDebugEnabledProvider);
    _ref.invalidate(replayDebugRetentionDaysProvider);
  }
}

final replayDebugSettingsControllerProvider =
    Provider<ReplayDebugSettingsController>((ref) {
      return ReplayDebugSettingsController(ref);
    });
