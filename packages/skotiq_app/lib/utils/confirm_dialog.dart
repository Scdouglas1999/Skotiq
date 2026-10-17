import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Utility class for showing confirmation dialogs.
///
/// This eliminates duplicate AlertDialog patterns across the codebase.
/// Use this instead of implementing inline `showDialog<bool>` patterns.
class ConfirmDialog {
  /// Shows a confirmation dialog and returns true if confirmed.
  ///
  /// [title] - The dialog title
  /// [message] - The dialog message/content
  /// [confirmLabel] - Label for the confirm button (default: 'Confirm')
  /// [cancelLabel] - Label for the cancel button (default: 'Cancel')
  /// [isDestructive] - If true, uses error color for confirm button
  static Future<bool> show({
    required BuildContext context,
    required String title,
    required String message,
    String confirmLabel = 'Confirm',
    String cancelLabel = 'Cancel',
    bool isDestructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return SkotiqDialog(
          title: title,
          width: 420,
          showCloseButton: false,
          actions: [
            SkotiqButton(
              label: cancelLabel,
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
              onPressed: () => Navigator.pop(ctx, false),
            ),
            SkotiqButton(
              label: confirmLabel,
              variant: isDestructive
                  ? ButtonVariant.destructive
                  : ButtonVariant.primary,
              size: ButtonSize.small,
              onPressed: () => Navigator.pop(ctx, true),
            ),
          ],
          child: Text(message),
        );
      },
    );

    return result ?? false;
  }

  /// Convenience method for delete confirmations.
  ///
  /// Shows a destructive-styled confirmation with "Delete" as the confirm label.
  static Future<bool> delete({
    required BuildContext context,
    required String itemName,
  }) =>
      show(
        context: context,
        title: 'Delete $itemName?',
        message: 'This action cannot be undone.',
        confirmLabel: 'Delete',
        isDestructive: true,
      );

  /// Convenience method for discard/cancel confirmations.
  ///
  /// Shows a destructive-styled confirmation for discarding unsaved changes.
  static Future<bool> discard({
    required BuildContext context,
    String itemName = 'changes',
  }) =>
      show(
        context: context,
        title: 'Discard $itemName?',
        message: 'Any unsaved $itemName will be lost.',
        confirmLabel: 'Discard',
        isDestructive: true,
      );

  /// Convenience method for restore confirmations.
  ///
  /// Shows a confirmation for restoring from backup.
  static Future<bool> restore({
    required BuildContext context,
    required String backupName,
  }) =>
      show(
        context: context,
        title: 'Restore Backup?',
        message:
            'This imports "$backupName" without deleting your current data. '
            'Settings with the same keys may be updated, and library items '
            'from the backup may be added.',
        confirmLabel: 'Restore',
        isDestructive: true,
      );
}
