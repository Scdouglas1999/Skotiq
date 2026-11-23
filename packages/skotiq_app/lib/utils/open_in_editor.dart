import 'package:flutter/material.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// What the operator is told when opening something in the sequence editor
/// would throw away unsaved edits.
class DiscardUnsavedPrompt {
  /// The sentence after `"<current>" has unsaved changes.`, naming what
  /// happens on confirm.
  final String consequence;

  /// Label of the confirm button.
  final String confirmLabel;

  /// Whether the confirm button reads as destructive.
  final bool destructive;

  const DiscardUnsavedPrompt({
    required this.consequence,
    required this.confirmLabel,
    this.destructive = true,
  });
}

/// The prompt for replacing the editor with a sequence built or read
/// elsewhere (Plan, Framing, a sequence file).
const openLoadedSequencePrompt = DiscardUnsavedPrompt(
  consequence: 'Open the loaded sequence anyway?',
  confirmLabel: 'Discard and open',
  destructive: false,
);

/// Asks whether the unsaved edits in [currentName] may be discarded.
/// Completes with true only when the operator confirms.
Future<bool> confirmDiscardUnsaved(
  BuildContext context, {
  required String currentName,
  required DiscardUnsavedPrompt prompt,
}) async {
  final discard = await showDialog<bool>(
    context: context,
    builder: (ctx) => SkotiqDialog(
      title: 'Discard unsaved changes?',
      width: SkotiqDialog.widthConfirm,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(ctx).pop(false),
        ),
        SkotiqButton(
          label: prompt.confirmLabel,
          variant: prompt.destructive
              ? ButtonVariant.destructive
              : ButtonVariant.primary,
          size: ButtonSize.small,
          onPressed: () => Navigator.of(ctx).pop(true),
        ),
      ],
      child: Text(
        '"$currentName" has unsaved changes. ${prompt.consequence}',
      ),
    ),
  );
  return discard == true;
}

/// Opens something in the sequence editor without silently discarding
/// unsaved edits.
///
/// [load] performs the editor call (`loadSequence`, `createSequence`,
/// `loadCopyForEditing`, ...) with the given `discardUnsaved` flag. When the
/// editor refuses because of unsaved edits the operator is asked with
/// [prompt]; on confirm [load] runs again with `discardUnsaved: true`, once
/// [proceed] (when given) still allows it after the dialog closed.
///
/// A locked editor (a run is active) is reported through [onLocked]; with no
/// [onLocked] the [SequenceLockedException] propagates to the caller.
///
/// Completes with true when [load] went through.
Future<bool> openInEditor(
  BuildContext context, {
  required void Function({required bool discardUnsaved}) load,
  required DiscardUnsavedPrompt prompt,
  bool Function()? proceed,
  void Function(SequenceLockedException error)? onLocked,
}) async {
  try {
    try {
      load(discardUnsaved: false);
      return true;
    } on UnsavedChangesException catch (e) {
      if (!context.mounted) return false;
      final discard = await confirmDiscardUnsaved(
        context,
        currentName: e.currentSequenceName,
        prompt: prompt,
      );
      if (!discard || !context.mounted) return false;
      if (proceed != null && !proceed()) return false;
      load(discardUnsaved: true);
      return true;
    }
  } on SequenceLockedException catch (e) {
    if (onLocked == null) rethrow;
    if (context.mounted) onLocked(e);
    return false;
  }
}
