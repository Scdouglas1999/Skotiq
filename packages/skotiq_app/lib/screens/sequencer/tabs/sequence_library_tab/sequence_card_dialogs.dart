part of '../sequence_library_tab.dart';

class _DeleteSequenceDialog extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final int sequenceId;
  final String sequenceName;

  const _DeleteSequenceDialog({
    required this.colors,
    required this.sequenceId,
    required this.sequenceName,
  });

  @override
  ConsumerState<_DeleteSequenceDialog> createState() =>
      _DeleteSequenceDialogState();
}

class _DeleteSequenceDialogState extends ConsumerState<_DeleteSequenceDialog>
    with HostBoundDialogState<_DeleteSequenceDialog> {
  @override
  String get hostChangedMessage =>
      'The connected host changed. Sequence deletion canceled.';

  @override
  bool get hostChangeDiscardsInput => true;

  late final SequenceRepository _repository;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _repository = ref.read(sequenceRepositoryProvider);
  }

  Future<void> _delete() async {
    if (host.isStale) return;
    setState(() => _isDeleting = true);
    try {
      await _repository.deleteSequence(widget.sequenceId);
      if (!mounted || host.isStale) return;

      notifySequenceCatalogChanged(
        ref,
        sequenceId: widget.sequenceId,
        action: 'deleted',
        name: widget.sequenceName,
      );
      context.showSuccessSnackBar('Deleted "${widget.sequenceName}"');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted || host.isStale) return;
      setState(() => _isDeleting = false);
      context.showErrorSnackBar('Failed to delete: ${userFacingError(e)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isDeleting,
      child: AlertDialog(
        backgroundColor: widget.colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        ),
        title: Text(
          'Delete Sequence',
          style: TextStyle(color: widget.colors.textPrimary),
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            context,
            designMaxWidth: 400,
          ),
          child: Text(
            'Are you sure you want to delete "${widget.sequenceName}"? '
            'This action cannot be undone.',
            style: TextStyle(color: widget.colors.textSecondary),
          ),
        ),
        actions: [
          SkotiqButton(
            onPressed: _isDeleting ? null : () => Navigator.of(context).pop(),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
          SkotiqButton(
            onPressed: _isDeleting ? null : _delete,
            label: 'Delete',
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
            isLoading: _isDeleting,
          ),
        ],
      ),
    );
  }
}

/// Star toggle that flips the favorite flag for a sequence. Filled (warning
/// color) when favorited, outline-muted otherwise.
class _FavoriteToggle extends StatelessWidget {
  final SkotiqColors colors;
  final bool isFavorite;
  final VoidCallback onPressed;

  const _FavoriteToggle({
    required this.colors,
    required this.isFavorite,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: isFavorite ? 'Remove from favorites' : 'Add to favorites',
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(
          LucideIcons.star,
          size: 18,
          color: isFavorite ? colors.warning : colors.textMuted,
        ),
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      ),
    );
  }
}
