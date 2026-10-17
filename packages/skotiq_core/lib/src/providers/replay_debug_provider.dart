import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/network_backend.dart';
import '../models/replay_decision.dart';
import '../services/replay_debug_service.dart';
import 'backend_provider.dart';
import 'database_provider.dart';

/// Replay Debug — Riverpod surface for the structured decision
/// log feeding the retrospective Replay screen.
///
/// Every read/write provider here branches on the ACTIVE backend
/// authority:
///   * Local (FfiBackend / Disconnected) reads through [ReplayDebugService]
///     and [SettingsDao] against the local database.
///   * Remote ([NetworkBackend]) reads the HOST's decision log + settings
///     over REST — the remote client's own local database is empty and must
///     never be used as the source of truth (or mutated).
///
/// The live event-handling path (sequencer event → DB row) lives in
/// `SequenceExecutor._handleSequencerEvent` and only runs on the host, so
/// the write side of that path stays local-only.

/// Replay Debug — settings keys persisted in `app_settings`.
const String replayDebugEnabledKey = 'replay_debug.enabled';
const String replayDebugRetentionDaysKey = 'replay_debug.retention_days';

/// Default retention window when the setting is unset on first install.
const int replayDebugDefaultRetentionDays = 90;

/// Strict decoder for the persisted `replay_debug.enabled` value.
///
/// An unset value (no row) is the legitimate default (`true`). A stored
/// value must be exactly `true`/`false` (case-insensitive, surrounding
/// whitespace tolerated); anything else is corruption and throws
/// [FormatException] so the read surfaces as an AsyncError instead of
/// coercing an unreadable value to `true`.
bool parseReplayEnabledSetting(String? stored) {
  if (stored == null) return true;
  switch (stored.trim().toLowerCase()) {
    case 'true':
      return true;
    case 'false':
      return false;
    default:
      throw FormatException(
        'replay_debug.enabled is corrupt: "$stored" (expected true/false)',
      );
  }
}

/// Strict decoder for the persisted `replay_debug.retention_days` value.
///
/// An unset value is the legitimate default (90). A stored value must parse
/// to an integer inside `1..3650`; anything else (non-numeric or out of
/// band) is corruption and throws [FormatException] rather than silently
/// coercing to the default.
int parseReplayRetentionSetting(String? stored) {
  if (stored == null) return replayDebugDefaultRetentionDays;
  final parsed = int.tryParse(stored.trim());
  if (parsed == null) {
    throw FormatException(
      'replay_debug.retention_days is corrupt: "$stored" (expected an integer)',
    );
  }
  if (parsed < 1 || parsed > 3650) {
    throw FormatException(
      'replay_debug.retention_days out of range 1..3650: $parsed',
    );
  }
  return parsed;
}

/// Clamp a requested retention value into the persisted band. The minimum is
/// 1 day — retention can't be disabled entirely or the table grows unbounded;
/// the upper clamp (3650 = ~10 years) is the "keep everything" ceiling.
int _clampRetentionDays(int days) {
  if (days < 1) return 1;
  if (days > 3650) return 3650;
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
      final backend = ref.watch(backendProvider);
      if (backend is! NetworkBackend) {
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
          final decisions = await backend.replayListDecisions(runId);
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
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    return backend.replayCountDecisions(runId);
  }
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
  final backend = ref.watch(backendProvider);
  if (backend is! NetworkBackend) {
    throw StateError(
      'Replay host settings are only available while connected to a host.',
    );
  }
  return backend.replayGetSettings();
});

/// Replay Debug — runtime decision-logging toggle.
///
/// Local: strict parse of the `replay_debug.enabled` app-setting (unset →
/// default `true`; a corrupt value throws → AsyncError). Remote: the host's
/// authoritative value. Corruption/host failure surfaces as an error, never
/// a silent `true`.
final replayDebugEnabledProvider = FutureProvider<bool>((ref) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final settings = await ref.watch(_replayHostSettingsProvider.future);
    return settings.enabled;
  }
  final dao = ref.watch(settingsDaoProvider);
  return parseReplayEnabledSetting(await dao.getSetting(replayDebugEnabledKey));
});

