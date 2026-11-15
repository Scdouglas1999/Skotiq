part of '../sequence_library_tab.dart';

/// Version-history list + restore for a saved sequence.
///
/// Reads the stored snapshots from
/// [SequenceRepository.listVersions] (newest first, capped per sequence by the
/// DAO) and lets the operator restore any earlier shape. Restoring rebuilds an
/// editable [Sequence] re-anchored to the same library row and loads it into
/// the editor, so the user reviews it and saves to persist the restore in
/// place.
class _VersionHistoryDialog extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final int sequenceId;
  final String sequenceName;

  const _VersionHistoryDialog({
    required this.colors,
    required this.sequenceId,
    required this.sequenceName,
  });

  @override
  ConsumerState<_VersionHistoryDialog> createState() =>
      _VersionHistoryDialogState();
}

class _VersionHistoryDialogState extends ConsumerState<_VersionHistoryDialog>
    with HostBoundDialogState<_VersionHistoryDialog> {
  @override
  String get hostChangedMessage =>
      'The connected host changed. Version history closed.';

  @override
  bool get hostChangeDiscardsInput => true;

  late Future<List<SequenceVersionSummary>> _versionsFuture;
  late final SequenceRepository _repository;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(sequenceRepositoryProvider);
    _versionsFuture = _load();
  }

  Future<List<SequenceVersionSummary>> _load() {
    return _repository.listVersions(widget.sequenceId);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return SkotiqDialog(
      title: 'Version history',
      width: SkotiqDialog.widthForm,
      actions: [
        SkotiqButton(
          label: 'Close',
          variant: ButtonVariant.ghost,
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.sequenceName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style:
                SkotiqTypography.bodyStrong.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _buildBody(colors),
        ],
      ),
    );
  }

  Widget _buildBody(SkotiqColors colors) {
    return FutureBuilder<List<SequenceVersionSummary>>(
      future: _versionsFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return const Padding(
            padding: EdgeInsets.all(SkotiqTokens.spaceXl),
            child: Center(
              child: SkotiqMark(motion: SkotiqMarkMotion.loading, size: 36),
            ),
          );
        }
        if (snapshot.hasError) {
          return EmptyState.error(
            title: 'Could not load the version history',
            body: userFacingError(snapshot.error!),
            onRetry: () => setState(() => _versionsFuture = _load()),
          );
        }
        final versions = snapshot.data ?? const <SequenceVersionSummary>[];
        if (versions.isEmpty) {
          return const EmptyState(
            icon: LucideIcons.history,
            title: 'No saved versions yet',
            body: 'A version is kept each time this sequence is saved.',
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Restoring loads a version into the editor; save to keep it.',
              style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            for (var index = 0; index < versions.length; index++)
              _VersionRow(
                colors: colors,
                version: versions[index],
                isLatest: index == 0,
                isLast: index == versions.length - 1,
                onRestore: () => _restore(versions[index]),
              ),
          ],
        );
      },
    );
  }

  Future<void> _restore(SequenceVersionSummary version) async {
    if (host.isStale) return;
    final editor = ref.read(currentSequenceProvider.notifier);
    Sequence? restored;
    try {
      restored = await _repository.restoreVersion(version.id);
    } catch (e) {
      if (mounted && host.isCurrent) {
        context.showErrorSnackBar(
            'Failed to restore version: ${userFacingError(e)}');
      }
      return;
    }
    if (!mounted || host.isStale) return;
    if (restored == null) {
      context.showErrorSnackBar('That version is no longer available');
      return;
    }

    try {
      editor.loadSequence(restored);
    } on UnsavedChangesException catch (e) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => SkotiqDialog(
          title: 'Discard unsaved changes?',
          width: SkotiqDialog.widthConfirm,
          actions: [
            SkotiqButton(
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              onPressed: () => Navigator.of(ctx).pop(false),
            ),
            SkotiqButton(
              label: 'Discard and restore',
              variant: ButtonVariant.destructive,
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
          child: Text(
            '"${e.currentSequenceName}" has unsaved changes. '
            'Restoring this version will discard them.',
            style: SkotiqTypography.body.copyWith(
              color: widget.colors.textSecondary,
            ),
          ),
        ),
      );
      if (discard != true || host.isStale) {
        return;
      }
      editor.loadSequence(restored, discardUnsaved: true);
    }

    if (!mounted || host.isStale) return;
    Navigator.of(context).pop();
    ref.read(sequencerTabProvider.notifier).state = 0;
    context.showSuccessSnackBar(
      'Restored the version into the editor. Save to keep it.',
    );
  }
}

class _VersionRow extends StatelessWidget {
  final SkotiqColors colors;
  final SequenceVersionSummary version;
  final bool isLatest;
  final bool isLast;
  final VoidCallback onRestore;

  const _VersionRow({
    required this.colors,
    required this.version,
    required this.isLatest,
    required this.isLast,
    required this.onRestore,
  });

  @override
  Widget build(BuildContext context) {
    final label = version.label;
    final when = ClockFormat.monthDayYearHm(version.createdAt.toLocal());
    return ListRow(
      title: when,
      subtitle: label != null && label.isNotEmpty ? label : null,
      showDivider: !isLast,
      trailingWidget: isLatest
          ? const SkotiqChip(label: 'Latest', tone: ChipTone.success)
          : null,
      actions: [
        SkotiqIconButton(
          icon: LucideIcons.undo2,
          tooltip: 'Restore the version of $when',
          onPressed: onRestore,
        ),
      ],
    );
  }
}
