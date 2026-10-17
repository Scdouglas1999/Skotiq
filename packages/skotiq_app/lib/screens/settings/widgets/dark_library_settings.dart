import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/file_download_service.dart';
import '../../../utils/snackbar_helper.dart';
import '../../../widgets/help/field_help_copy.dart';
import 'settings_widgets.dart';

part 'dark_library_settings_parts/_tiles.dart';

class DarkLibrarySettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const DarkLibrarySettings({
    super.key,
    this.isMobile = false,
  });

  @override
  ConsumerState<DarkLibrarySettings> createState() =>
      _DarkLibrarySettingsState();
}

class _DarkLibrarySettingsState extends ConsumerState<DarkLibrarySettings> {
  /// Entry id currently streaming to this device, or null. One transfer at
  /// a time keeps the UI honest about progress on a phone-grade link.
  int? _downloadingEntryId;

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(darkLibraryEntriesProvider);
    final isRemote = ref.watch(backendProvider) is NetworkBackend;
    final statsAsync = ref.watch(darkLibraryStatsProvider);
    final groupsAsync = ref.watch(darkLibraryGroupsProvider);
    final librarySettingsAsync = ref.watch(darkLibrarySettingsProvider);
    final librarySettings = librarySettingsAsync.valueOrNull;
    final uiState = ref.watch(darkLibraryNotifierProvider);

    return SettingsPage(
      title: 'Dark library',
      description: 'Manage dark and bias calibration frames',
      isMobile: widget.isMobile,
      hideHeader: widget.isMobile,
      children: [
        // Settings section
        SettingsSection(
          title: 'Auto-Calibration',
          isMobile: widget.isMobile,
          children: [
            if (librarySettings == null)
              SettingRow(
                icon: librarySettingsAsync.hasError
                    ? LucideIcons.alertTriangle
                    : LucideIcons.loader,
                title: librarySettingsAsync.hasError
                    ? 'Could not load dark-library settings'
                    : 'Loading dark-library settings',
                subtitle: librarySettingsAsync.hasError
                    ? '${librarySettingsAsync.error}'
                    : 'Reading settings from the imaging host',
                trailing: librarySettingsAsync.hasError
                    ? SkotiqIconButton(
                        icon: LucideIcons.refreshCw,
                        tooltip: 'Retry',
                        onPressed: () =>
                            ref.invalidate(darkLibrarySettingsProvider),
                        size: IconButtonSize.sm,
                      )
                    : SizedBox(
                        width: 18,
                        height: 18,
                        child: SkotiqSpinner(
                            size: 18, color: SkotiqColors.of(context).primary),
                      ),
                isMobile: widget.isMobile,
              ),
            if (librarySettings != null)
              // This is the shared dark, flat, and bias calibration switch.
              SettingRow(
                icon: LucideIcons.zap,
                title: 'Auto-calibrate light frames',
                subtitle:
                    'Apply dark, flat, and bias correction to captured images '
                    'automatically. Same setting as Settings > Calibration.',
                trailing: SettingsSwitch(
                  value: librarySettings.autoCalibrate,
                  onChanged: (value) {
                    return ref
                        .read(darkLibrarySettingsActionsProvider)
                        .setAutoCalibrate(value);
                  },
                ),
                isMobile: widget.isMobile,
              ),
            if (librarySettings != null)
              SettingRow(
                icon: LucideIcons.thermometer,
                title: 'Temperature tolerance',
                helpId: FieldHelpId.darkLibraryMatching,
                subtitle: 'Maximum temperature difference for dark matching',
                trailing: SizedBox(
                  width: 120,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 60,
                        child: SettingsDropdown(
                          value: librarySettings.temperatureTolerance
                              .toStringAsFixed(1),
                          items: const [
                            '0.5',
                            '1.0',
                            '1.5',
                            '2.0',
                            '3.0',
                            '5.0'
                          ],
                          onChanged: (value) {
                            return ref
                                .read(darkLibrarySettingsActionsProvider)
                                .setTemperatureTolerance(double.parse(value));
                          },
                          isMobile: widget.isMobile,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '\u00b0C',
                        style: SkotiqTypography.bodySm.copyWith(
                          color: SkotiqColors.of(context).textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                isMobile: widget.isMobile,
              ),
          ],
        ),

        const SizedBox(height: 16),

        // Library statistics
        SettingsSection(
          title: 'Library statistics',
          isMobile: widget.isMobile,
          children: [
            statsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                    child:
                        SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not load dark library stats.',
                    style: SkotiqTypography.body.copyWith(
                      color: SkotiqColors.of(context).error,
                    )),
              ),
              // Counts are measurements, so they are Readouts (05 §3): the
              // uppercase label comes from the Readout itself, which is why
              // these read "DARK FRAMES" without being written that way.
              data: (stats) => Padding(
                padding: SkotiqTokens.paddingLg,
                child: ReadoutRow(
                  children: [
                    Readout(
                      label: 'Dark frames',
                      value: '${stats.darkCount}',
                    ),
                    Readout(
                      label: 'Bias frames',
                      value: '${stats.biasCount}',
                    ),
                    Readout(
                      label: 'Master darks',
                      value: '${stats.masterCount}',
                    ),
                    Readout(
                      label: 'Total',
                      value: '${stats.totalEntries}',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // Status/Error messages
        if (uiState.statusMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: SkotiqDecorations.emphasisSurface(
                SkotiqColors.of(context).primary,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.info,
                      size: 16, color: SkotiqColors.of(context).primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      uiState.statusMessage!,
                      style: SkotiqTypography.bodySm.copyWith(
                        color: SkotiqColors.of(context).textPrimary,
                      ),
                    ),
                  ),
                  SkotiqIconButton(
                    icon: LucideIcons.x,
                    tooltip: 'Dismiss this message',
                    onPressed: () => ref
                        .read(darkLibraryNotifierProvider.notifier)
                        .clearStatus(),
                    size: IconButtonSize.sm,
                    color: SkotiqColors.of(context).textMuted,
                  ),
                ],
              ),
            ),
          ),
        if (uiState.errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: SkotiqDecorations.emphasisSurface(
                SkotiqColors.of(context).error,
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.alertTriangle,
                      size: 16, color: SkotiqColors.of(context).error),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      uiState.errorMessage!,
                      style: SkotiqTypography.bodySm.copyWith(
                        color: SkotiqColors.of(context).textPrimary,
                      ),
                    ),
                  ),
                  SkotiqIconButton(
                    icon: LucideIcons.x,
                    tooltip: 'Dismiss this error',
                    onPressed: () => ref
                        .read(darkLibraryNotifierProvider.notifier)
                        .clearError(),
                    size: IconButtonSize.sm,
                    color: SkotiqColors.of(context).textMuted,
                  ),
                ],
              ),
            ),
          ),

