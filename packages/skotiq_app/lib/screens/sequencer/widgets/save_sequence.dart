import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:uuid/uuid.dart';

import '../../../utils/authority_bound_dialog.dart';
import '../../../utils/count_label.dart';
import '../../../utils/snackbar_helper.dart';

/// Save the open plan into the sequence library: Ctrl+S and the builder's
/// Save button.
///
/// A plan that already has a library row is written over that row at once,
/// keeping whether it is a template; the version history keeps what it
/// replaced. A plan that was never saved opens [showSaveSequenceDialog] for
/// its name.
Future<void> saveOpenSequence(BuildContext context, WidgetRef ref) async {
  final sequence = ref.read(currentSequenceProvider);
  if (sequence == null) {
    context.showWarningSnackBar('No sequence to save');
    return;
  }
  if (sequence.databaseId == null) {
    await showSaveSequenceDialog(context, sequence: sequence);
    return;
  }
  final scope = ref.backendScope(alive: () => context.mounted);
  try {
    final snapshotError = await _writeToLibrary(
      ref,
      scope,
      sequence,
      open: sequence,
    );
    if (scope.isStale || !context.mounted) return;
    _announceSaved(context, sequence.name, snapshotError);
  } catch (e) {
    if (scope.isStale || !context.mounted) return;
    context.showErrorSnackBar('Could not save "${sequence.name}": '
        '${userFacingError(e)}');
  }
}

