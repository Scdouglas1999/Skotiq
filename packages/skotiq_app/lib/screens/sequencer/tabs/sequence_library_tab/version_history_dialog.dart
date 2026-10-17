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

class _VersionHistoryDialogState extends ConsumerState<_VersionHistoryDialog> {
  late Future<List<SequenceVersionSummary>> _versionsFuture;
  late final SkotiqBackend _authority;
  late final SequenceRepository _repository;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;

  @override
  void initState() {
    super.initState();
    _authority = ref.read(backendProvider);
    _repository = ref.read(sequenceRepositoryProvider);
    _versionsFuture = _load();
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next) || !mounted) return;
        context.showWarningSnackBar(
          'The connected host changed. Version history closed.',
        );
        closeAuthorityBoundDialog(context);
      },
    );
  }

  Future<List<SequenceVersionSummary>> _load() {
    return _repository.listVersions(widget.sequenceId);
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    return Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        side: BorderSide(color: colors.border),
      ),
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 560,
          designMaxHeight: 640,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(colors),
            Flexible(child: _buildBody(colors)),
            _buildFooter(colors),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.gitBranch, size: 20, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Version History',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize18,
                    fontWeight: FontWeight.w700,
                    color: colors.textPrimary,
                  ),
                ),
                Text(
                  widget.sequenceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize12,
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(LucideIcons.x, color: colors.textMuted),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Widget _buildBody(SkotiqColors colors) {
    return FutureBuilder<List<SequenceVersionSummary>>(
      future: _versionsFuture,
      builder: (context, snapshot) {
        if (!snapshot.hasData && !snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: CircularProgressIndicator(color: colors.primary),
            ),
          );
        }
        if (snapshot.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: Text(
                'Failed to load version history: ${snapshot.error}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize13,
                  color: colors.error,
                ),
              ),
            ),
          );
        }
        final versions = snapshot.data ?? const <SequenceVersionSummary>[];
        if (versions.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.history, size: 32, color: colors.textMuted),
                  const SizedBox(height: 12),
                  Text(
                    'No saved versions yet',
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize14,
                      fontWeight: FontWeight.w600,
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'A version is captured each time this sequence is saved.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.all(16),
          itemCount: versions.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) => _VersionRow(
            colors: colors,
            version: versions[index],
            isLatest: index == 0,
            onRestore: () => _restore(versions[index]),
          ),
        );
      },
    );
  }

  Widget _buildFooter(SkotiqColors colors) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.info, size: 13, color: colors.textMuted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Restoring loads the version into the editor; save to keep it.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textMuted,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _restore(SequenceVersionSummary version) async {
    if (!identical(ref.read(backendProvider), _authority)) return;
    final editor = ref.read(currentSequenceProvider.notifier);
    Sequence? restored;
    try {
      restored = await _repository.restoreVersion(version.id);
    } catch (e) {
      if (mounted && identical(ref.read(backendProvider), _authority)) {
        context.showErrorSnackBar('Failed to restore version: $e');
      }
      return;
    }
    if (!mounted || !identical(ref.read(backendProvider), _authority)) return;
    if (restored == null) {
      context.showErrorSnackBar('That version is no longer available');
      return;
    }

    try {
      editor.loadSequence(restored);
    } on UnsavedChangesException catch (e) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Discard unsaved changes?'),
          content: ConstrainedBox(
            constraints: AdaptiveDialogConstraints.hybrid(
              ctx,
              designMaxWidth: 440,
            ),
            child: Text('"${e.currentSequenceName}" has unsaved changes. '
                'Restoring this version will discard them.'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Discard and restore'),
            ),
          ],
        ),
      );
      if (discard != true ||
          !identical(ref.read(backendProvider), _authority)) {
        return;
      }
      editor.loadSequence(restored, discardUnsaved: true);
    }

    if (!mounted || !identical(ref.read(backendProvider), _authority)) return;
    Navigator.of(context).pop();
    ref.read(sequencerTabProvider.notifier).state = 0;
    context.showSuccessSnackBar(
      'Restored version into the editor — save to keep it',
    );
  }
}

class _VersionRow extends StatelessWidget {
  final SkotiqColors colors;
  final SequenceVersionSummary version;
  final bool isLatest;
  final VoidCallback onRestore;

  const _VersionRow({
    required this.colors,
    required this.version,
    required this.isLatest,
    required this.onRestore,
  });

  String _formatTimestamp(DateTime date) {
    return DateFormat('MMM d, yyyy HH:mm').format(date);
  }

  @override
  Widget build(BuildContext context) {
    final label = version.label;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.gitCommit, size: 16, color: colors.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _formatTimestamp(version.createdAt),
                      style: TextStyle(
                        fontSize: SkotiqTypography.fontSize13,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    if (isLatest) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: SkotiqDecorations.tintedBadge(
                          colors.success,
                          borderRadius:
                              BorderRadius.circular(SkotiqTokens.radiusInline4),
                        ),
                        child: Text(
                          'Latest',
                          style: SkotiqTypography.labelStrongSm
                              .copyWith(color: colors.success),
                        ),
                      ),
                    ],
                  ],
                ),
                if (label != null && label.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: SkotiqTypography.fontSize12,
                      color: colors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 8),
          SkotiqButton(
            label: 'Restore',
            icon: LucideIcons.undo2,
            variant: ButtonVariant.outline,
            size: ButtonSize.small,
            onPressed: onRestore,
          ),
        ],
      ),
    );
  }
}
