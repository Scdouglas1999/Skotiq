import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_astro/format.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as path;

import '../../utils/confirm_dialog.dart';
import '../../utils/exported_file_reveal.dart';
import '../../utils/snackbar_helper.dart';
import 'backup_list_entry.dart';
import 'widgets/admin_only.dart';
import 'widgets/cloud_sync_settings.dart';

part 'backup_screen/restore_widgets.dart';

typedef BackupDownloadSavePicker = Future<ExportTarget?> Function(
  String suggestedName,
);
typedef BackupImportPicker = Future<XFile?> Function();
typedef BackupImportReader = Future<List<int>> Function(XFile file);

Future<XFile?> _pickBackupImport() {
  return openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: 'Skotiq backup',
        // '.nsbackup' keeps pre-rename backup files selectable.
        extensions: ['skbackup', 'nsbackup', 'json'],
      ),
    ],
  );
}

final backupImportPickerProvider =
    Provider<BackupImportPicker>((ref) => _pickBackupImport);

final backupImportReaderProvider = Provider<BackupImportReader>(
  (ref) => (file) => File(file.path).readAsBytes(),
);

/// Outcome of the last restore, held until the operator dismisses it.
///
/// A restore rewrites the database under a running app, so from that moment
/// every screen shows in-memory state that disagrees with what is on disk — and
/// the operator is usually about to observe.
///
/// A provider and not [State]: the condition outlives the Backup & Restore
/// screen, and leaving that screen is the very next thing the operator does, so
/// screen state would be cleared by exactly the action that makes it matter.
/// In-memory and never persisted is the right lifetime — restarting Skotiq
/// is what resolves the condition, and a restart clears the provider for free.
final restoreRestartNoticeProvider = StateProvider<String?>((ref) => null);

final backupDownloadSavePickerProvider =
    Provider<BackupDownloadSavePicker>((ref) {
  return (suggestedName) => chooseExportTarget(
        suggestedName: suggestedName,
        acceptedTypeGroups: const [
          XTypeGroup(
            label: 'Skotiq backup',
            extensions: ['skbackup', 'json'],
          ),
        ],
      );
});

class BackupScreen extends ConsumerStatefulWidget {
  const BackupScreen({super.key});