/// The library save dialog for [sequence]: name and description, then save
/// as a new library entry, or for a plan that already has a row, update it or
/// save an independent copy.
Future<void> showSaveSequenceDialog(
  BuildContext context, {
  required Sequence sequence,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => SaveSequenceDialog(sequence: sequence),
    );

/// Write [toSave] to the library under [scope]'s host and re-anchor the open
/// plan on the saved row. [open] is the open plan as it was when the save
/// began; what was edited since stays unsaved.
///
/// Returns the version-history snapshot's error, or null when the snapshot
/// was taken too. The row itself is durable once this returns; a failed
/// snapshot does not fail the save. Throws when the row write fails.
Future<Object?> _writeToLibrary(
  WidgetRef ref,
  AsyncScope<SkotiqBackend> scope,
  Sequence toSave, {
  required Sequence open,
}) async {
  final repository = ref.read(sequenceRepositoryProvider);
  final savedId =
      await repository.saveSequence(toSave, isTemplate: toSave.isTemplate);
  Object? snapshotError;
  try {
    await repository.snapshotVersionOnSave(
      toSave.copyWith(databaseId: savedId),
    );
  } catch (e) {
    snapshotError = e;
  }
  if (scope.isStale) return snapshotError;
  ref.read(currentSequenceProvider.notifier).applyPersistedSave(
        savedFrom: open,
        databaseId: savedId,
        name: toSave.name,
        description: toSave.description,
        isTemplate: toSave.isTemplate,
      );
  notifySequenceCatalogChanged(
    ref,
    sequenceId: savedId,
    action: 'saved',
    name: toSave.name,
    isTemplate: toSave.isTemplate,
  );
  return snapshotError;
}

void _announceSaved(BuildContext context, String name, Object? snapshotError) {
  if (snapshotError == null) {
    context.showSuccessSnackBar('Saved "$name"');
  } else {
    context.showWarningSnackBar(
      'Saved "$name", but its version-history snapshot failed: '
      '${userFacingError(snapshotError)}',
    );
  }
}

class SaveSequenceDialog extends ConsumerStatefulWidget {
  const SaveSequenceDialog({super.key, required this.sequence});

  final Sequence sequence;

  @override
  ConsumerState<SaveSequenceDialog> createState() => _SaveSequenceDialogState();
}

class _SaveSequenceDialogState extends ConsumerState<SaveSequenceDialog>
    with HostBoundDialogState<SaveSequenceDialog> {
  @override
  String get hostChangedMessage =>
      'The connected host changed. Sequence save canceled.';

  @override
  bool get hostChangeDiscardsInput => true;

  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.sequence.name);
    _descriptionController =
        TextEditingController(text: widget.sequence.description);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  bool get _isExisting => widget.sequence.databaseId != null;

  /// Overwrite the existing saved sequence (only available for a
  /// sequence already in the library). Confirms before clobbering.
  Future<void> _updateExisting() async {
    if (_nameController.text.trim().isEmpty) {
      context.showErrorSnackBar('Please enter a sequence name');
      return;
    }
    final colors = SkotiqColors.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text('Overwrite saved sequence?',
            style: TextStyle(color: colors.textPrimary)),
        content: ConstrainedBox(
          constraints:
              AdaptiveDialogConstraints.hybrid(ctx, designMaxWidth: 400),
          child: Text(
            'This replaces the saved "${widget.sequence.name}" with the '
            'current sequence. Its earlier versions stay in Version history.',
            style: TextStyle(color: colors.textSecondary),
          ),
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
            label: 'Overwrite',
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || host.isStale) return;

    await _persist(
      widget.sequence.copyWith(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
      ),
    );
  }

  /// Save the current sequence as an independent new copy. Re-keys every
  /// node id so the copy never shares persistence with the original.
  Future<void> _saveAsNew() async {
    if (_nameController.text.trim().isEmpty) {
      context.showErrorSnackBar('Please enter a sequence name');
      return;
    }

    final idMapping = <String, String>{
      for (final id in widget.sequence.nodes.keys) id: const Uuid().v4(),
    };
    final newNodes = <String, SequenceNode>{
      for (final MapEntry(key: id, value: node)
          in widget.sequence.nodes.entries)
        idMapping[id]!: node.copyWith(
          id: idMapping[id],
          parentId: node.parentId != null ? idMapping[node.parentId] : null,
          childIds: node.childIds.map((c) => idMapping[c] ?? c).toList(),
        ),
    };
    final rootId = widget.sequence.rootNodeId;

    await _persist(
      Sequence.create(
        name: _nameController.text.trim(),
        description: _descriptionController.text.trim(),
        nodes: newNodes,
        rootNodeId: rootId != null ? idMapping[rootId] : null,
        isTemplate: false,
      ),
    );
  }

  Future<void> _persist(Sequence sequenceToSave) async {
    if (host.isStale) {
      context.showWarningSnackBar(
        'The connected host changed. Reopen the sequence library.',
      );
      return;
    }
    setState(() => _isSaving = true);
    try {
      final snapshotError = await _writeToLibrary(
        ref,
        host,
        sequenceToSave,
        open: widget.sequence,
      );
      if (!mounted || host.isStale) return;
      Navigator.pop(context);
      _announceSaved(context, sequenceToSave.name, snapshotError);
    } catch (e) {
      if (mounted && host.isCurrent) {
        context.showErrorSnackBar(
            'Failed to save sequence: ${userFacingError(e)}');
      }
    } finally {
      if (mounted && host.isCurrent) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final dialog = Dialog(
      backgroundColor: colors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8)),
      child: ConstrainedBox(
        constraints: AdaptiveDialogConstraints.hybrid(
          context,
          designMaxWidth: 450,
        ),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration:
                        SkotiqDecorations.chip(colors, tone: colors.primary),
                    child: Icon(
                      LucideIcons.save,
                      size: 20,
                      color: colors.primary,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _isExisting ? 'Update sequence' : 'Save sequence',
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize18,
                            fontWeight: FontWeight.w700,
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          _isExisting
                              ? 'Overwrite the original or save an independent copy'
                              : 'Save to your sequence library',
                          style: TextStyle(
                            fontSize: SkotiqTypography.fontSize12,
                            color: colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              SkotiqTextField(
                label: 'Sequence name',
                controller: _nameController,
                hint: 'Enter sequence name',
                autofocus: !_isExisting,
                onSubmitted: _isSaving
                    ? null
                    : (_) => _isExisting ? _updateExisting() : _saveAsNew(),
              ),
              const SizedBox(height: 20),
              SkotiqTextField(
                label: 'Description (optional)',
                controller: _descriptionController,
                hint: 'Add a description...',
                maxLines: 2,
              ),
              const SizedBox(height: 24),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: SkotiqDecorations.well(colors),
                child: Row(
                  children: [
                    Icon(LucideIcons.info, size: 16, color: colors.info),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Saving ${countLabel(widget.sequence.nodes.length, 'node')}',
                        style: TextStyle(
                          fontSize: SkotiqTypography.fontSize12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    SkotiqButton(
                      onPressed: _isSaving ? null : () => Navigator.pop(context),
                      label: 'Cancel',
                      variant: ButtonVariant.ghost,
                      size: ButtonSize.small,
                    ),
                    if (_isExisting) ...[
                      SkotiqButton(
                        label: 'Save as new copy',
                        icon: LucideIcons.copy,
                        variant: ButtonVariant.secondary,
                        onPressed: _isSaving ? null : _saveAsNew,
                        size: ButtonSize.small,
                      ),
                      SkotiqButton(
                        label: _isSaving
                            ? 'Saving...'
                            : 'Update "${widget.sequence.name}"',
                        icon: _isSaving ? LucideIcons.loader : LucideIcons.save,
                        onPressed: _isSaving ? null : _updateExisting,
                        size: ButtonSize.small,
                      ),
                    ] else
                      SkotiqButton(
                        label: _isSaving ? 'Saving...' : 'Save',
                        icon: _isSaving ? LucideIcons.loader : LucideIcons.save,
                        onPressed: _isSaving ? null : _saveAsNew,
                        size: ButtonSize.small,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return PopScope(canPop: !_isSaving, child: dialog);
  }
}