        // Library actions
        SettingsSection(
          title: 'Library management',
          isMobile: widget.isMobile,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _ActionButton(
                    icon: LucideIcons.scan,
                    label: 'Clean orphans',
                    tooltip:
                        'Remove entries whose files no longer exist on disk',
                    onPressed: uiState.isBusy
                        ? null
                        : () => ref
                            .read(darkLibraryNotifierProvider.notifier)
                            .cleanOrphans(),
                    isLoading: uiState.activeMutation ==
                        DarkLibraryMutation.cleanOrphans,
                  ),
                  _ActionButton(
                    icon: LucideIcons.trash2,
                    label: 'Clear library',
                    tooltip: 'Remove all entries from the library',
                    onPressed:
                        uiState.isBusy ? null : () => _showClearDialog(context),
                    isDanger: true,
                    isLoading: uiState.activeMutation ==
                        DarkLibraryMutation.clearLibrary,
                  ),
                ],
              ),
            ),
          ],
        ),

        const SizedBox(height: 16),

        // Frame groups
        SettingsSection(
          title: 'Frame groups',
          isMobile: widget.isMobile,
          children: [
            groupsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                    child:
                        SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not load dark frame groups.',
                    style: SkotiqTypography.body.copyWith(
                      color: SkotiqColors.of(context).error,
                    )),
              ),
              data: (groups) {
                if (groups.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.moon,
                              size: 48,
                              color: SkotiqColors.of(context)
                                  .textMuted
                                  .withValues(alpha: 0.5)),
                          const SizedBox(height: 12),
                          Text(
                            'No dark frames in library',
                            style: SkotiqTypography.body.copyWith(
                              color: SkotiqColors.of(context).textMuted,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Capture dark or bias frames to populate the library',
                            style: SkotiqTypography.caption.copyWith(
                              color: SkotiqColors.of(context)
                                  .textMuted
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }

                return Column(
                  children: [
                    for (final group in groups)
                      _DarkGroupTile(
                        group: group,
                        onCreateMaster: uiState.isBusy
                            ? null
                            : () => _showCreateMasterDialog(context, group),
                        onDeleteGroup: uiState.isBusy
                            ? null
                            : () => _showDeleteGroupDialog(context, group),
                      ),
                  ],
                );
              },
            ),
          ],
        ),

        const SizedBox(height: 16),

        // All entries list
        SettingsSection(
          title: 'All entries',
          isMobile: widget.isMobile,
          children: [
            entriesAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(
                    child:
                        SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36)),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Could not load dark library entries.',
                    style: SkotiqTypography.body.copyWith(
                      color: SkotiqColors.of(context).error,
                    )),
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No entries',
                      style: SkotiqTypography.body.copyWith(
                        color: SkotiqColors.of(context).textMuted,
                      ),
                    ),
                  );
                }

                return Column(
                  children: [
                    for (final entry in entries)
                      _DarkEntryTile(
                        entry: entry,
                        // Downloading only makes sense against a remote
                        // appliance — locally the file already lives on
                        // this machine (path shown in the delete dialog).
                        downloadable: isRemote,
                        isDownloading: _downloadingEntryId == entry.id,
                        onDownload: _downloadingEntryId != null
                            ? null
                            : () => _downloadEntry(entry),
                        onDelete: uiState.isBusy
                            ? null
                            : () => _showDeleteEntryDialog(context, entry),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  void _showClearDialog(BuildContext context) {
    final authority = ref.read(backendProvider);
    bool deleteFiles = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Clear dark library'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Remove all entries from the dark library?'),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: deleteFiles,
                onChanged: (v) =>
                    setDialogState(() => deleteFiles = v ?? false),
                title: const Text('Also delete files from disk'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (!_isCurrentAuthority(authority)) {
                  _cancelForAuthorityChange(ctx);
                  return;
                }
                Navigator.pop(ctx);
                unawaited(
                  ref
                      .read(darkLibraryNotifierProvider.notifier)
                      .clearLibrary(deleteFiles: deleteFiles),
                );
              },
              child: Text('Clear',
                  style: SkotiqTypography.body.copyWith(
                    color: SkotiqColors.of(context).error,
                  )),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCreateMasterDialog(
    BuildContext context,
    DarkGroupKey group,
  ) async {
    final authority = ref.read(backendProvider);
    final controller = TextEditingController();
    String? pathError;
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setDialogState) => AlertDialog(
            title: const Text('Create Master Dark'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Median-combine all ${group.frameType} frames with:\n'
                  '${group.exposureTime}s / gain ${group.gain} / offset '
                  '${group.offset} / ${group.binX}x${group.binY}',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  onChanged: (_) {
                    if (pathError != null) {
                      setDialogState(() => pathError = null);
                    }
                  },
                  decoration: InputDecoration(
                    labelText: 'Output file path',
                    hintText: '/path/to/master_dark.fits',
                    errorText: pathError,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  final path = controller.text.trim();
                  if (path.isEmpty) {
                    setDialogState(
                      () => pathError = 'Enter an output file path',
                    );
                    return;
                  }
                  if (!_isCurrentAuthority(authority)) {
                    _cancelForAuthorityChange(ctx);
                    return;
                  }
                  Navigator.pop(ctx);
                  unawaited(
                    ref
                        .read(darkLibraryNotifierProvider.notifier)
                        .createMasterDark(
                          exposureTime: group.exposureTime,
                          gain: group.gain,
                          offset: group.offset,
                          binX: group.binX,
                          binY: group.binY,
                          outputPath: path,
                          frameType: group.frameType,
                        ),
                  );
                },
                child: const Text('Create'),
              ),
            ],
          ),
        ),
      );
    } finally {
      controller.dispose();
    }
  }

  void _showDeleteGroupDialog(BuildContext context, DarkGroupKey group) {
    final authority = ref.read(backendProvider);
    bool deleteFiles = false;
    bool isDeleting = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Delete Group'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Delete all ${group.frameType} frames with:\n'
                '${group.exposureTime}s / gain ${group.gain} / offset '
                '${group.offset} / ${group.binX}x${group.binY}?',
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: deleteFiles,
                onChanged: isDeleting
                    ? null
                    : (v) => setDialogState(() => deleteFiles = v ?? false),
                title: const Text('Also delete files from disk'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: isDeleting ? null : () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: isDeleting
                  ? null
                  : () async {
                      if (!_isCurrentAuthority(authority)) {
                        _cancelForAuthorityChange(ctx);
                        return;
                      }
                      setDialogState(() => isDeleting = true);
                      try {
                        final removed = await ref
                            .read(darkLibraryNotifierProvider.notifier)
                            .deleteGroup(
                              group,
                              deleteFiles: deleteFiles,
                            );
                        if (!ctx.mounted) return;
                        if (!_isCurrentAuthority(authority)) {
                          Navigator.pop(ctx);
                          return;
                        }
                        Navigator.pop(ctx);
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text(
                              'Deleted $removed ${group.frameType} '
                              '${removed == 1 ? 'entry' : 'entries'}.',
                            ),
                          ),
                        );
                      } catch (error) {
                        if (!ctx.mounted) return;
                        setDialogState(() => isDeleting = false);
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text('Failed to delete group: $error'),
                          ),
                        );
                      }
                    },
              child: isDeleting
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: SkotiqSpinner(
                          size: 16, color: SkotiqColors.of(context).primary),
                    )
                  : Text(
                      'Delete',
                      style: SkotiqTypography.body.copyWith(
                        color: SkotiqColors.of(context).error,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeleteEntryDialog(BuildContext context, DarkLibraryEntry entry) {
    final authority = ref.read(backendProvider);
    bool deleteFile = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Delete Entry'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Delete this ${entry.frameType} frame?'),
              const SizedBox(height: 4),
              Text(
                entry.filePath,
                style: SkotiqTypography.captionSm.copyWith(
                  color: SkotiqColors.of(context).textMuted,
                ),
              ),
              const SizedBox(height: 12),
              CheckboxListTile(
                value: deleteFile,
                onChanged: (v) => setDialogState(() => deleteFile = v ?? false),
                title: const Text('Also delete file from disk'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                if (!_isCurrentAuthority(authority)) {
                  _cancelForAuthorityChange(ctx);
                  return;
                }
                Navigator.pop(ctx);
                unawaited(
                  ref
                      .read(darkLibraryNotifierProvider.notifier)
                      .deleteEntry(entry.id, deleteFile: deleteFile),
                );
              },
              child: Text('Delete',
                  style: SkotiqTypography.body.copyWith(
                    color: SkotiqColors.of(context).error,
                  )),
            ),
          ],
        ),
      ),
    );
  }

  /// Stream the on-disk file for [entry] off the appliance to this device
  /// (share sheet on mobile, save picker on desktop) via
  /// `GET /api/calibration/darks/{id}/download`.
  Future<void> _downloadEntry(DarkLibraryEntry entry) async {
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend || _downloadingEntryId != null) return;
    setState(() => _downloadingEntryId = entry.id);
    try {
      final fileName = entry.filePath.split('/').last.split('\\').last;
      final outcome = await downloadFileToDevice(
        fileName: fileName.isEmpty ? 'dark-${entry.id}.fits' : fileName,
        tempKey: 'dark-${entry.id}',
        fetch: (localPath, onProgress) =>
            backend.downloadDark(entry.id, localPath, onProgress: onProgress),
      );
      if (!mounted || !_isCurrentAuthority(backend)) return;
      switch (outcome.status) {
        case FileDownloadStatus.saved:
          context.showSuccessSnackBar('Saved to ${outcome.savedPath}');
        case FileDownloadStatus.shared:
          context.showSuccessSnackBar('Calibration frame ready to share');
        case FileDownloadStatus.cancelled:
          break;
        case FileDownloadStatus.failed:
          context.showErrorSnackBar(outcome.error ?? 'Download failed');
      }
    } finally {
      if (mounted) setState(() => _downloadingEntryId = null);
    }
  }

  bool _isCurrentAuthority(SkotiqBackend authority) =>
      identical(ref.read(backendProvider), authority);

  void _cancelForAuthorityChange(BuildContext dialogContext) {
    if (dialogContext.mounted) Navigator.pop(dialogContext);
    if (mounted) {
      context.showErrorSnackBar(
        'Connected rig changed; dark-library action cancelled',
      );
    }
  }
}
