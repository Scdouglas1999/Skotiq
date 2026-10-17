import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/sequence/sequence_models.dart';
import '../models/sequence/active_plan_owner.dart';
import '../database/daos/settings_dao.dart';
import '../providers/backend_provider.dart';
import '../providers/constellation_provider.dart';
import '../providers/replay_debug_provider.dart';
import '../providers/sky_atlas_provider.dart';
import '../providers/database_provider.dart';
import '../providers/sequence_provider.dart';
import 'sequence_repository.dart';
import 'backup_service.dart';
import 'replay_debug_service.dart';
import 'remote_sequence_editor_sync_lifecycle.dart';
import 'sync/sync_service.dart';

/// Configuration for auto-save behavior
class AutoSaveConfig {
  final Duration sequenceInterval;
  final Duration backupInterval;
  final bool sequenceEnabled;
  final bool backupEnabled;
  final int maxBackups;

  const AutoSaveConfig({
    this.sequenceInterval = const Duration(minutes: 2),
    this.backupInterval = const Duration(hours: 24),
    // Opt-in: sequence edits are queued by autoSaveLifecycleProvider when the
    // operator enables this in Settings → Automatic Backups.
    this.sequenceEnabled = false,
    this.backupEnabled = true,
    this.maxBackups = 7, // Keep last 7 auto-backups
  });

  AutoSaveConfig copyWith({
    Duration? sequenceInterval,
    Duration? backupInterval,
    bool? sequenceEnabled,
    bool? backupEnabled,
    int? maxBackups,
  }) {
    return AutoSaveConfig(
      sequenceInterval: sequenceInterval ?? this.sequenceInterval,
      backupInterval: backupInterval ?? this.backupInterval,
      sequenceEnabled: sequenceEnabled ?? this.sequenceEnabled,
      backupEnabled: backupEnabled ?? this.backupEnabled,
      maxBackups: maxBackups ?? this.maxBackups,
    );
  }
}

/// Status of auto-save operations
class AutoSaveStatus {
  final DateTime? lastSequenceSave;
  final DateTime? lastBackup;
  final bool isSequenceSaving;
  final bool isBackingUp;
  final String? lastError;

  const AutoSaveStatus({
    this.lastSequenceSave,
    this.lastBackup,
    this.isSequenceSaving = false,
    this.isBackingUp = false,
    this.lastError,
  });

  AutoSaveStatus copyWith({
    DateTime? lastSequenceSave,
    DateTime? lastBackup,
    bool? isSequenceSaving,
    bool? isBackingUp,
    String? lastError,
  }) {
    return AutoSaveStatus(
      lastSequenceSave: lastSequenceSave ?? this.lastSequenceSave,
      lastBackup: lastBackup ?? this.lastBackup,
      isSequenceSaving: isSequenceSaving ?? this.isSequenceSaving,
      isBackingUp: isBackingUp ?? this.isBackingUp,
      lastError: lastError,
    );
  }
}

/// Service for automatic saving of sequences and backups
class AutoSaveService {
  final SequenceRepository sequenceRepository;
  final BackupService backupService;
  final ReplayDebugService? replayDebugService;
  final Future<int> Function()? replayRetentionDays;
  final DateTime Function() clock;

  /// Cloud sync hook — invoked after each SUCCESSFUL automatic backup so
  /// the opt-in cloud auto-push (SyncService.maybeAutoPush) rides the
  /// existing daily backup scheduler instead of owning a second timer.
  /// Errors are swallowed here; the hook records its own failures.
  final Future<void> Function()? postBackupHook;

  /// Derived-artifact retention sweep, run on start and then daily. The Sky
  /// Atlas cutout/delta cache and the pulled swarm blobs are both rebuildable
  /// on demand and both grow without bound on a host that runs for months, so
  /// they ride this maintenance schedule instead of owning a second timer.
  /// Failures are logged, never fatal — reclaiming disk is best-effort.
  final Future<void> Function()? livingSkyRetentionSweep;

  final Future<void> Function(AutoSaveConfig config)? persistConfig;
  final Future<void> Function(DateTime timestamp)? persistLastBackup;
  final void Function(Sequence sequence, int databaseId)? onSequenceSaved;

