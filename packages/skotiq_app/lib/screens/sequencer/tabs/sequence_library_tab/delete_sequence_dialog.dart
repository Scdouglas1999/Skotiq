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
      child: SkotiqDialog(
        title: 'Delete sequence',
        width: SkotiqDialog.widthConfirm,
        closeEnabled: !_isDeleting,
        actions: [
          SkotiqButton(
            onPressed: _isDeleting ? null : () => Navigator.of(context).pop(),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
          ),
          SkotiqButton(
            onPressed: _isDeleting ? null : _delete,
            label: 'Delete',
            variant: ButtonVariant.destructive,
            isLoading: _isDeleting,
          ),
        ],
        child: Text(
          'Delete "${widget.sequenceName}"? This cannot be undone.',
          style: SkotiqTypography.body.copyWith(
            color: widget.colors.textSecondary,
          ),
        ),
      ),
    );
  }
}
