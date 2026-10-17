import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../accessible_dropdown.dart';
import 'settings_widgets.dart';

part 'calibration_library_settings_parts/_tiles_and_preview.dart';

/// Calibration Library Manager — the unified browse / tag / auto-match
/// surface over the master calibration artifacts the imaging pipeline
/// records (darks, biases, master flats, defect maps), joined with the v46
/// user-tag / notes layer.
///
/// Three panes:
///  * filter bar (type / camera / filter) over a list of master tiles;
///  * each tile shows type badge, key capture params, age/freshness, tags,
///    and edit / delete actions;
///  * a collapsible matching-preview that takes a light-frame context and
///    shows which master auto-selects per type and exactly why.
class CalibrationLibrarySettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const CalibrationLibrarySettings({super.key, this.isMobile = false});

  @override
  ConsumerState<CalibrationLibrarySettings> createState() =>
      _CalibrationLibrarySettingsState();
}

class _CalibrationLibrarySettingsState
    extends ConsumerState<CalibrationLibrarySettings> {
  CalibrationMasterType? _typeFilter;
  bool _loading = true;
  Object? _error;
  List<CalibrationMasterRecord> _records = const [];
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (identical(previous, next) || !mounted) return;
        _loadGeneration++;
        setState(() {
          _records = const [];
          _error = null;
          _loading = true;
        });
        unawaited(_reload());
      },
    );
    unawaited(_reload());
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  CalibrationLibraryService get _service =>
      ref.read(calibrationLibraryServiceProvider);

  int get _masterCount => _records.length;

  Future<void> _reload() async {
    final backend = ref.read(backendProvider);
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (backend is NetworkBackend) {
        // Remote: read the APPLIANCE's master library over REST so a tablet
        // sees the rig's actual darks/flats/biases, not this device's library.
        // The maps are the host's `CalibrationMasterRecord.toJson`, so we
        // rebuild typed records and drive the same edit/delete actions — the
        // service routes those mutations back to the appliance.
        final masters = await backend.getCalibrationMasters(
          type: _typeFilter == null
              ? null
              : calibrationMasterTypeWireName(_typeFilter!),
        );
        if (!_isCurrentLoad(backend, generation)) return;
        setState(() {
          _records = [
            for (final m in masters) CalibrationMasterRecord.fromJson(m),
          ];
          _loading = false;
        });
      } else {
        final records = await _service.listMasters(
          filter: CalibrationLibraryFilter(type: _typeFilter),
        );
        if (!_isCurrentLoad(backend, generation)) return;
        setState(() {
          _records = records;
          _loading = false;
        });
      }
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

  void _showAuthorityChanged(String action) {
    _showMessage(
      'The imaging host changed while $action. The action was cancelled.',
      isError: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Both local and remote share the same panes: locally the records come
    // from this device's Drift DB; remotely they are the APPLIANCE's masters
    // read over `/api/calibration-library`, and the edit / delete / match
    // actions route back to the appliance through CalibrationLibraryService.
    final backend = ref.watch(backendProvider);
    final isRemote = backend is NetworkBackend;

    return SettingsPage(
      title: 'Calibration library',
      description: 'Browse, tag, and auto-match master darks, flats, '
          'biases, and defect maps',
      isMobile: widget.isMobile,
      hideHeader: widget.isMobile,
      children: [
        SettingsSection(
          title: isRemote ? 'Appliance Masters' : 'Masters',
          isMobile: widget.isMobile,
          children: [
            _buildFilterBar(context),
            const SizedBox(height: 12),
            _buildList(context),
          ],
        ),
        SettingsSection(
          title: 'Matching preview',
          isMobile: widget.isMobile,
          children: [
            _MatchingPreview(
              key: ValueKey(backend),
              service: _service,
              onAccept: _accept,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFilterBar(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: AccessibleDropdownFormField<CalibrationMasterType?>(
            initialValue: _typeFilter,
            decoration: const InputDecoration(
              labelText: 'Type',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            items: [
              const DropdownMenuItem(value: null, child: Text('All types')),
              for (final type in CalibrationMasterType.values)
                DropdownMenuItem(value: type, child: Text(_typeLabel(type))),
            ],
            onChanged: (value) {
              setState(() => _typeFilter = value);
              _reload();
            },
          ),
        ),
        const SizedBox(width: 12),
        Text('$_masterCount master${_masterCount == 1 ? '' : 's'}',
            style: theme.textTheme.bodySmall),
        SkotiqIconButton(
          icon: LucideIcons.refreshCw,
          tooltip: 'Refresh',
          onPressed: _loading ? null : _reload,
          size: IconButtonSize.md,
        ),
      ],
    );
  }

  Widget _buildList(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text('Failed to load calibration library: $_error',
            style: SkotiqTypography.body.copyWith(
              color: Theme.of(context).colorScheme.error,
            )),
      );
    }
    if (_records.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(
          child: Text('No calibration masters yet. Stacked darks, flats, '
              'and defect maps appear here automatically.'),
        ),
      );
    }
    return Column(
      children: [
        for (final record in _records)
          _MasterTile(
            record: record,
            onEditTags: () => _editTags(record),
            onDelete: () => _confirmDelete(record),
            // Sharing applies only to a stacked master of a shareable type that
            // lives locally (a remote candidate is pulled, not re-shared here).
            onPublish: (record.isMaster &&
                    !record.isRemote &&
                    !record.isPublished &&
                    record.type != CalibrationMasterType.defectMap)
                ? () => _publish(record)
                : null,
            // Un-share (retract) is offered for a master the user has published
            // to the hub (carries a retract handle) and lives locally.
            onRetract: (record.isPublished && !record.isRemote)
                ? () => _retract(record)
                : null,
          ),
      ],
    );
  }

  Future<void> _editTags(CalibrationMasterRecord record) async {
    final authority = ref.read(backendProvider);
    var tagsText = record.tags.join(', ');
    var notesText = record.notes ?? '';

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Tags — ${_typeLabel(record.type)} #${record.id}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              initialValue: tagsText,
              onChanged: (value) => tagsText = value,
              decoration: const InputDecoration(
                labelText: 'Tags (comma-separated)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: notesText,
              onChanged: (value) => notesText = value,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Notes',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Save')),
        ],
      ),
    );

    if (saved != true) return;
    if (!_isCurrentAuthority(authority)) {
      _showAuthorityChanged('editing the master');
      return;
    }

    final tags = tagsText
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    try {
      if (authority is NetworkBackend) {
        final type = calibrationMasterTypeWireName(record.type);
        await authority.setCalibrationMasterTags(
          type: type,
          id: record.id,
          tags: tags,
        );
        await authority.setCalibrationMasterNotes(
          type: type,
          id: record.id,
          notes: notesText.trim(),
        );
      } else {
        await _service.setTags(record.type, record.id, tags);
        if (!_isCurrentAuthority(authority)) return;
        await _service.setNotes(record.type, record.id, notesText);
      }
      if (!_isCurrentAuthority(authority)) return;
      await _reload();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not save tags: $e', isError: true);
    }
  }

  Future<void> _confirmDelete(CalibrationMasterRecord record) async {
    final authority = ref.read(backendProvider);
    var deleteFile = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Delete calibration master?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${_typeLabel(record.type)} #${record.id} will be removed '
                  'from the library.'),
              if (record.filePath != null) ...[
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: deleteFile,
                  title: const Text('Also delete the file from disk'),
                  subtitle: Text(record.filePath!,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  onChanged: (v) =>
                      setDialogState(() => deleteFile = v ?? false),
                ),
              ],
            ],
          ),
          actions: [
            SkotiqButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
            SkotiqButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              label: 'Delete',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
            ),
          ],
        ),
      ),
    );

    if (confirmed != true) return;
    if (!_isCurrentAuthority(authority)) {
      _showAuthorityChanged('deleting the master');
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
      await _reload();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not delete master: $e', isError: true);
    }
  }

  /// Publish a local master to the configured hub after collecting
  /// the consent/license. On a remote client the action routes to the appliance
  /// over REST; locally it goes straight through [CalibrationLibraryService].
  Future<void> _publish(CalibrationMasterRecord record) async {
    final authority = ref.read(backendProvider);
    final consent = await _collectConsent(record);
    if (consent == null) return;
    if (!_isCurrentAuthority(authority)) {
      _showAuthorityChanged('sharing the master');
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
      _showMessage('Shared ${_typeLabel(record.type)} #${record.id} '
          'under ${consent.license.wireName}.');
      // Reload so the now-published master surfaces its un-share affordance.
      await _reload();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not share master: $e', isError: true);
    }
  }

  /// Retract (un-share) a master the user previously published to the hub. On a
  /// remote client the action routes to the appliance over REST; locally it goes
  /// straight through [CalibrationLibraryService].
  Future<void> _retract(CalibrationMasterRecord record) async {
    final authority = ref.read(backendProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Un-share calibration master?'),
        content: Text(
          'Stop sharing ${_typeLabel(record.type)} #${record.id} on your hub. '
          'Members can no longer pull it; your local copy is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Un-share'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!_isCurrentAuthority(authority)) {
      _showAuthorityChanged('un-sharing the master');
      return;
    }
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
      _showMessage('Un-shared ${_typeLabel(record.type)} #${record.id}.');
      await _reload();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not un-share master: $e', isError: true);
    }
  }

  /// Download + merge a REMOTE shared master surfaced by the matching preview.
  Future<void> _accept(CalibrationMasterRecord remote) async {
    final authority = ref.read(backendProvider);
    try {
      final String message;
      if (authority is NetworkBackend) {
        final outcome = await authority.acceptRemoteCalibrationMaster(remote);
        message = _acceptOutcomeMessage(
          outcome['kind'] as String?,
          outcome['reason'] as String?,
        );
      } else {
        final outcome = await _service.acceptRemoteMaster(remote);
        message = _acceptOutcomeMessage(outcome.kind.name, outcome.reason);
      }
      if (!_isCurrentAuthority(authority)) return;
      _showMessage(message);
      await _reload();
    } catch (e) {
      if (!_isCurrentAuthority(authority)) return;
      _showMessage('Could not pull shared master: $e', isError: true);
    }
  }

  String _acceptOutcomeMessage(String? kind, String? reason) {
    switch (kind) {
      case 'merged':
        return 'Shared master downloaded into your library.';
      case 'preferredLocal':
        return 'You already have an equivalent local master — kept yours.';
      case 'refused':
        return 'Master refused: ${reason ?? 'failed the quality/consent gate'}.';
      default:
        return 'Accept finished (${kind ?? 'unknown'}).';
    }
  }

  /// Prompt for the reuse license + attribution name before sharing. Returns null
  /// when the user cancels.
  Future<ContributionConsent?> _collectConsent(
    CalibrationMasterRecord record,
  ) async {
    var license = ContributionLicense.ccBy;
    var attribution = '';
    return showDialog<ContributionConsent>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Share ${_typeLabel(record.type)} #${record.id}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Choose a reuse license. Anyone on your hub with a '
                  'matching sensor can then pull this master.'),
              const SizedBox(height: 12),
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
                    () => license = v ?? ContributionLicense.ccBy),
              ),
              const SizedBox(height: 12),
              TextFormField(
                onChanged: (value) => attribution = value,
                decoration: const InputDecoration(
                  labelText: 'Attribution name (optional)',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(
                ContributionConsent(
                  license: license,
                  attributionName:
                      attribution.trim().isEmpty ? null : attribution.trim(),
                  consentedAt: DateTime.now(),
                ),
              ),
              child: const Text('Share'),
            ),
          ],
        ),
      ),
    );
  }

  void _showMessage(String message, {bool isError = false}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }
}