/// Replay Debug — retention window in days. Local strict parse
/// (unset → 90; corrupt/out-of-range throws → AsyncError); remote reads the
/// host's authoritative value.
final replayDebugRetentionDaysProvider = FutureProvider<int>((ref) async {
  final backend = ref.watch(backendProvider);
  if (backend is NetworkBackend) {
    final settings = await ref.watch(_replayHostSettingsProvider.future);
    return settings.retentionDays;
  }
  final dao = ref.watch(settingsDaoProvider);
  return parseReplayRetentionSetting(
    await dao.getSetting(replayDebugRetentionDaysKey),
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
  /// Remote: a single host endpoint persists the host setting AND mirrors the
  /// flag into the host executor (with host-side rollback). The remote
  /// client's local database is never touched.
  ///
  /// Local: transactional from the user's perspective — persist the setting,
  /// then push the flag to the executor; if the executor push fails, roll the
  /// persisted value back so the DB and runtime never silently disagree.
  Future<void> setEnabled(bool value) => _serialize(() async {
    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      await backend.replaySetEnabled(value);
      if (!identical(_ref.read(backendProvider), backend)) {
        throw StateError(
          'Replay settings host changed while applying the update.',
        );
      }
      _ref.invalidate(_replayHostSettingsProvider);
      _ref.invalidate(replayDebugEnabledProvider);
      return;
    }

    // Refuse if the current value is unavailable (still loading, or corrupt):
    // we need it as the rollback target and as an authority that the read
    // side is coherent.
    final currentAsync = _ref.read(replayDebugEnabledProvider);
    if (!currentAsync.hasValue) {
      throw StateError(
        'Cannot change replay logging: current value is unavailable '
        '(${currentAsync.hasError ? currentAsync.error : 'still loading'}).',
      );
    }
    final previous = currentAsync.requireValue;
    final dao = _ref.read(settingsDaoProvider);
    final previousRaw = await dao.getSetting(replayDebugEnabledKey);
    if (!identical(_ref.read(settingsDaoProvider), dao) ||
        !identical(_ref.read(backendProvider), backend)) {
      throw StateError('Replay settings authority changed before the update.');
    }

    // 1) Persist the new value.
    await dao.setSetting(replayDebugEnabledKey, value.toString());

    // Authority may have swapped while awaiting the write. If the DAO or the
    // backend changed, do not push runtime to a now-different executor.
    if (!identical(_ref.read(settingsDaoProvider), dao) ||
        !identical(_ref.read(backendProvider), backend)) {
      try {
        if (previousRaw == null) {
          await dao.deleteSetting(replayDebugEnabledKey);
        } else {
          await dao.setSetting(replayDebugEnabledKey, previousRaw);
        }
      } catch (e) {
        _logFailedReplayRollback('the decision-logging flag', e);
      }
      _ref.invalidate(replayDebugEnabledProvider);
      throw StateError('Replay settings authority changed during the update.');
    }

    // 2) Mirror into the executor; roll the persist back on failure.
    try {
      await backend.sequencerSetDecisionLoggingEnabled(value);
    } catch (error, stack) {
      try {
        if (previousRaw == null) {
          await dao.deleteSetting(replayDebugEnabledKey);
        } else {
          await dao.setSetting(replayDebugEnabledKey, previousRaw);
        }
      } catch (e) {
        _logFailedReplayRollback(
          'the decision-logging flag after the executor rejected it',
          e,
        );
      }
      _ref.invalidate(replayDebugEnabledProvider);
      Error.throwWithStackTrace(error, stack);
    }
    if (!identical(_ref.read(settingsDaoProvider), dao) ||
        !identical(_ref.read(backendProvider), backend)) {
      try {
        await backend.sequencerSetDecisionLoggingEnabled(previous);
        if (previousRaw == null) {
          await dao.deleteSetting(replayDebugEnabledKey);
        } else {
          await dao.setSetting(replayDebugEnabledKey, previousRaw);
        }
      } catch (e) {
        _logFailedReplayRollback(
          'the decision-logging flag and its executor mirror',
          e,
        );
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
    final clamped = _clampRetentionDays(days);
    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      await backend.replaySetRetentionDays(clamped);
      if (!identical(_ref.read(backendProvider), backend)) {
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
    final previousRaw = await dao.getSetting(replayDebugRetentionDaysKey);
    if (!identical(_ref.read(settingsDaoProvider), dao) ||
        !identical(_ref.read(backendProvider), backend)) {
      throw StateError('Replay settings authority changed before the update.');
    }
    await dao.setSetting(replayDebugRetentionDaysKey, clamped.toString());
    if (!identical(_ref.read(settingsDaoProvider), dao) ||
        !identical(_ref.read(backendProvider), backend)) {
      try {
        if (previousRaw == null) {
          await dao.deleteSetting(replayDebugRetentionDaysKey);
        } else {
          await dao.setSetting(replayDebugRetentionDaysKey, previousRaw);
        }
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
    final backend = _ref.read(backendProvider);
    try {
      if (backend is NetworkBackend) {
        final count = await backend.replayCountAllDecisions();
        if (!identical(_ref.read(backendProvider), backend)) return null;
        return count;
      }
      final service = _ref.read(replayDebugServiceProvider);
      final count = await service.countAll();
      if (!identical(_ref.read(backendProvider), backend) ||
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
    final backend = _ref.read(backendProvider);
    if (backend is NetworkBackend) {
      final removed = await backend.replayClearHistory();
      if (!identical(_ref.read(backendProvider), backend)) {
        throw StateError('Replay history host changed while clearing history.');
      }
      _ref.invalidate(decisionsForRunProvider);
      _ref.invalidate(decisionCountForRunProvider);
      return removed;
    }
    final service = _ref.read(replayDebugServiceProvider);
    final removed = await service.deleteAll();
    if (!identical(_ref.read(backendProvider), backend) ||
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
    if (_ref.read(backendProvider) is NetworkBackend) {
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
