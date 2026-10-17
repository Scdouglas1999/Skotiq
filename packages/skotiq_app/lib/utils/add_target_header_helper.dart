import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Shared helper for adding a target header to the current sequence.
///
/// `CurrentSequenceNotifier.addTargetHeader` THROWS
/// [NoActiveSequenceException] when no sequence is loaded, rather than quietly
/// creating one the user did not ask for. This helper centralises the
/// prompt-then-create dance so every entry point that adds a target (planner,
/// planetarium, framing, annotation overlay) behaves identically.
///
/// Returns `true` if the target was actually added, `false` if the user
/// declined the prompt or the editor refused (e.g. a sequence is running).
Future<bool> addTargetHeaderWithPrompt({
  required BuildContext context,
  required WidgetRef ref,
  required TargetHeaderNode targetNode,
}) async {
  final notifier = ref.read(currentSequenceProvider.notifier);

  Future<bool> attempt() async {
    try {
      notifier.addTargetHeader(targetNode);
      return true;
    } on NoActiveSequenceException {
      // Caller-aware fallback — prompt the user to create a sequence
      // pre-named after the target, then retry.
      final shouldCreate = await showDialog<bool>(
        context: context,
        builder: (ctx) => SkotiqDialog(
          title: 'No sequence open',
          icon: LucideIcons.folderOpen,
          width: 420,
          actions: [
            SkotiqButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
            SkotiqButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              label: 'Create & add',
              size: ButtonSize.small,
            ),
          ],
          child: Text(
            'You don\'t have a sequence open yet. '
            'Create one named "${targetNode.targetName}" and add this '
            'target to it?',
          ),
        ),
      );
      if (shouldCreate != true) return false;
      notifier.createSequence(name: targetNode.targetName);
      // Retry once — on the second attempt the sequence exists so
      // addTargetHeader will succeed (or surface a different error like
      // SequenceLockedException, which we handle below).
      notifier.addTargetHeader(targetNode);
      return true;
    } on SequenceLockedException catch (e) {
      // Cannot edit while running/paused/stopping. Surface to the user
      // via the standard snackbar pipe — the calling screen does not
      // need to know about execution state.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
      return false;
    }
  }

  return attempt();
}
