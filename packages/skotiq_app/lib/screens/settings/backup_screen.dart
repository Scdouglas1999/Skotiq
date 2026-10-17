import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:path/path.dart' as path;

import '../../utils/confirm_dialog.dart';
import '../../utils/exported_file_reveal.dart';
import '../../utils/snackbar_helper.dart';
import 'backup_list_entry.dart';
import 'widgets/cloud_sync_settings.dart';

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
        extensions: ['nsbackup', 'json'],
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
            extensions: ['nsbackup', 'json'],
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

  /// Records a completed restore as a banner that stays until dismissed.
  ///
  /// Not a snackbar: the condition it describes (running app, freshly rewritten
  /// database) outlives any transient message, and the restart is the operator's
  /// to perform. Written to [restoreRestartNoticeProvider] rather than to this
  /// [State] so leaving the screen does not clear it.
  void _announceRestore(int itemsRestored, {required bool remote}) {
    ref.read(restoreRestartNoticeProvider.notifier).state = remote
        ? 'Restored $itemsRestored items to the imaging host. Restart the '
            'host before the next run — until then it is running on the '
            'state it had before the restore.'
        : 'Restored $itemsRestored items. Restart Skotiq before the next '
            'run — until then this app is showing the state it had before '
            'the restore.';
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
    final token = backendBackupToken(backend);
    setState(() {
      _isLoadingBackups = true;
      _loadError = null;
    });
    try {
      final entries = backend is NetworkBackend
          ? parseRemoteBackupList(await backend.listBackups())
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
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _isLoadingBackups = false;
        _loadError = 'Failed to load backups: $e';
      });
    }
  }

  Future<void> _createBackup() async {
    if (_rejectIfBusy()) return;
    final backend = ref.read(backendProvider);
    final token = backendBackupToken(backend);
    setState(() => _isCreatingBackup = true);
    try {
      String? createdPath;
      if (backend is NetworkBackend) {
        final result = await backend.createBackup();
        if ((result['status'] as String?) != 'created') {
          throw Exception(result['error'] ?? 'Backup failed');
        }
        createdPath = result['filePath'] as String?;
      } else {
        final result = await ref.read(backupServiceProvider).createBackup();
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
      context.showErrorSnackBar('Error creating backup: $e');
    } finally {
      if (mounted) {
        setState(() => _isCreatingBackup = false);
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
    final token = backendBackupToken(backend);
    final confirmed = await ConfirmDialog.restore(
      context: context,
      backupName: backup.fileName,
    );
    if (!confirmed || !mounted || _rejectIfBusy()) return;
    if (!_backendStillMatches(token)) {
      context.showWarningSnackBar(
          'The connected host changed. Restore cancelled.');
      await _loadAvailableBackups();
      return;
    }

    setState(() => _isRestoring = true);
    try {
      if (backend is NetworkBackend) {
        // Address the backup by its stable id — the host resolves it to a file
        // inside its backup directory, so no absolute server path crosses the
        // wire and the host can't be pointed at an arbitrary file.
        final result = await backend.restoreBackupById(backup.id);
        if ((result['status'] as String?) != 'restored') {
          throw Exception(result['error'] ?? 'Restore failed');
        }
        final restored = result['itemsRestored'] as int? ?? 0;
        if (!mounted || !_backendStillMatches(token)) return;
        _refreshAfterRestore();
        _announceRestore(restored, remote: true);
      } else {
        final result = await ref.read(backupServiceProvider).restoreBackup(
              filePath: backup.filePath,
              replaceExisting: false,
            );
        if (!result.success) {
          throw Exception(result.errorMessage ?? 'Restore failed');
        }
        if (!mounted || !_backendStillMatches(token)) return;
        _refreshAfterRestore();
        _announceRestore(result.itemsRestored, remote: false);
      }
    } catch (e) {
      if (!mounted || !_backendStillMatches(token)) return;
      context.showErrorSnackBar('Restore failed: $e');
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
    final token = backendBackupToken(backend);
    setState(() => _isImportingBackup = true);

    try {
      final file = await ref.read(backupImportPickerProvider)();
      if (file == null || !mounted || !_isCurrentImport(generation, token)) {
        return;
      }
      if (_rejectRestoreDuringActiveRun()) return;

      final confirmed = await ConfirmDialog.restore(
        context: context,
        backupName: path.basename(file.path),
      );
      if (!confirmed || !_isCurrentImport(generation, token)) return;
      if (_rejectRestoreDuringActiveRun()) return;

      int restored;
      if (backend is NetworkBackend) {
        final bytes = await ref.read(backupImportReaderProvider)(file);
        if (!_isCurrentImport(generation, token)) return;
        final result = await backend.uploadBackupAndRestore(
          Uint8List.fromList(bytes),
          path.basename(file.path),
        );
        if ((result['status'] as String?) != 'restored') {
          throw Exception(result['error'] ?? 'Restore failed');
        }
        restored = result['itemsRestored'] as int? ?? 0;
      } else {
        final result = await ref.read(backupServiceProvider).restoreBackup(
              filePath: file.path,
              replaceExisting: false,
            );
        if (!result.success) {
          throw Exception(result.errorMessage ?? 'Restore failed');
        }
        restored = result.itemsRestored;
      }

      if (!mounted || !_isCurrentImport(generation, token)) return;
      _refreshAfterRestore();
      _announceRestore(restored, remote: backend is NetworkBackend);
      await _loadAvailableBackups();
    } catch (e) {
      if (!mounted || !_isCurrentImport(generation, token)) return;
      context.showErrorSnackBar('Import failed: $e');
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
    final token = backendBackupToken(backend);
    final confirmed = await ConfirmDialog.delete(
      context: context,
      itemName: 'backup "${backup.fileName}"',
    );
    if (!confirmed || !mounted || _rejectIfBusy()) return;
    if (!_backendStillMatches(token)) {
      context
          .showWarningSnackBar('The connected host changed. Delete cancelled.');
      await _loadAvailableBackups();
      return;
    }

    setState(() => _isManagingBackup = true);
    try {
      if (backend is NetworkBackend) {
        await backend.deleteBackup(backup.id);
      } else {
        await File(backup.filePath).delete();
      }
      if (!mounted || !_backendStillMatches(token)) return;
      context.showSuccessSnackBar('Backup deleted');
      await _loadAvailableBackups();
    } catch (e) {
      if (!mounted || !_backendStillMatches(token)) return;
      context.showErrorSnackBar('Failed to delete backup: $e');
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
    if (backend is! NetworkBackend) return;
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
          'The connected host changed. Download cancelled.',
        );
        return;
      }

      final bytes = await backend.downloadBackup(backup.id);
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
      context.showErrorSnackBar('Download failed: $e');
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
        _loadAvailableBackups();
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
                  if (restoreNotice != null) ...[
                    _RestoreNoticeBanner(
                      message: restoreNotice,
                      onDismiss: () => ref
                          .read(restoreRestartNoticeProvider.notifier)
                          .state = null,
                    ),
                    const SizedBox(height: 24),
                  ],
                  if (!isRemoteMode) ...[
                    _AutoSaveStatusCard(statusAsync: autoSaveStatus!),
                    const SizedBox(height: 24),
                  ],
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
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Stays on the Backup & Restore screen after a restore until dismissed.
class _RestoreNoticeBanner extends StatelessWidget {
  final String message;
  final VoidCallback onDismiss;

  const _RestoreNoticeBanner({required this.message, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.warning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.refreshCw, size: 18, color: colors.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Restart required',
                  style: SkotiqTypography.labelStrong
                      .copyWith(color: colors.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: SkotiqTypography.caption.copyWith(
                    color: colors.textSecondary,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          SkotiqButton(
            label: 'Dismiss',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: onDismiss,
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
                    : DateFormat('MMM d, yyyy HH:mm')
                        .format(status.lastSequenceSave!),
              ),
              const SizedBox(height: 12),
              _StatusRow(
                label: 'Last Full Backup',
                value: status.lastBackup == null
                    ? 'Never'
                    : DateFormat('MMM d, yyyy HH:mm')
                        .format(status.lastBackup!),
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
          loading: () => const Center(child: CircularProgressIndicator()),
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
                  child: CircularProgressIndicator(),
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
    final timestamp = DateFormat('MMM d, yyyy HH:mm').format(backup.createdAt);

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
        '${_formatFileSize(backup.fileSize)} | $timestamp',
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

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
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