  AutoSaveConfig _config = const AutoSaveConfig();
  Timer? _sequenceTimer;
  Timer? _backupTimer;
  Timer? _replayPruneTimer;
  Timer? _retentionSweepTimer;
  Timer? _initialBackupCheckTimer;
  bool _isReplayPruning = false;
  bool _isSweepingRetention = false;
  bool _started = false;
  bool _disposed = false;
  Future<BackupResult>? _backupInFlight;
  Future<bool>? _sequenceSaveInFlight;

  // Track sequences that need saving
  final Map<String, Sequence> _pendingSequences = {};
  bool _hasUnsavedChanges = false;

  // Status tracking
  final _statusController = StreamController<AutoSaveStatus>.broadcast();
  AutoSaveStatus _status = const AutoSaveStatus();

  AutoSaveService({
    required this.sequenceRepository,
    required this.backupService,
    this.replayDebugService,
    this.replayRetentionDays,
    this.postBackupHook,
    this.livingSkyRetentionSweep,
    this.persistConfig,
    this.persistLastBackup,
    this.onSequenceSaved,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  /// Stream of auto-save status updates
  Stream<AutoSaveStatus> get statusStream async* {
    yield _status;
    yield* _statusController.stream;
  }

  /// Current auto-save status
  AutoSaveStatus get status => _status;

  /// Current configuration
  AutoSaveConfig get config => _config;

  /// Whether there are unsaved changes
  bool get hasUnsavedChanges => _hasUnsavedChanges;

  /// Start the auto-save service
  void start([AutoSaveConfig? config, DateTime? lastBackup]) {
    if (_started) return;
    if (config != null) {
      _config = config;
    }
    _validateConfig(_config);
    if (lastBackup != null) {
      _status = _status.copyWith(lastBackup: lastBackup);
      // PUBLISH the hydrated timestamp. `statusStream` seeds late subscribers
      // with `_status`, but a listener that attached BEFORE the lifecycle
      // provider finished hydrating (the settings Backup screen builds during
      // boot) had already been handed the pre-hydration status and never heard
      // about this one, because nothing here emitted. The result: "Last Full
      // Backup: Never" on a machine whose `autosave.last_backup_at` was
      // persisted hours earlier — observed on the desktop app with backup files
      // sitting on disk.
      _statusController.add(_status);
    }
    _started = true;

    developer.log(
      'AutoSaveService: Starting with config:',
      name: 'AutoSaveService',
      level: 800,
    );
    developer.log(
      '  Sequence auto-save: ${_config.sequenceEnabled} (every ${_config.sequenceInterval.inMinutes} min)',
      name: 'AutoSaveService',
      level: 800,
    );
    developer.log(
      '  Backup auto-save: ${_config.backupEnabled} (every ${_config.backupInterval.inHours} hours)',
      name: 'AutoSaveService',
      level: 800,
    );
    developer.log(
      '  Max backups: ${_config.maxBackups}',
      name: 'AutoSaveService',
      level: 800,
    );

    // Start sequence auto-save timer
    if (_config.sequenceEnabled) {
      _sequenceTimer?.cancel();
      _sequenceTimer = Timer.periodic(_config.sequenceInterval, (_) {
        _autoSaveSequences();
      });
    }

    // Start backup timer
    if (_config.backupEnabled) {
      _backupTimer?.cancel();
      _backupTimer = Timer.periodic(_config.backupInterval, (_) {
        _autoBackup();
      });

      // Also run initial backup check (delayed to avoid startup overhead)
      _initialBackupCheckTimer = Timer(const Duration(minutes: 5), () {
        unawaited(_checkAndPerformBackup());
      });
    }

    _startReplayRetentionPruning();
    _startLivingSkyRetentionSweeps();

    developer.log(
      'AutoSaveService: Started successfully',
      name: 'AutoSaveService',
      level: 800,
    );
  }

  /// Stop the auto-save service
  ///
  /// Flushes any pending sequence saves before stopping timers.
  Future<void> stop() async {
    developer.log(
      'AutoSaveService: Stopping...',
      name: 'AutoSaveService',
      level: 800,
    );

    final wasStarted = _started;

    _sequenceTimer?.cancel();
    _sequenceTimer = null;

    _backupTimer?.cancel();
    _backupTimer = null;

    _replayPruneTimer?.cancel();
    _replayPruneTimer = null;
    _retentionSweepTimer?.cancel();
    _retentionSweepTimer = null;
    _initialBackupCheckTimer?.cancel();
    _initialBackupCheckTimer = null;
    _started = false;

    // Do not dispose the provider graph underneath an in-flight database
    // export. Graceful shutdown waits for the single coalesced backup.
    final activeBackup = _backupInFlight;
    if (activeBackup != null) {
      await activeBackup;
    }

    // Drain every snapshot that became pending before or during an in-flight
    // save. Awaiting a single coalesced save is insufficient: an edit that
    // arrives while that request is running deliberately remains queued.
    final flushed = await _flushPendingSequences();
    if (!flushed) {
      // A failed close/configuration change must not silently leave the
      // service stopped. Keep retry scheduling alive while the caller reports
      // the failure and lets the operator decide whether to try again.
      if (wasStarted && !_disposed) {
        start();
      }
      throw StateError(
        _status.lastError ?? 'Pending sequence changes could not be saved',
      );
    }

    developer.log(
      'AutoSaveService: Stopped',
      name: 'AutoSaveService',
      level: 800,
    );
  }

  /// Update configuration (restarts timers if needed)
  Future<void> updateConfig(AutoSaveConfig newConfig) async {
    _validateConfig(newConfig);
    await persistConfig?.call(newConfig);
    final needsRestart =
        _config.sequenceInterval != newConfig.sequenceInterval ||
        _config.backupInterval != newConfig.backupInterval ||
        _config.sequenceEnabled != newConfig.sequenceEnabled ||
        _config.backupEnabled != newConfig.backupEnabled;

    _config = newConfig;

    if (needsRestart) {
      await stop();
      start();
    }

    developer.log(
      'AutoSaveService: Configuration updated',
      name: 'AutoSaveService',
      level: 800,
    );
  }

  /// Mark a sequence as having unsaved changes
  void markSequenceChanged(Sequence sequence) {
    _pendingSequences[sequence.id] = sequence;
    _hasUnsavedChanges = true;
  }

  /// Clear unsaved changes marker for a sequence
  void markSequenceSaved(String sequenceId) {
    _pendingSequences.remove(sequenceId);
    if (_pendingSequences.isEmpty) {
      _hasUnsavedChanges = false;
    }
  }

  /// Manually trigger sequence save
  Future<void> saveNow() async {
    final flushed = await _flushPendingSequences();
    if (!flushed) {
      throw StateError(
        _status.lastError ?? 'Pending sequence changes could not be saved',
      );
    }
  }

  /// Manually trigger backup
  Future<BackupResult> backupNow() async {
    return await _autoBackup();
  }

  /// Manually trigger replay-debug retention pruning.
  Future<int> pruneReplayDebugNow() =>
      _pruneReplayDebugRetention(rethrowErrors: true);

  /// Auto-save sequences that have pending changes
  Future<bool> _autoSaveSequences() {
    final active = _sequenceSaveInFlight;
    if (active != null) return active;

    late final Future<bool> run;
    run = _performAutoSaveSequences().whenComplete(() {
      if (identical(_sequenceSaveInFlight, run)) {
        _sequenceSaveInFlight = null;
      }
    });
    _sequenceSaveInFlight = run;
    return run;
  }

  Future<bool> _performAutoSaveSequences() async {
    if (_pendingSequences.isEmpty) {
      return true;
    }

    developer.log(
      'AutoSaveService: Auto-saving ${_pendingSequences.length} '
      'sequence${_pendingSequences.length == 1 ? '' : 's'}...',
      name: 'AutoSaveService',
      level: 800,
    );

    _updateStatus(_status.copyWith(isSequenceSaving: true));

    try {
      final sequences = _pendingSequences.values.toList();
      for (final sequence in sequences) {
        final databaseId = await sequenceRepository.saveSequence(sequence);
        // A newer immutable snapshot may have arrived while this save was in
        // flight. Never remove or mark that newer edit as saved.
        if (identical(_pendingSequences[sequence.id], sequence)) {
          _pendingSequences.remove(sequence.id);
          onSequenceSaved?.call(sequence, databaseId);
        }
      }

      _hasUnsavedChanges = _pendingSequences.isNotEmpty;

      _updateStatus(
        _status.copyWith(
          isSequenceSaving: false,
          lastSequenceSave: DateTime.now(),
          lastError: null,
        ),
      );

      developer.log(
        'AutoSaveService: Successfully saved ${sequences.length} '
        'sequence${sequences.length == 1 ? '' : 's'}',
        name: 'AutoSaveService',
        level: 800,
      );
      return true;
    } catch (e) {
      developer.log(
        'AutoSaveService: Error saving sequences: $e',
        name: 'AutoSaveService',
        level: 1000,
        error: e,
      );
      _updateStatus(
        _status.copyWith(
          isSequenceSaving: false,
          lastError: 'Failed to auto-save sequences: $e',
        ),
      );
      return false;
    }
  }

  Future<bool> _flushPendingSequences() async {
    while (_pendingSequences.isNotEmpty) {
      if (!await _autoSaveSequences()) {
        return false;
      }
    }
    return true;
  }

  /// Check if backup is needed and perform it
  Future<void> _checkAndPerformBackup() async {
    // Check if enough time has passed since last backup
    if (_status.lastBackup != null) {
      final timeSinceLastBackup = DateTime.now().difference(
        _status.lastBackup!,
      );
      if (timeSinceLastBackup < _config.backupInterval) {
        developer.log(
          'AutoSaveService: Skipping backup, last backup was ${timeSinceLastBackup.inHours} hours ago',
          name: 'AutoSaveService',
          level: 800,
        );
        return;
      }
    }

    await _autoBackup();
  }

  /// Perform automatic backup
  Future<BackupResult> _autoBackup() async {
    final active = _backupInFlight;
    if (active != null) return active;

    final operation = _performAutoBackup();
    _backupInFlight = operation;
    try {
      return await operation;
    } finally {
      if (identical(_backupInFlight, operation)) {
        _backupInFlight = null;
      }
    }
  }

  Future<BackupResult> _performAutoBackup() async {
    developer.log(
      'AutoSaveService: Starting automatic backup...',
      name: 'AutoSaveService',
      level: 800,
    );

    _updateStatus(_status.copyWith(isBackingUp: true));

    try {
      final result = await backupService.autoSaveBackup();

      if (result.success) {
        developer.log(
          'AutoSaveService: Backup completed successfully: ${result.filePath}',
          name: 'AutoSaveService',
          level: 800,
        );

        final completedAt = clock();
        _updateStatus(
          _status.copyWith(
            isBackingUp: false,
            lastBackup: completedAt,
            lastError: null,
          ),
        );
        try {
          await persistLastBackup?.call(completedAt);
        } catch (e) {
          developer.log(
            'AutoSaveService: Failed to persist last-backup time: $e',
            name: 'AutoSaveService',
            level: 900,
            error: e,
          );
        }

        // Clean up old backups
        await _cleanupOldBackups();

        // Cloud sync auto-push (opt-in; no-op unless enabled in settings).
        final hook = postBackupHook;
        if (hook != null) {
          try {
            await hook();
          } catch (e) {
            developer.log(
              'AutoSaveService: post-backup hook failed: $e',
              name: 'AutoSaveService',
              level: 900,
              error: e,
            );
          }
        }
      } else {
        developer.log(
          'AutoSaveService: Backup failed: ${result.errorMessage}',
          name: 'AutoSaveService',
          level: 900,
        );

        _updateStatus(
          _status.copyWith(
            isBackingUp: false,
            lastError: 'Backup failed: ${result.errorMessage}',
          ),
        );
      }

      return result;
    } catch (e) {
      developer.log(
        'AutoSaveService: Error during backup: $e',
        name: 'AutoSaveService',
        level: 1000,
        error: e,
      );

      _updateStatus(
        _status.copyWith(isBackingUp: false, lastError: 'Backup error: $e'),
      );

      return BackupResult(
        success: false,
        errorMessage: e.toString(),
        timestamp: DateTime.now(),
      );
    }
  }

  void _startReplayRetentionPruning() {
    _replayPruneTimer?.cancel();
    if (replayDebugService == null || replayRetentionDays == null) {
      return;
    }

    Future.microtask(() => _pruneReplayDebugRetention());
    _replayPruneTimer = Timer.periodic(const Duration(days: 1), (_) {
      _pruneReplayDebugRetention();
    });
  }

  void _startLivingSkyRetentionSweeps() {
    _retentionSweepTimer?.cancel();
    if (livingSkyRetentionSweep == null) return;

    // Once now (a host that is restarted daily would otherwise never sweep),
    // then on the same daily cadence as the replay-debug prune.
    Future.microtask(_runLivingSkyRetentionSweep);
    _retentionSweepTimer = Timer.periodic(const Duration(days: 1), (_) {
      _runLivingSkyRetentionSweep();
    });
  }

  Future<void> _runLivingSkyRetentionSweep() async {
    final sweep = livingSkyRetentionSweep;
    if (sweep == null || _isSweepingRetention) return;

    _isSweepingRetention = true;
    try {
      await sweep();
    } catch (e) {
      developer.log(
        'AutoSaveService: Living Sky retention sweep failed: $e',
        name: 'AutoSaveService',
        level: 900,
        error: e,
      );
    } finally {
      _isSweepingRetention = false;
    }
  }

  Future<int> _pruneReplayDebugRetention({bool rethrowErrors = false}) async {
    final service = replayDebugService;
    final readRetentionDays = replayRetentionDays;
    if (service == null || readRetentionDays == null) {
      return 0;
    }
    if (_isReplayPruning) {
      developer.log(
        'AutoSaveService: Replay debug prune already running; skipping overlap',
        name: 'AutoSaveService',
        level: 800,
      );
      return 0;
    }

    _isReplayPruning = true;
    try {
      final days = await readRetentionDays();
      if (days < 1) {
        throw StateError('Replay debug retention_days must be >= 1, got $days');
      }
      final cutoff = clock().toUtc().subtract(Duration(days: days));
      final removed = await service.pruneOlderThan(cutoff);
      developer.log(
        'AutoSaveService: Pruned $removed replay decision '
        'row${removed == 1 ? '' : 's'} older than $cutoff',
        name: 'AutoSaveService',
        level: 800,
      );
      return removed;
    } catch (e) {
      developer.log(
        'AutoSaveService: Replay debug retention prune failed: $e',
        name: 'AutoSaveService',
        level: 1000,
        error: e,
      );
      _updateStatus(
        _status.copyWith(lastError: 'Replay debug retention prune failed: $e'),
      );
      if (rethrowErrors) rethrow;
      return 0;
    } finally {
      _isReplayPruning = false;
    }
  }

  /// Remove old auto-save backups, keeping only the most recent ones
  Future<void> _cleanupOldBackups() async {
    try {
      final backups = await backupService.listBackups();

      // Filter to only auto-save backups
      final autoSaveBackups = backups
          .where((file) => file.path.contains('autosave'))
          .toList();

      // Keep only the most recent N backups
      if (autoSaveBackups.length > _config.maxBackups) {
        final toDelete = autoSaveBackups.sublist(_config.maxBackups);

        developer.log(
          'AutoSaveService: Cleaning up ${toDelete.length} old '
          'backup${toDelete.length == 1 ? '' : 's'}',
          name: 'AutoSaveService',
          level: 800,
        );

        for (final file in toDelete) {
          try {
            await file.delete();
            developer.log(
              'AutoSaveService: Deleted old backup: ${file.path}',
              name: 'AutoSaveService',
              level: 800,
            );
          } catch (e) {
            developer.log(
              'AutoSaveService: Failed to delete backup ${file.path}: $e',
              name: 'AutoSaveService',
              level: 900,
              error: e,
            );
          }
        }
      }
    } catch (e) {
      developer.log(
        'AutoSaveService: Error cleaning up backups: $e',
        name: 'AutoSaveService',
        level: 900,
        error: e,
      );
    }
  }

  void _updateStatus(AutoSaveStatus newStatus) {
    _status = newStatus;
    if (!_disposed) {
      _statusController.add(_status);
    }
  }

  static void _validateConfig(AutoSaveConfig config) {
    if (config.sequenceInterval <= Duration.zero ||
        config.backupInterval <= Duration.zero ||
        config.maxBackups < 1) {
      throw ArgumentError('Auto-save intervals and retention must be positive');
    }
  }

  /// Dispose of resources
  ///
  /// Note: dispose cannot be async due to Riverpod lifecycle constraints.
  /// Callers that own a graceful lifecycle must await [stop] first; launching
  /// a new asynchronous database write from a disposal callback is unsafe
  /// because its dependencies are being torn down at the same time.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sequenceTimer?.cancel();
    _sequenceTimer = null;
    _backupTimer?.cancel();
    _backupTimer = null;
    _replayPruneTimer?.cancel();
    _replayPruneTimer = null;
    _initialBackupCheckTimer?.cancel();
    _initialBackupCheckTimer = null;
    _retentionSweepTimer?.cancel();
    _retentionSweepTimer = null;
    _started = false;

    _statusController.close();
    developer.log(
      'AutoSaveService: Disposed',
      name: 'AutoSaveService',
      level: 800,
    );
  }
}

/// Provider for AutoSaveService
final autoSaveServiceProvider = Provider<AutoSaveService>((ref) {
  final backend = ref.watch(backendProvider);
  final sequenceRepo = ref.watch(sequenceRepositoryProvider);
  final backupService = ref.watch(backupServiceProvider);
  final replayDebugService = ref.watch(replayDebugServiceProvider);

  final service = AutoSaveService(
    sequenceRepository: sequenceRepo,
    backupService: backupService,
    replayDebugService: replayDebugService,
    replayRetentionDays: () =>
        ref.read(replayDebugRetentionDaysProvider.future),
    // Cloud sync — opt-in auto-push rides the daily backup cycle.
    postBackupHook: () =>
        ref.read(syncServiceProvider).maybeAutoPush(reason: 'daily backup'),
    // Living Sky derived-artifact retention rides the same schedule: both the
    // atlas cutout/delta cache and the pulled swarm blobs are regenerable and
    // would otherwise grow without bound on an appliance that runs for months.
    livingSkyRetentionSweep: () async {
      await ref.read(skyAtlasServiceProvider).sweepCache();
      await ref.read(constellationServiceProvider).sweepSwarmBlobs();
    },
    persistConfig: (config) =>
        _persistAutoSaveConfig(ref.read(settingsDaoProvider), config),
    persistLastBackup: (timestamp) => ref
        .read(settingsDaoProvider)
        .setSetting(_lastBackupKey, timestamp.toUtc().toIso8601String()),
    onSequenceSaved: (sequence, databaseId) {
      final editor = ref.read(currentSequenceProvider.notifier);
      if (identical(ref.read(currentSequenceProvider), sequence)) {
        editor.applyRemoteSave(databaseId, expectedSnapshot: sequence);
      }
    },
  );

  late final RemoteSequencePreSwapFlush preSwapFlush;
  preSwapFlush = (outgoingBackend, {required requireSuccess}) async {
    if (!identical(outgoingBackend, backend)) return;
    try {
      await service.stop();
    } catch (error, stackTrace) {
      developer.log(
        'AutoSaveService: Failed to flush before backend teardown: $error',
        name: 'AutoSaveService',
        level: 1000,
        error: error,
        stackTrace: stackTrace,
      );
      if (requireSuccess) rethrow;
    }
  };
  RemoteSequenceEditorSyncLifecycle.register(preSwapFlush);

  ref.onDispose(() {
    RemoteSequenceEditorSyncLifecycle.unregister(preSwapFlush);
    service.dispose();
  });

  return service;
});

/// Auto-save status for the UI, with `lastBackup` backfilled from the persisted
/// timestamp whenever the live service instance does not know it.
///
/// [autoSaveServiceProvider] watches [backendProvider], so a backend swap
/// during boot rebuilds it with a fresh `AutoSaveService` whose
/// `_status.lastBackup` is null even though a backup was recorded against the
/// previous instance. Reading the same settings key the writer uses surfaces
/// only timestamps that were actually recorded, whichever instance the UI
/// observes.
final autoSaveStatusProvider = StreamProvider<AutoSaveStatus>((ref) async* {
  final dao = ref.watch(settingsDaoProvider);
  DateTime? persistedLastBackup;
  try {
    final raw = await dao.getSetting(_lastBackupKey);
    if (raw != null) {
      persistedLastBackup = DateTime.tryParse(raw)?.toLocal();
    }
  } catch (_) {
    // A settings read failure must not blank the whole status card.
  }

  final service = ref.watch(autoSaveServiceProvider);
  await for (final status in service.statusStream) {
    yield status.lastBackup == null && persistedLastBackup != null
        ? status.copyWith(lastBackup: persistedLastBackup)
        : status;
  }
});

/// Host lifecycle for automatic backups. Desktop GUI and headless entry points
/// eagerly await this provider; remote clients deliberately do not, because
/// backup files and the database belong to the host.
final autoSaveLifecycleProvider = FutureProvider<AutoSaveService>((ref) async {
  final service = ref.watch(autoSaveServiceProvider);
  // StateNotifier publishes the new immutable sequence before load/create
  // methods finish resetting their dirty flag. Defer one microtask so clean
  // loads are not mistaken for edits, while real mutations remain dirty.
  ref.listen<Sequence?>(currentSequenceProvider, (previous, next) {
    if (next == null) return;
    scheduleMicrotask(() {
      if (!service.config.sequenceEnabled) return;
      if (!identical(ref.read(currentSequenceProvider), next)) return;
      final editor = ref.read(currentSequenceProvider.notifier);
      if (editor.activeOwner != ActivePlanOwner.manual || !editor.isDirty) {
        return;
      }
      service.markSequenceChanged(next);
    });
  });

  final dao = ref.watch(settingsDaoProvider);
  final config = await _loadAutoSaveConfig(dao);
  final lastBackupRaw = await dao.getSetting(_lastBackupKey);
  final lastBackup = lastBackupRaw == null
      ? null
      : DateTime.tryParse(lastBackupRaw)?.toLocal();
  service.start(config, lastBackup);
  return service;
});

/// Provider for checking if there are unsaved changes
final hasUnsavedChangesProvider = Provider<bool>((ref) {
  final service = ref.watch(autoSaveServiceProvider);
  return service.hasUnsavedChanges;
});

const _sequenceEnabledKey = 'autosave.sequence_enabled';
const _sequenceMinutesKey = 'autosave.sequence_interval_minutes';
const _backupEnabledKey = 'autosave.backup_enabled';
const _backupHoursKey = 'autosave.backup_interval_hours';
const _maxBackupsKey = 'autosave.max_backups';

/// Same key [BackupService] writes on every successful backup, manual or
/// scheduled — one owner, so the displayed "Last Full Backup" cannot disagree
/// with what is actually on disk.
const _lastBackupKey = BackupService.lastBackupSettingKey;

Future<AutoSaveConfig> _loadAutoSaveConfig(SettingsDao dao) async {
  final values = await dao.getAllSettings();
  int positiveInt(String key, int fallback) {
    final parsed = int.tryParse(values[key] ?? '');
    return parsed != null && parsed > 0 ? parsed : fallback;
  }

  bool flag(String key, bool fallback) {
    final value = values[key]?.toLowerCase();
    if (value == 'true') return true;
    if (value == 'false') return false;
    return fallback;
  }

  return AutoSaveConfig(
    sequenceEnabled: flag(_sequenceEnabledKey, false),
    sequenceInterval: Duration(minutes: positiveInt(_sequenceMinutesKey, 2)),
    backupEnabled: flag(_backupEnabledKey, true),
    backupInterval: Duration(hours: positiveInt(_backupHoursKey, 24)),
    maxBackups: positiveInt(_maxBackupsKey, 7),
  );
}

Future<void> _persistAutoSaveConfig(SettingsDao dao, AutoSaveConfig config) =>
    dao.setSettings(<String, String>{
      _sequenceEnabledKey: config.sequenceEnabled.toString(),
      _sequenceMinutesKey: config.sequenceInterval.inMinutes.toString(),
      _backupEnabledKey: config.backupEnabled.toString(),
      _backupHoursKey: config.backupInterval.inHours.toString(),
      _maxBackupsKey: config.maxBackups.toString(),
    });
