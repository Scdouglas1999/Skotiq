import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Toolbar shown when multi-select mode is active.
/// Provides batch operations: Copy, Paste, Delete, Enable, Disable.
class BatchOperationsToolbar extends ConsumerWidget {
  final SkotiqColors colors;

  const BatchOperationsToolbar({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedIds = ref.watch(multiSelectedNodeIdsProvider);
    final clipboard = ref.watch(nodeCopyClipboardProvider);
    final hasClipboard = clipboard != null && clipboard.isNotEmpty;
    final count = selectedIds.length;
    // Mutating batch actions must be gated while the executor owns the tree.
    // Copy and Clear are non-mutating and stay enabled.
    final canEdit = ref.watch(canEditSequenceProvider);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: SkotiqDecorations.iconChip(
        colors.primary,
        borderRadius: BorderRadius.zero,
      ).copyWith(
        border: Border(
          bottom: BorderSide(color: colors.primary.withValues(alpha: 0.3)),
        ),
      ),
      child: Row(
        children: [
          // Selection count
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: SkotiqDecorations.statusChip(
              colors.primary,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline4),
              bordered: false,
            ),
            child: Text(
              '$count selected',
              style: SkotiqTypography.h6.copyWith(color: colors.primary),
            ),
          ),

          const SizedBox(width: 12),

          // Batch actions scroll horizontally so the toolbar never overflows
          // on narrow windows / phones.
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  // Copy
                  _ToolbarButton(
                    colors: colors,
                    icon: LucideIcons.copy,
                    label: 'Copy',
                    onPressed: () {
                      ref
                          .read(multiSelectedNodeIdsProvider.notifier)
                          .copySelected();
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                              '$count node${count == 1 ? '' : 's'} copied'),
                          duration: const Duration(seconds: 2),
                          backgroundColor: colors.info,
                        ),
                      );
                    },
                  ),

                  const SizedBox(width: 4),

                  // Paste
                  _ToolbarButton(
                    colors: colors,
                    icon: LucideIcons.clipboardPaste,
                    label: 'Paste',
                    enabled: hasClipboard && canEdit,
                    onPressed: hasClipboard && canEdit
                        ? () {
                            // Read the count before pasting so the snackbar
                            // reports how many nodes landed.
                            final pasted = clipboard.length;
                            ref
                                .read(multiSelectedNodeIdsProvider.notifier)
                                .pasteFromClipboard();
                            _showCountSnackBar(
                              context,
                              colors,
                              'Pasted $pasted node${pasted == 1 ? '' : 's'}',
                            );
                          }
                        : null,
                  ),

                  const SizedBox(width: 8),
                  Container(width: 1, height: 20, color: colors.border),
                  const SizedBox(width: 8),

                  // Enable
                  _ToolbarButton(
                    colors: colors,
                    icon: LucideIcons.eye,
                    label: 'Enable',
                    enabled: canEdit,
                    onPressed: canEdit
                        ? () {
                            ref
                                .read(multiSelectedNodeIdsProvider.notifier)
                                .enableSelected();
                            _showCountSnackBar(
                              context,
                              colors,
                              '$count node${count == 1 ? '' : 's'} enabled',
                            );
                          }
                        : null,
                  ),

                  const SizedBox(width: 4),

                  // Disable
                  _ToolbarButton(
                    colors: colors,
                    icon: LucideIcons.eyeOff,
                    label: 'Disable',
                    enabled: canEdit,
                    onPressed: canEdit
                        ? () {
                            ref
                                .read(multiSelectedNodeIdsProvider.notifier)
                                .disableSelected();
                            _showCountSnackBar(
                              context,
                              colors,
                              '$count node${count == 1 ? '' : 's'} disabled',
                            );
                          }
                        : null,
                  ),

                  const SizedBox(width: 8),
                  Container(width: 1, height: 20, color: colors.border),
                  const SizedBox(width: 8),

                  // Delete
                  _ToolbarButton(
                    colors: colors,
                    icon: LucideIcons.trash2,
                    label: 'Delete',
                    color: colors.error,
                    enabled: canEdit,
                    onPressed: canEdit
                        ? () {
                            _confirmDelete(context, ref, selectedIds);
                          }
                        : null,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Clear selection
          _ToolbarButton(
            colors: colors,
            icon: LucideIcons.x,
            label: 'Clear',
            onPressed: () {
              ref.read(multiSelectedNodeIdsProvider.notifier).clear();
            },
          ),
        ],
      ),
    );
  }

  /// Brief feedback snackbar mirroring the Copy snackbar styling so every
  /// batch action confirms what it did.
  void _showCountSnackBar(
    BuildContext context,
    SkotiqColors colors,
    String message,
  ) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
        backgroundColor: colors.info,
      ),
    );
  }

  void _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Set<String> selectedIds,
  ) {
    final count = selectedIds.length;
    final sequence = ref.read(currentSequenceProvider);
    // Sum descendants across the whole selection. Aligns the wording with
    // the single-node confirmation helper ("N nodes + M descendants").
    final descendants = sequence == null
        ? 0
        : selectedIds.fold<int>(
            0, (sum, id) => sum + sequence.countDescendants(id));

    // Point at the toolbar button, not only the keystroke: Ctrl+Z needs
    // keyboard focus inside the builder subtree, the Undo button never does.
    final body = descendants == 0
        ? 'This will remove the selected node${count == 1 ? '' : 's'}. '
            'Recover them with Undo in the toolbar (or Ctrl+Z).'
        : 'This will remove $count node${count == 1 ? '' : 's'} plus their '
            '$descendants descendant${descendants == 1 ? '' : 's'}. '
            'Recover them with Undo in the toolbar (or Ctrl+Z).';

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          'Delete $count node${count == 1 ? '' : 's'}?',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: ConstrainedBox(
          constraints: AdaptiveDialogConstraints.hybrid(
            dialogContext,
            designMaxWidth: 440,
          ),
          child: Text(
            body,
            style: TextStyle(color: colors.textSecondary),
          ),
        ),
        actions: [
          SkotiqButton(
            onPressed: () => Navigator.pop(dialogContext),
            label: 'Cancel',
            variant: ButtonVariant.ghost,
            size: ButtonSize.small,
          ),
          SkotiqButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              // Wrap the delete so a locked-state failure surfaces as a
              // snackbar (matching confirmAndDeleteSequenceNode) rather than
              // a raw red error overlay.
              try {
                ref
                    .read(multiSelectedNodeIdsProvider.notifier)
                    .deleteSelected();
              } catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Failed to delete nodes: $error'),
                      backgroundColor: colors.error,
                      duration: const Duration(seconds: 4),
                    ),
                  );
                }
              }
            },
            label: 'Delete',
            variant: ButtonVariant.destructive,
            size: ButtonSize.small,
          ),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool enabled;
  final Color? color;

  const _ToolbarButton({
    required this.colors,
    required this.icon,
    required this.label,
    this.onPressed,
    this.enabled = true,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? colors.textSecondary;
    final isEnabled = enabled && onPressed != null;

    return Tooltip(
      message: label,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isEnabled ? onPressed : null,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 14,
                  color: isEnabled
                      ? effectiveColor
                      : colors.textMuted.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: SkotiqTypography.labelQuiet.copyWith(
                      color: isEnabled
                          ? effectiveColor
                          : colors.textMuted.withValues(alpha: 0.4)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
