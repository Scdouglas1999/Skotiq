import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../services/file_download_service.dart';
import '../../../utils/snackbar_helper.dart';
import '../../accessible_dropdown.dart';
import 'calibration_panel.dart';

String calibrationTypeLabel(CalibrationMasterType type) => switch (type) {
      CalibrationMasterType.dark => 'Dark',
      CalibrationMasterType.bias => 'Bias',
      CalibrationMasterType.flat => 'Flat',
      CalibrationMasterType.defectMap => 'Defect map',
    };

/// The calibration library: every registered master dark, bias, flat and
/// defect map, with tags, notes, sharing, deletion and library upkeep.
///
/// On a remote client the masters are the imaging computer's, read and
/// changed over its calibration-library API.
class CalibrationLibraryPanel extends ConsumerStatefulWidget {
  const CalibrationLibraryPanel({super.key});

  @override
  ConsumerState<CalibrationLibraryPanel> createState() =>
      CalibrationLibraryPanelState();
}

class CalibrationLibraryPanelState
    extends ConsumerState<CalibrationLibraryPanel> {
  static const _filters = <CalibrationMasterType?>[
    null,
    CalibrationMasterType.dark,
    CalibrationMasterType.bias,
    CalibrationMasterType.flat,
    CalibrationMasterType.defectMap,
  ];

  CalibrationMasterType? _typeFilter;
  bool _loading = true;
  Object? _error;
  List<CalibrationMasterRecord> _records = const [];
  int _loadGeneration = 0;
  int? _downloadingId;

  CalibrationLibraryService get _service =>
      ref.read(calibrationLibraryServiceProvider);

  @override
  void initState() {
    super.initState();
    ref.listenManual<SkotiqBackend>(backendProvider, (previous, next) {
      if (identical(previous, next) || !mounted) return;
      setState(() {
        _records = const [];
        _error = null;
        _loading = true;
      });
      unawaited(reload());
    });
    ref.listenManual<int>(calibrationLibraryRevisionProvider, (_, __) {
      if (mounted) unawaited(reload());
    });
    unawaited(reload());
  }

  Future<void> reload() async {
    final backend = ref.read(backendProvider);
    final generation = ++_loadGeneration;
    setState(() {
      _loading = _records.isEmpty;
      _error = null;
    });
    try {
      final List<CalibrationMasterRecord> records;
      if (backend is NetworkBackend) {
        final masters = await backend.getCalibrationMasters();
        records = [
          for (final m in masters) CalibrationMasterRecord.fromJson(m)
        ];
      } else {
        records = await _service.listMasters();
      }
      if (!_isCurrentLoad(backend, generation)) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (e) {
      if (!_isCurrentLoad(backend, generation)) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  bool _isCurrentLoad(SkotiqBackend backend, int generation) =>
      mounted &&
      generation == _loadGeneration &&
      identical(ref.read(backendProvider), backend);

  bool _isCurrentAuthority(SkotiqBackend authority) =>
      mounted && identical(ref.read(backendProvider), authority);

  void _bumpRevision() =>
      ref.read(calibrationLibraryRevisionProvider.notifier).state++;

  @override
  Widget build(BuildContext context) {
    final isRemote = ref.watch(backendProvider) is NetworkBackend;
    final shown = _typeFilter == null
        ? _records
        : _records.where((r) => r.type == _typeFilter).toList();
    final uiState = ref.watch(darkLibraryNotifierProvider);

    return CalibrationSection(
      title: 'Library',
      note: isRemote
          ? 'Masters on the imaging computer'
          : 'Masters the Darkroom, live calibration and the night-end '
              'build use',
      actions: [
        SkotiqIconButton(
          icon: LucideIcons.refreshCw,
          tooltip: 'Reload the library',
          size: IconButtonSize.sm,
          onPressed: _loading ? null : reload,
        ),
        _MaintenanceMenu(
          busy: uiState.isBusy,
          onCleanOrphans: () => _cleanOrphans(),
          onClear: () => _confirmClear(context),
        ),
      ],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: SkotiqTokens.spaceSm),
          Align(
            alignment: Alignment.centerLeft,
            child: SegmentedControl(
              dense: true,
              semanticLabel: 'Master type',
              segments: [
                for (final t in _filters)
                  '${t == null ? 'All' : _plural(t)} '
                      '${t == null ? _records.length : _records.where((r) => r.type == t).length}',
              ],
              selectedIndex: _filters.indexOf(_typeFilter),
              onSelected: (i) => setState(() => _typeFilter = _filters[i]),
            ),
          ),
          if (uiState.statusMessage != null || uiState.errorMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: SkotiqTokens.spaceSm),
              child: SkotiqBanner(
                tone: uiState.errorMessage != null
                    ? BannerTone.error
                    : BannerTone.info,
                title: uiState.errorMessage ?? uiState.statusMessage!,
                onDismiss: () {
                  final n = ref.read(darkLibraryNotifierProvider.notifier);
                  uiState.errorMessage != null
                      ? n.clearError()
                      : n.clearStatus();
                },
              ),
            ),
          const SizedBox(height: SkotiqTokens.spaceXs),
          ..._list(context, shown, isRemote),
        ],
      ),
    );
  }

  static String _plural(CalibrationMasterType t) => switch (t) {
        CalibrationMasterType.dark => 'Darks',
        CalibrationMasterType.bias => 'Bias',
        CalibrationMasterType.flat => 'Flats',
        CalibrationMasterType.defectMap => 'Defect maps',
      };

  List<Widget> _list(
    BuildContext context,
    List<CalibrationMasterRecord> shown,
    bool isRemote,
  ) {
    final colors = context.skotiqColors;
    if (_loading) {
      return const [
        Padding(
          padding: EdgeInsets.symmetric(vertical: SkotiqTokens.spaceXl),
          child: Center(child: SkotiqSpinner(size: 20)),
        ),
      ];
    }
    if (_error != null) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: SkotiqTokens.spaceMd),
          child: Row(
            children: [
              Icon(LucideIcons.alertTriangle, size: 14, color: colors.error),
              const SizedBox(width: SkotiqTokens.spaceSm),
              Expanded(
                child: Text(
                  'Could not load the calibration library: $_error',
                  style: SkotiqTypography.bodySm.copyWith(color: colors.error),
                ),
              ),
              SkotiqButton(
                label: 'Retry',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: reload,
              ),
            ],
          ),
        ),
      ];
    }
    if (shown.isEmpty) {
      return [
        CalibrationEmpty(
          _records.isEmpty
              ? 'No masters yet. Built darks, bias and flats appear here, '
                  'and the Darkroom finds them by their capture settings.'
              : 'No ${_plural(_typeFilter!).toLowerCase()} in the library.',
          icon: LucideIcons.library,
        ),
      ];
    }
    final out = <Widget>[];
    for (final type in CalibrationMasterType.values) {
      final ofType = shown.where((r) => r.type == type).toList();
      if (ofType.isEmpty) continue;
      out.add(CalibrationOverline('${_plural(type)} · ${ofType.length}'));
      for (var i = 0; i < ofType.length; i++) {
        final record = ofType[i];
        out.add(
          CalibrationMasterRow(
            record: record,
            last: i == ofType.length - 1,
            downloading: _downloadingId == record.id,
            onEditTags: () => _editTags(record),
            onDelete: () => _confirmDelete(record),
            onPublish: (record.isMaster &&
                    !record.isRemote &&
                    !record.isPublished &&
                    record.type != CalibrationMasterType.defectMap)
                ? () => _publish(record)
                : null,
            onRetract: (record.isPublished && !record.isRemote)
                ? () => _retract(record)
                : null,
            onDownload: isRemote &&
                    (record.type == CalibrationMasterType.dark ||
                        record.type == CalibrationMasterType.bias)
                ? () => _download(record)
                : null,
          ),
        );
      }
    }
    return out;
  }

  Future<void> _cleanOrphans() async {
    await ref.read(darkLibraryNotifierProvider.notifier).cleanOrphans();
    if (!mounted) return;
    _bumpRevision();
  }

  Future<void> _confirmClear(BuildContext context) async {
    final authority = ref.read(backendProvider);
    var deleteFiles = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Clear the dark and bias library?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Every dark and bias entry is removed from the library. '
                'Flats and defect maps are kept.',
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              CalibrationCheckLine(
                value: deleteFiles,
                label: 'Also delete the files from disk',
                onChanged: (v) => setDialogState(() => deleteFiles = v),
              ),
            ],
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            SkotiqButton(
              label: 'Clear',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    if (!_isCurrentAuthority(authority)) {
      _showMessage(
        'The imaging host changed; the library was not cleared.',
        isError: true,
      );
      return;
    }
    await ref
        .read(darkLibraryNotifierProvider.notifier)
        .clearLibrary(deleteFiles: deleteFiles);
    if (mounted) _bumpRevision();
  }

  Future<void> _editTags(CalibrationMasterRecord record) async {
    final authority = ref.read(backendProvider);
    final tags = TextEditingController(text: record.tags.join(', '));
    final notes = TextEditingController(text: record.notes ?? '');
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${calibrationTypeLabel(record.type)} #${record.id}'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SkotiqTextField(
                controller: tags,
                label: 'Tags, separated by commas',
              ),
              const SizedBox(height: SkotiqTokens.spaceMd),
              SkotiqTextField(controller: notes, label: 'Notes', maxLines: 3),
            ],
          ),
        ),
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          SkotiqButton(
            label: 'Save',
            size: ButtonSize.small,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    final tagsText = tags.text;
    final notesText = notes.text;
    tags.dispose();
    notes.dispose();
    if (saved != true) return;
    if (!_isCurrentAuthority(authority)) {
      _showMessage(
        'The imaging host changed; the tags were not saved.',
        isError: true,
      );
      return;
    }
    final tagList = [
      for (final t in tagsText.split(','))
        if (t.trim().isNotEmpty) t.trim(),
    ];
    try {
      if (authority is NetworkBackend) {
        final type = calibrationMasterTypeWireName(record.type);
        await authority.setCalibrationMasterTags(
          type: type,
          id: record.id,
          tags: tagList,
        );
        await authority.setCalibrationMasterNotes(
          type: type,
          id: record.id,
          notes: notesText.trim(),
        );
      } else {
        await _service.setTags(record.type, record.id, tagList);
        if (!_isCurrentAuthority(authority)) return;
        await _service.setNotes(record.type, record.id, notesText);
      }
      if (!_isCurrentAuthority(authority)) return;
      await reload();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not save the tags: $e', isError: true);
    }
  }

  Future<void> _confirmDelete(CalibrationMasterRecord record) async {
    final authority = ref.read(backendProvider);
    var deleteFile = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Delete this master?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${calibrationTypeLabel(record.type)} #${record.id} is '
                'removed from the library, so no build or capture uses it.',
              ),
              if (record.filePath != null) ...[
                const SizedBox(height: SkotiqTokens.spaceMd),
                CalibrationCheckLine(
                  value: deleteFile,
                  label: 'Also delete ${p.basename(record.filePath!)}',
                  onChanged: (v) => setDialogState(() => deleteFile = v),
                ),
              ],
            ],
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            SkotiqButton(
              label: 'Delete',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    if (!_isCurrentAuthority(authority)) {
      _showMessage(
        'The imaging host changed; nothing was deleted.',
        isError: true,
      );
      return;
    }
    try {
      if (authority is NetworkBackend) {
        await authority.deleteCalibrationMaster(
          type: calibrationMasterTypeWireName(record.type),
          id: record.id,
          deleteFile: deleteFile,
        );
      } else {
        await _service.deleteMaster(
          record.type,
          record.id,
          deleteFile: deleteFile,
        );
      }
      if (!_isCurrentAuthority(authority)) return;
      _bumpRevision();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not delete the master: $e', isError: true);
    }
  }

  Future<void> _publish(CalibrationMasterRecord record) async {
    final authority = ref.read(backendProvider);
    final consent = await _collectConsent(record);
    if (consent == null) return;
    if (!_isCurrentAuthority(authority)) {
      _showMessage(
        'The imaging host changed; the master was not shared.',
        isError: true,
      );
      return;
    }
    try {
      if (authority is NetworkBackend) {
        await authority.publishCalibrationMaster(
          type: calibrationMasterTypeWireName(record.type),
          id: record.id,
          license: consent.license.wireName,
          attributionName: consent.attributionName,
        );
      } else {
        await _service.publishMaster(record, consent: consent);
      }
      if (!_isCurrentAuthority(authority)) return;
      _showMessage(
        'Shared ${calibrationTypeLabel(record.type)} #${record.id} under '
        '${consent.license.wireName}.',
      );
      await reload();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not share the master: $e', isError: true);
    }
  }

  Future<void> _retract(CalibrationMasterRecord record) async {
    final authority = ref.read(backendProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Stop sharing this master?'),
        content: Text(
          'Hub members can no longer pull ${calibrationTypeLabel(record.type)} '
          '#${record.id}. Your copy stays in the library.',
        ),
        actions: [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
            onPressed: () => Navigator.of(ctx).pop(false),
          ),
          SkotiqButton(
            label: 'Stop sharing',
            size: ButtonSize.small,
            onPressed: () => Navigator.of(ctx).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!_isCurrentAuthority(authority)) return;
    try {
      if (authority is NetworkBackend) {
        await authority.retractCalibrationMaster(
          type: calibrationMasterTypeWireName(record.type),
          id: record.id,
        );
      } else {
        await _service.retractPublishedMaster(record);
      }
      if (!_isCurrentAuthority(authority)) return;
      _showMessage(
        'Stopped sharing ${calibrationTypeLabel(record.type)} #${record.id}.',
      );
      await reload();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not stop sharing: $e', isError: true);
    }
  }

  /// Download a shared master the match check surfaced into this library.
  Future<void> acceptRemote(CalibrationMasterRecord remote) async {
    final authority = ref.read(backendProvider);
    try {
      final String message;
      if (authority is NetworkBackend) {
        final outcome = await authority.acceptRemoteCalibrationMaster(remote);
        message = _acceptMessage(
          outcome['kind'] as String?,
          outcome['reason'] as String?,
        );
      } else {
        final outcome = await _service.acceptRemoteMaster(remote);
        message = _acceptMessage(outcome.kind.name, outcome.reason);
      }
      if (!_isCurrentAuthority(authority)) return;
      _showMessage(message);
      _bumpRevision();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not pull the shared master: $e', isError: true);
    }
  }

  static String _acceptMessage(String? kind, String? reason) => switch (kind) {
        'merged' => 'The shared master was added to your library.',
        'preferredLocal' =>
          'You already have an equivalent master; yours was kept.',
        'refused' => 'The shared master was refused: '
            '${reason ?? 'it failed the quality or license check'}.',
        _ => 'Finished (${kind ?? 'unknown outcome'}).',
      };

  Future<void> _download(CalibrationMasterRecord record) async {
    final backend = ref.read(backendProvider);
    if (backend is! NetworkBackend || _downloadingId != null) return;
    setState(() => _downloadingId = record.id);
    try {
      final name = (record.filePath ?? '').split(RegExp(r'[/\\]')).last;
      final outcome = await downloadFileToDevice(
        fileName: name.isEmpty ? 'dark-${record.id}.fits' : name,
        tempKey: 'dark-${record.id}',
        fetch: (localPath, onProgress) =>
            backend.downloadDark(record.id, localPath, onProgress: onProgress),
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
      if (mounted) setState(() => _downloadingId = null);
    }
  }

  Future<ContributionConsent?> _collectConsent(CalibrationMasterRecord record) {
    var license = ContributionLicense.ccBy;
    final attribution = TextEditingController();
    return showDialog<ContributionConsent>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            'Share ${calibrationTypeLabel(record.type)} #${record.id}',
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Choose a reuse license. Hub members with the same camera '
                  'and sensor can then pull this master.',
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                AccessibleDropdownFormField<ContributionLicense>(
                  initialValue: license,
                  decoration: const InputDecoration(
                    labelText: 'License',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    for (final l in ContributionLicense.values)
                      if (l.isShareable)
                        DropdownMenuItem(value: l, child: Text(l.wireName)),
                  ],
                  onChanged: (v) => setDialogState(
                    () => license = v ?? ContributionLicense.ccBy,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                SkotiqTextField(
                  controller: attribution,
                  label: 'Attribution name (optional)',
                ),
              ],
            ),
          ),
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(),
            ),
            SkotiqButton(
              label: 'Share',
              size: ButtonSize.small,
              onPressed: () => Navigator.of(ctx).pop(
                ContributionConsent(
                  license: license,
                  attributionName: attribution.text.trim().isEmpty
                      ? null
                      : attribution.text.trim(),
                  consentedAt: DateTime.now(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    if (isError) {
      context.showErrorSnackBar(message);
    } else {
      context.showInfoSnackBar(message);
    }
  }
}

/// One master: kind, capture settings, frames, age and actions; the file,
/// tags and notes below.
class CalibrationMasterRow extends StatelessWidget {
  const CalibrationMasterRow({
    super.key,
    required this.record,
    required this.onEditTags,
    required this.onDelete,
    this.onPublish,
    this.onRetract,
    this.onDownload,
    this.downloading = false,
    this.last = false,
  });

  final CalibrationMasterRecord record;
  final VoidCallback onEditTags;
  final VoidCallback onDelete;
  final VoidCallback? onPublish;
  final VoidCallback? onRetract;
  final VoidCallback? onDownload;
  final bool downloading;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final now = DateTime.now();
    final age = record.ageDays(now);
    final freshness = record.freshness(now);
    final ageColor = switch (freshness) {
      CalibrationFreshness.fresh => colors.textSecondary,
      CalibrationFreshness.aging => colors.warning,
      CalibrationFreshness.stale => colors.error,
    };
    final ageNote = switch (freshness) {
      CalibrationFreshness.fresh => 'Recent',
      CalibrationFreshness.aging => 'Getting old',
      CalibrationFreshness.stale => 'Old enough that a new one is due',
    };

    return CalibrationRow(
      last: last,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 84,
                child: Text(
                  record.type == CalibrationMasterType.flat &&
                          (record.filter?.isNotEmpty ?? false)
                      ? 'Flat ${record.filter}'
                      : calibrationTypeLabel(record.type),
                  style: SkotiqTypography.labelStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Text(
                  _settings(record),
                  style: SkotiqTypography.monoSm.copyWith(
                    color: colors.textSecondary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              if (record.frameCount != null)
                SizedBox(
                  width: 84,
                  child: Text(
                    record.type == CalibrationMasterType.defectMap
                        ? '${record.frameCount} pixels'
                        : '${record.frameCount} frames',
                    textAlign: TextAlign.right,
                    style: SkotiqTypography.bodySm.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              SkotiqTooltip(
                message: ageNote,
                child: SizedBox(
                  width: 44,
                  child: Text(
                    age == 0 ? 'today' : '$age d',
                    textAlign: TextAlign.right,
                    style: SkotiqTypography.monoSm.copyWith(color: ageColor),
                  ),
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceSm),
              if (onDownload != null)
                downloading
                    ? const Padding(
                        padding: EdgeInsets.all(SkotiqTokens.spaceSm),
                        child: SkotiqSpinner(size: 14),
                      )
                    : SkotiqIconButton(
                        icon: LucideIcons.download,
                        tooltip: 'Download to this device',
                        size: IconButtonSize.sm,
                        onPressed: onDownload,
                      ),
              if (onPublish != null)
                SkotiqIconButton(
                  icon: LucideIcons.share2,
                  tooltip: 'Share on your hub',
                  size: IconButtonSize.sm,
                  onPressed: onPublish,
                ),
              if (onRetract != null)
                SkotiqIconButton(
                  icon: LucideIcons.link2Off,
                  tooltip: 'Stop sharing',
                  size: IconButtonSize.sm,
                  onPressed: onRetract,
                ),
              SkotiqIconButton(
                icon: LucideIcons.tag,
                tooltip: 'Tags and notes',
                size: IconButtonSize.sm,
                onPressed: onEditTags,
              ),
              SkotiqIconButton(
                icon: LucideIcons.trash2,
                tooltip: 'Delete from the library',
                size: IconButtonSize.sm,
                color: colors.error,
                onPressed: onDelete,
              ),
            ],
          ),
          if (record.filePath != null ||
              record.tags.isNotEmpty ||
              (record.notes?.isNotEmpty ?? false))
            Padding(
              padding: const EdgeInsets.only(
                left: 84 + SkotiqTokens.spaceMd,
                top: 2,
              ),
              child: Wrap(
                spacing: SkotiqTokens.spaceSm,
                runSpacing: SkotiqTokens.spaceXs,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (record.filePath != null)
                    Text(
                      p.basename(record.filePath!.replaceAll('\\', '/')),
                      style: SkotiqTypography.monoXs.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  if (record.isPublished)
                    const SkotiqChip(label: 'Shared', tone: ChipTone.primary),
                  for (final tag in record.tags) SkotiqChip(label: tag),
                  if (record.notes?.isNotEmpty ?? false)
                    Text(
                      record.notes!,
                      style: SkotiqTypography.caption.copyWith(
                        color: colors.textSecondary,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _settings(CalibrationMasterRecord r) {
    String secs(double v) => v == v.roundToDouble()
        ? '${v.round()} s'
        : '${v < 0.01 ? v.toStringAsFixed(3) : v.toStringAsFixed(2)} s';
    return [
      if (r.exposureSeconds != null && r.type == CalibrationMasterType.dark)
        secs(r.exposureSeconds!),
      if (r.gain != null) 'gain ${r.gain}',
      if (r.offset != null) 'offset ${r.offset}',
      'bin ${r.binX}x${r.binY}',
      if (r.temperature != null) '${r.temperature!.toStringAsFixed(1)} °C',
      if (r.cameraId?.isNotEmpty ?? false) r.cameraId!,
    ].join(' · ');
  }
}

class _MaintenanceMenu extends StatelessWidget {
  const _MaintenanceMenu({
    required this.busy,
    required this.onCleanOrphans,
    required this.onClear,
  });

  final bool busy;
  final VoidCallback onCleanOrphans;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      tooltip: 'Library upkeep',
      enabled: !busy,
      icon: const Icon(LucideIcons.moreHorizontal, size: 16),
      onSelected: (v) => v == 0 ? onCleanOrphans() : onClear(),
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: 0,
          child: Text('Remove entries whose files are gone'),
        ),
        PopupMenuItem(value: 1, child: Text('Clear the dark and bias library')),
      ],
    );
  }
}
