// Delete-sequence dialog and the favourite toggle.
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

class _DeleteSequenceDialogState extends ConsumerState<_DeleteSequenceDialog> {
  late final SkotiqBackend _authority;
  late final SequenceRepository _repository;
  ProviderSubscription<SkotiqBackend>? _backendSubscription;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _authority = ref.read(backendProvider);
    _repository = ref.read(sequenceRepositoryProvider);
    _backendSubscription = ref.listenManual<SkotiqBackend>(
      backendProvider,
      (previous, next) {
        if (previous == null || identical(previous, next) || !mounted) return;
        context.showWarningSnackBar(
          'The connected host changed. Sequence deletion cancelled.',
        );
        closeAuthorityBoundDialog(context);
      },
    );
  }

  @override
  void dispose() {
    _backendSubscription?.close();
    super.dispose();
  }

  Future<void> _delete() async {
    if (!identical(ref.read(backendProvider), _authority)) return;
    setState(() => _isDeleting = true);
    try {
      await _repository.deleteSequence(widget.sequenceId);
      if (!mounted || !identical(ref.read(backendProvider), _authority)) return;

      notifySequenceCatalogChanged(
        ref,
        sequenceId: widget.sequenceId,
        action: 'deleted',
        name: widget.sequenceName,
      );
      context.showSuccessSnackBar('Deleted "${widget.sequenceName}"');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted || !identical(ref.read(backendProvider), _authority)) return;
      setState(() => _isDeleting = false);
      context.showErrorSnackBar('Failed to delete: $e');
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