  @override
  ConsumerState<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends ConsumerState<BackupScreen> {
  bool _isCreatingBackup = false;
  bool _isRestoring = false;
  bool _isImportingBackup = false;
  bool _isManagingBackup = false;
  bool _isLoadingBackups = true;
  List<BackupListEntry> _availableBackups = const [];

  /// How far the backup or restore that is running has got.
  RestoreProgress? _progress;

  /// The replace that waits for the next start of the app (or of the linked
  /// host), and what the last start did with one.
  _ReplaceState _replace = const _ReplaceState();

  /// Monotonic counter identifying the most recent [_loadAvailableBackups]
  /// call. A slow list from an old rig must not paint over a newer load (or a
  /// screen that has since switched hosts), so only the request matching the
  /// current generation is allowed to apply its result.
  int _loadGeneration = 0;
  int _importGeneration = 0;

  /// Backend identity ([backendBackupToken]) that produced [_availableBackups].
  /// Row actions are rejected when the live backend no longer matches this, so
  /// a row from host A can never be dispatched to host B (or the local store).
  String? _loadedBackendToken;

  /// Last list-load failure, surfaced inline with a Retry affordance instead of
  /// a transient snackbar so the user can actually recover.
  String? _loadError;

  bool get _isBusy =>
      _isCreatingBackup ||
      _isRestoring ||
      _isImportingBackup ||
      _isManagingBackup;

  bool _rejectIfBusy() {
    if (!_isBusy) return false;
    context.showWarningSnackBar(
      'Wait for the current backup or restore operation to finish.',
    );
    return true;
  }

  /// True (warns + reloads) when the backend that produced the current list
  /// differs from the live backend. Guards every row action so a stale row is
  /// never sent to the wrong host.
  bool _rejectIfBackendChanged() {
    if (_loadedBackendToken == null) return false;
    final token = backendBackupToken(ref.read(backendProvider));
    if (token == _loadedBackendToken) return false;
    context.showWarningSnackBar(
      'The connected host changed. Refreshing the backup list.',
    );
    _loadAvailableBackups();
    return true;
  }

  /// Whether the live backend still matches [token]. Used after an await to
  /// skip applying stale success/refresh UI once the user has switched hosts
  /// mid-operation.
  bool _backendStillMatches(String token) =>
      backendBackupToken(ref.read(backendProvider)) == token;

  bool _rejectRestoreDuringActiveRun() {
    final execution = ref.read(sequenceExecutionStateProvider);
    if (!ref.read(sessionStateProvider).isCapturing && !execution.isBusy) {
      return false;
    }
    context.showWarningSnackBar(
      'Stop the active capture or sequence before restoring a backup.',
    );
    return true;
  }

  /// Records a finished merge as a banner that stays until dismissed.
  ///
  /// Not a snackbar: the condition it describes (a running app over a
  /// database that just changed) outlives any transient message. Written to
  /// [restoreRestartNoticeProvider] and not to this [State], so leaving the
  /// screen does not clear it. A replace has its own banner, read from where
  /// the replace is recorded ([_loadReplaceState]).
  void _announceMerge(String report, {required bool remote}) {
    ref.read(restoreRestartNoticeProvider.notifier).state = remote
        ? report
        : '$report Restart Skotiq before the next run: until then some '
            'screens show what they held before the restore.';
  }

  /// Runs one restore, here or on the linked host, showing how far it is,
  /// and announces a merge that worked. Throws when the restore fails.
  Future<void> _runRestore({
    required RestoreMode mode,
    required HostBackups? hostBackups,
    required Future<Map<String, dynamic>> Function(HostBackups host) onHost,
    required String localPath,
    required bool Function() stillCurrent,
  }) async {
    Timer? poll;
    setState(() => _progress = const RestoreProgress('Reading the backup', 0));
    try {
      if (hostBackups != null) {
        poll = _followHostProgress(hostBackups);
        final result = await onHost(hostBackups);
        final status = result['status'] as String?;
        if (status != 'restored' && status != 'staged') {
          throw Exception(result['error'] ?? 'Restore failed');
        }
        if (!stillCurrent()) return;
        if (status == 'restored') {
          _refreshAfterRestore();
          _announceMerge(
            result['message'] as String? ?? restoreReportFromWire(result),
            remote: true,
          );
        }
      } else {
        final result = await ref.read(backupServiceProvider).restoreBackup(
              filePath: localPath,
              mode: mode,
              onProgress: (progress) {
                if (mounted) setState(() => _progress = progress);
              },
            );
        if (!result.success) {
          throw Exception(result.errorMessage ?? 'Restore failed');
        }
        if (!stillCurrent()) return;
        if (!result.pendingRestart) {
          _refreshAfterRestore();
          _announceMerge(result.report, remote: false);
        }
      }
      await _loadAvailableBackups();
    } finally {
      poll?.cancel();
      if (mounted) setState(() => _progress = null);
    }
  }

  /// Shows how far the linked host is with the backup or restore it is
  /// running for this screen, until the returned timer is canceled.
  Timer _followHostProgress(HostBackups hostBackups) =>
      Timer.periodic(const Duration(seconds: 1), (_) async {
        try {
          final state = await hostBackups.restoreState();
          final progress = state['progress'];
          if (mounted && _progress != null && progress is Map) {
            setState(
              () => _progress = RestoreProgress(
                progress['step'] as String? ?? 'Working',
                (progress['fraction'] as num?)?.toDouble() ?? 0,
              ),
            );
          }
        } catch (_) {
          // The operation's own answer says how it went.
        }
      });

  /// Reads the replace that waits for a restart and the record of the last
  /// one, from this database or from the linked host.
  Future<void> _loadReplaceState(HostBackups? hostBackups) async {
    try {
      final _ReplaceState state;
      if (hostBackups != null) {
        final body = await hostBackups.restoreState();
        final pending = body['pendingReplace'];
        final last = body['lastReplace'];
        state = _ReplaceState(
          pendingBackup:
              pending is Map ? pending['backupName'] as String? : null,
          pendingSafetyBackup:
              pending is Map ? pending['safetyBackup'] as String? : null,
          outcome: last is Map ? last['report'] as String? : null,
          outcomeRestored: last is Map && last['restored'] == true,
        );
      } else {
        final service = ref.read(backupServiceProvider);
        final pending = await service.pendingReplace();
        final last = await service.replaceOutcome();
        state = _ReplaceState(
          pendingBackup: pending?.backupName,
          pendingSafetyBackup: pending?.safetyBackupName,
          outcome: last?.report,
          outcomeRestored: last?.restored ?? false,
        );
      }
      if (mounted) setState(() => _replace = state);
    } catch (_) {
      // The list load reports a host that cannot be reached.
    }
  }

  Future<void> _cancelReplace() async {
    final hostBackups = ref.read(linkedHostBackupsProvider);
    try {
      if (hostBackups != null) {
        await hostBackups.cancelReplace();
      } else {
        await ref.read(backupServiceProvider).cancelPendingReplace();
      }
      if (!mounted) return;
      context.showSuccessSnackBar('The replace was canceled.');
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Could not cancel: ${userFacingError(e)}');
    }
    await _loadReplaceState(hostBackups);
  }

  Future<void> _dismissReplaceOutcome() async {
    final hostBackups = ref.read(linkedHostBackupsProvider);
    try {
      if (hostBackups != null) {
        await hostBackups.acknowledgeReplace();
      } else {
        await ref.read(backupServiceProvider).dismissReplaceOutcome();
      }
    } catch (_) {
      // It is shown again next time.
    }
    await _loadReplaceState(hostBackups);
  }

  void _refreshAfterRestore() {
    ref.invalidate(appSettingsProvider);
    ref.invalidate(equipmentProfilesProvider);
    ref.invalidate(savedSequencesProvider);
  }

  @override
  void initState() {
    super.initState();
    _loadAvailableBackups();
  }

  Future<void> _loadAvailableBackups() async {
    final generation = ++_loadGeneration;
    final backend = ref.read(backendProvider);
    final hostBackups = ref.read(linkedHostBackupsProvider);
    final token = backendBackupToken(backend);
    setState(() {
      _isLoadingBackups = true;
      _loadError = null;
    });
    try {
      final entries = hostBackups != null
          ? parseRemoteBackupList(await hostBackups.listBackups())
          : await Future.wait(
              (await ref.read(backupServiceProvider).listBackups())
                  .map(BackupListEntry.fromLocalFile),
            );
      // Drop the result if a newer load has started or the screen switched
      // hosts while this one was in flight — an old rig must not populate the
      // current screen.
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _availableBackups = entries;
        _loadedBackendToken = token;
        _isLoadingBackups = false;
      });
      await _loadReplaceState(hostBackups);
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _isLoadingBackups = false;
        _loadError = 'Failed to load backups: ${userFacingError(e)}';
      });
    }
  }

  Future<void> _createBackup() async {
    if (_rejectIfBusy()) return;
    final backend = ref.read(backendProvider);
    final hostBackups = ref.read(linkedHostBackupsProvider);
    final token = backendBackupToken(backend);
    setState(() {
      _isCreatingBackup = true;
      _progress = const RestoreProgress('Writing the backup', 0);
    });
    Timer? poll;
    try {
      String? createdPath;
      if (hostBackups != null) {
        poll = _followHostProgress(hostBackups);
        final result = await hostBackups.createBackup();
        if ((result['status'] as String?) != 'created') {
          throw Exception(result['error'] ?? 'Backup failed');
        }
        createdPath = result['filePath'] as String?;
      } else {
        final result = await ref.read(backupServiceProvider).createBackup(
          onProgress: (fraction) {
            if (mounted) {
              setState(
                () =>
                    _progress = RestoreProgress('Writing the backup', fraction),
              );
            }
          },
        );
        if (!result.success) {
          throw Exception(result.errorMessage ?? 'Backup failed');
        }
        createdPath = result.filePath;
      }

      // If the host switched mid-create, the new backup belongs to the old
      // host; don't paint success against the new one.
      if (!mounted || !_backendStillMatches(token)) return;
      // The "Last Full Backup" summary is fed by a provider that reads the
      // persisted timestamp when its stream starts, so it has to be re-read
      // now — otherwise the card keeps showing the previous (or "Never") time
      // right above the button that was just pressed.
      ref.invalidate(autoSaveStatusProvider);
      context.showSuccessSnackBar(
        createdPath == null || createdPath.isEmpty
            ? 'Backup created successfully'
            : 'Backup created: ${path.basename(createdPath)}',
      );
      await _loadAvailableBackups();
    } catch (e) {
      if (!mounted || !_backendStillMatches(token)) return;
      context.showErrorSnackBar('Error creating backup: ${userFacingError(e)}');
    } finally {
      poll?.cancel();
      if (mounted) {
        setState(() {
          _isCreatingBackup = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _restoreBackup(BackupListEntry backup) async {
    if (_rejectIfBusy() ||
        _rejectRestoreDuringActiveRun() ||
        _rejectIfBackendChanged()) {
      return;
    }
    // Capture the backend up front and dispatch to it, so a host switch after
    // the confirm dialog can't send this row to a different host.
    final backend = ref.read(backendProvider);
    final hostBackups = ref.read(linkedHostBackupsProvider);
    final token = backendBackupToken(backend);
    final mode = await _RestoreChoiceDialog.show(
      context,
      backupName: backup.fileName,
      onHost: hostBackups != null,
    );
    if (mode == null || !mounted || _rejectIfBusy()) return;
    if (!_backendStillMatches(token)) {
      context
          .showWarningSnackBar('The connected host changed. Restore canceled.');
      await _loadAvailableBackups();
      return;
    }

    setState(() => _isRestoring = true);
    try {
      await _runRestore(
        mode: mode,
        hostBackups: hostBackups,
        // By its id: the host resolves it to a file in its own backup
        // folder, so no server path crosses the wire.
        onHost: (host) => host.restoreBackupById(backup.id, mode: mode),
        localPath: backup.filePath,
        stillCurrent: () => mounted && _backendStillMatches(token),
      );
    } catch (e) {
      if (!mounted || !_backendStillMatches(token)) return;
      context.showErrorSnackBar('Restore failed: ${userFacingError(e)}');
    } finally {
      if (mounted) {
        setState(() => _isRestoring = false);
      }
    }
  }

  Future<void> _importBackup() async {
    if (_rejectIfBusy() || _rejectRestoreDuringActiveRun()) return;
    final generation = ++_importGeneration;
    final backend = ref.read(backendProvider);
    final hostBackups = ref.read(linkedHostBackupsProvider);
    final token = backendBackupToken(backend);
    setState(() => _isImportingBackup = true);

    try {
      final file = await ref.read(backupImportPickerProvider)();
      if (file == null || !mounted || !_isCurrentImport(generation, token)) {
        return;
      }
      if (_rejectRestoreDuringActiveRun()) return;

      final mode = await _RestoreChoiceDialog.show(
        context,
        backupName: path.basename(file.path),
        onHost: hostBackups != null,
      );
      if (mode == null || !_isCurrentImport(generation, token)) return;
      if (_rejectRestoreDuringActiveRun()) return;

      await _runRestore(
        mode: mode,
        hostBackups: hostBackups,
        onHost: (host) async {
          final bytes = await ref.read(backupImportReaderProvider)(file);
          return host.uploadBackupAndRestore(
            Uint8List.fromList(bytes),
            path.basename(file.path),
            mode: mode,
          );
        },
        localPath: file.path,
        stillCurrent: () => _isCurrentImport(generation, token),
      );
    } catch (e) {
      if (!mounted || !_isCurrentImport(generation, token)) return;
      context.showErrorSnackBar('Import failed: ${userFacingError(e)}');
    } finally {
      if (_isCurrentImport(generation, token)) {
        setState(() => _isImportingBackup = false);
      }
    }
  }

  bool _isCurrentImport(int generation, String token) {
    return mounted &&
        generation == _importGeneration &&
        _backendStillMatches(token);
  }

  Future<void> _deleteBackup(BackupListEntry backup) async {
    if (_rejectIfBusy() || _rejectIfBackendChanged()) return;
    final backend = ref.read(backendProvider);
    final hostBackups = ref.read(linkedHostBackupsProvider);
    final token = backendBackupToken(backend);
    final confirmed = await ConfirmDialog.delete(
      context: context,
      itemName: 'backup "${backup.fileName}"',
    );
    if (!confirmed || !mounted || _rejectIfBusy()) return;
    if (!_backendStillMatches(token)) {
      context
          .showWarningSnackBar('The connected host changed. Delete canceled.');
      await _loadAvailableBackups();
      return;
    }

    setState(() => _isManagingBackup = true);
    try {
      if (hostBackups != null) {
        await hostBackups.deleteBackup(backup.id);
      } else {
        await File(backup.filePath).delete();
      }
      if (!mounted || !_backendStillMatches(token)) return;
      context.showSuccessSnackBar('Backup deleted');
      await _loadAvailableBackups();
    } catch (e) {
      if (!mounted || !_backendStillMatches(token)) return;
      context
          .showErrorSnackBar('Failed to delete backup: ${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _isManagingBackup = false);
    }
  }

  /// Downloads a backup from a remote host.
  ///
  /// Android and iOS have no save dialog — `getSavePath` throws
  /// UnimplementedError — so on those platforms the file goes to a sandbox path
  /// and this finishes with the share sheet instead.
  Future<void> _downloadBackup(BackupListEntry backup) async {
    if (_rejectIfBusy() || _rejectIfBackendChanged()) return;
    final backend = ref.read(backendProvider);
    final hostBackups = ref.read(linkedHostBackupsProvider);
    if (hostBackups == null) return;
    final token = backendBackupToken(backend);
    setState(() => _isManagingBackup = true);
    try {
      // Reserve the operation before opening the native dialog. Without this,
      // repeated clicks could launch multiple save pickers and downloads.
      final target = await ref.read(backupDownloadSavePickerProvider)(
        backup.fileName,
      );
      if (target == null || !mounted) return;
      if (!_backendStillMatches(token)) {
        context.showWarningSnackBar(
          'The connected host changed. Download canceled.',
        );
        return;
      }

      final bytes = await hostBackups.downloadBackup(backup.id);
      await File(target.path).writeAsBytes(bytes, flush: true);
      if (!mounted || !_backendStillMatches(token)) return;
      await revealExportedFile(
        context,
        target.path,
        subject: 'Skotiq backup',
        desktopMessage: 'Saved backup to ${target.path}',
      );
    } catch (e) {
      if (!mounted || !_backendStillMatches(token)) return;
      context.showErrorSnackBar('Download failed: ${userFacingError(e)}');
    } finally {
      if (mounted) setState(() => _isManagingBackup = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isRemoteMode = ref.watch(isRemoteModeProvider);
    final backend = ref.watch(backendProvider);
    final autoSaveStatus =
        isRemoteMode ? null : ref.watch(autoSaveStatusProvider);
    final restoreNotice = ref.watch(restoreRestartNoticeProvider);

    // Reload when the active backend changes (connect / disconnect / switch
    // rig) so the list — and the identity token guarding row actions — always
    // reflects the live host instead of a stale one from a previous backend.
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (previous == null) return;
      if (backendBackupToken(previous) != backendBackupToken(next)) {
        _importGeneration++;
        if (_isImportingBackup) {
          setState(() => _isImportingBackup = false);
        }
        // After this notification: the backups half the load reads is
        // rebuilt only once the backend's listeners have run.
        Future.microtask(() {
          if (mounted) _loadAvailableBackups();
        });
      }
    });

    return Scaffold(
      body: Column(
        children: [
          // The subtitle is gone with ScreenHeader: "Manage your Skotiq
          // data backups" under a heading that reads "Backup & restore" said
          // nothing the title had not. Where the backups actually LIVE is a
          // fact, so it stays, as the header's one muted context line.
          PageHeader(
            icon: LucideIcons.save,
            title: 'Backup & restore',
            context: isRemoteMode ? 'On the connected host' : null,
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (_replace.pendingBackup case final pending?) ...[
                    _NoticeBanner(
                      title: 'Replace waits for a restart',
                      message: '"$pending" replaces '
                          '${isRemoteMode ? "the imaging computer's database when Skotiq next starts there" : 'this database when Skotiq next starts'}. '
                          'Until then the current database is in use, and '
                          'what is recorded in it from now on is not kept.'
                          '${_replace.pendingSafetyBackup == null ? '' : ' The database as it was is saved as ${_replace.pendingSafetyBackup}.'}',
                      actions: [
                        if (!isRemoteMode &&
                            ref.watch(appRelauncherProvider) != null)
                          SkotiqButton(
                            label: 'Restart now',
                            variant: ButtonVariant.primary,
                            size: ButtonSize.small,
                            onPressed: () => ref
                                .read(appRelauncherProvider)
                                ?.relaunch(
                                  reason: 'Replace the database with a backup',
                                ),
                          ),
                        SkotiqButton(
                          label: 'Cancel replace',
                          variant: ButtonVariant.ghost,
                          size: ButtonSize.small,
                          onPressed: _cancelReplace,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                  if (_replace.outcome case final outcome?) ...[
                    _NoticeBanner(
                      title: _replace.outcomeRestored
                          ? 'Database replaced'
                          : 'Database not replaced',
                      message: outcome,
                      actions: [
                        SkotiqButton(
                          label: 'Dismiss',
                          variant: ButtonVariant.ghost,
                          size: ButtonSize.small,
                          onPressed: _dismissReplaceOutcome,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                  if (restoreNotice != null) ...[
                    _NoticeBanner(
                      title: 'Backup restored',
                      message: restoreNotice,
                      actions: [
                        SkotiqButton(
                          label: 'Dismiss',
                          variant: ButtonVariant.ghost,
                          size: ButtonSize.small,
                          onPressed: () => ref
                              .read(restoreRestartNoticeProvider.notifier)
                              .state = null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                  ],
                  if (_progress case final progress?) ...[
                    _BackupProgressCard(progress: progress),
                    const SizedBox(height: 24),
                  ],
                  if (!isRemoteMode) ...[
                    _AutoSaveStatusCard(statusAsync: autoSaveStatus!),
                    const SizedBox(height: 24),
                  ],
                  if (hostRefusesAdminOnly(ref))
                    const AdminOnlyBanner(
                      title: 'Backups and cloud sync are managed on the '
                          'imaging computer',
                    )
                  else ...[
                    _QuickActionsCard(
                      isCreatingBackup: _isCreatingBackup,
                      isRestoring: _isRestoring,
                      isImportingBackup: _isImportingBackup,
                      onCreateBackup: _isBusy ? null : _createBackup,
                      onImportBackup: _isBusy ? null : _importBackup,
                    ),
                    const SizedBox(height: 24),
                    if (isRemoteMode)
                      RemoteCloudSyncCard(
                        key: ValueKey(backendBackupToken(backend)),
                      )
                    else
                      const CloudSyncCard(),
                    const SizedBox(height: 24),
                    _RecentBackupsCard(
                      isRemoteMode: isRemoteMode,
                      isLoading: _isLoadingBackups,
                      errorMessage: _loadError,
                      backups: _availableBackups,
                      onRefresh: _loadAvailableBackups,
                      onRestore: _restoreBackup,
                      onDelete: _deleteBackup,
                      onDownload: _downloadBackup,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AutoSaveStatusCard extends ConsumerWidget {
  final AsyncValue<AutoSaveStatus> statusAsync;

  const _AutoSaveStatusCard({required this.statusAsync});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    return Card(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: statusAsync.when(
          data: (status) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Auto-Save Status',
                style: SkotiqTypography.sectionTitle
                    .copyWith(color: colors.textPrimary),
              ),
              const SizedBox(height: 16),
              _StatusRow(
                label: 'Last Sequence Save',
                value: status.lastSequenceSave == null
                    ? 'Never'
                    : ClockFormat.monthDayYearHm(
                        status.lastSequenceSave!.toLocal(),
                      ),
              ),
              const SizedBox(height: 12),
              _StatusRow(
                label: 'Last Full Backup',
                value: status.lastBackup == null
                    ? 'Never'
                    : ClockFormat.monthDayYearHm(status.lastBackup!.toLocal()),
              ),
              if (status.lastError != null) ...[
                const SizedBox(height: 12),
                Text(
                  status.lastError!,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.error,
                  ),
                ),
              ],
            ],
          ),
          loading: () => const Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
          error: (error, _) => Text(
            'Could not load auto-save status.',
            style: SkotiqTypography.body.copyWith(
              color: colors.error,
            ),
          ),
        ),
      ),
    );
  }
}

class _QuickActionsCard extends StatelessWidget {
  final bool isCreatingBackup;
  final bool isRestoring;
  final bool isImportingBackup;
  final VoidCallback? onCreateBackup;
  final VoidCallback? onImportBackup;

  const _QuickActionsCard({
    required this.isCreatingBackup,
    required this.isRestoring,
    required this.isImportingBackup,
    required this.onCreateBackup,
    required this.onImportBackup,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Card(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Quick Actions',
              style: SkotiqTypography.sectionTitle
                  .copyWith(color: colors.textPrimary),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: SkotiqButton(
                    label: isCreatingBackup ? 'Creating...' : 'Create Backup',
                    icon: LucideIcons.download,
                    variant: ButtonVariant.primary,
                    isLoading: isCreatingBackup,
                    onPressed: onCreateBackup,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: SkotiqButton(
                    label: isImportingBackup
                        ? 'Importing...'
                        : isRestoring
                            ? 'Restoring...'
                            : 'Import Backup',
                    icon: LucideIcons.upload,
                    variant: ButtonVariant.secondary,
                    isLoading: isRestoring || isImportingBackup,
                    onPressed: onImportBackup,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentBackupsCard extends StatelessWidget {
  final bool isRemoteMode;
  final bool isLoading;
  final String? errorMessage;
  final List<BackupListEntry> backups;
  final VoidCallback onRefresh;
  final Future<void> Function(BackupListEntry backup) onRestore;
  final Future<void> Function(BackupListEntry backup) onDelete;
  final Future<void> Function(BackupListEntry backup) onDownload;

  const _RecentBackupsCard({
    required this.isRemoteMode,
    required this.isLoading,
    required this.errorMessage,
    required this.backups,
    required this.onRefresh,
    required this.onRestore,
    required this.onDelete,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Card(
      color: colors.surface,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Recent Backups',
                  style: SkotiqTypography.sectionTitle
                      .copyWith(color: colors.textPrimary),
                ),
                const Spacer(),
                SkotiqIconButton(
                  icon: LucideIcons.refreshCw,
                  tooltip: 'Refresh',
                  onPressed: isLoading ? null : onRefresh,
                  size: IconButtonSize.md,
                  color: colors.textSecondary,
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (isLoading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
                ),
              )
            else if (errorMessage != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(LucideIcons.alertTriangle,
                          size: 40, color: colors.error),
                      const SizedBox(height: 12),
                      Text(
                        errorMessage!,
                        textAlign: TextAlign.center,
                        style: SkotiqTypography.body.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SkotiqButton(
                        label: 'Retry',
                        icon: LucideIcons.refreshCw,
                        variant: ButtonVariant.secondary,
                        onPressed: onRefresh,
                      ),
                    ],
                  ),
                ),
              )
            else if (backups.isEmpty)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      Icon(LucideIcons.inbox,
                          size: 48, color: colors.textMuted),
                      const SizedBox(height: 12),
                      Text(
                        'No backups found',
                        style: SkotiqTypography.body.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: backups.length,
                separatorBuilder: (context, index) =>
                    Divider(color: colors.border),
                itemBuilder: (context, index) {
                  final backup = backups[index];
                  return _BackupTile(
                    isRemoteMode: isRemoteMode,
                    backup: backup,
                    onRestore: () => onRestore(backup),
                    onDelete: () => onDelete(backup),
                    onDownload: () => onDownload(backup),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

class _BackupTile extends StatelessWidget {
  final bool isRemoteMode;
  final BackupListEntry backup;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  final VoidCallback onDownload;

  const _BackupTile({
    required this.isRemoteMode,
    required this.backup,
    required this.onRestore,
    required this.onDelete,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final isAutoSave = backup.fileName.contains('autosave');
    final timestamp = ClockFormat.monthDayYearHm(backup.createdAt.toLocal());

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: SkotiqDecorations.chip(colors,
            tone: isAutoSave ? colors.warning : colors.primary),
        child: Icon(
          isAutoSave ? LucideIcons.clock : LucideIcons.database,
          size: 20,
          color: isAutoSave ? colors.warning : colors.primary,
        ),
      ),
      title: Text(
        backup.fileName,
        style: SkotiqTypography.label.copyWith(color: colors.textPrimary),
      ),
      subtitle: Text(
        '${ByteFormat.size(backup.fileSize)} | $timestamp',
        style: SkotiqTypography.caption.copyWith(
          color: colors.textSecondary,
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SkotiqIconButton(
            icon: LucideIcons.upload,
            tooltip: 'Restore',
            onPressed: onRestore,
            size: IconButtonSize.md,
            color: colors.primary,
          ),
          if (isRemoteMode)
            SkotiqIconButton(
              icon: LucideIcons.download,
              tooltip: 'Download',
              onPressed: onDownload,
              size: IconButtonSize.md,
              color: colors.textSecondary,
            ),
          SkotiqIconButton(
            icon: LucideIcons.trash2,
            tooltip: 'Delete',
            onPressed: onDelete,
            size: IconButtonSize.md,
            color: colors.error,
          ),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final String label;
  final String value;

  const _StatusRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: SkotiqTypography.caption.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              Text(
                value,
                style: SkotiqTypography.bodyMedium.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
