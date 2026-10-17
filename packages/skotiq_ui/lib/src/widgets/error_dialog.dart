import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../components/skotiq_button.dart';
import '../dialogs/skotiq_dialog.dart';

/// User-friendly error dialog with optional technical details.
///
/// This widget provides a consistent way to display errors throughout the app
/// with clear, non-technical messages and optional detailed error information.
class ErrorDialog extends StatefulWidget {
  final String title;
  final String message;
  final String? technicalDetails;
  final VoidCallback? onRetry;
  final VoidCallback? onDismiss;

  const ErrorDialog({
    super.key,
    required this.title,
    required this.message,
    this.technicalDetails,
    this.onRetry,
    this.onDismiss,
  });

  /// Show the error dialog in the given context.
  static Future<void> show(
    BuildContext context, {
    required String title,
    required String message,
    String? technicalDetails,
    VoidCallback? onRetry,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ErrorDialog(
        title: title,
        message: message,
        technicalDetails: technicalDetails,
        onRetry: onRetry,
        onDismiss: () => Navigator.pop(context),
      ),
    );
  }

  @override
  State<ErrorDialog> createState() => _ErrorDialogState();
}

class _ErrorDialogState extends State<ErrorDialog> {
  bool _showDetails = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;

    return Semantics(
      label: 'Error dialog: ${widget.title}',
      child: SkotiqDialog(
        title: widget.title,
        icon: LucideIcons.alertCircle,
        width: 520,
        showCloseButton: false,
        actions: [
          Semantics(
            button: true,
            // Live 2026-08-09: `button: true` without `enabled` publishes no
            // isEnabled flag, and AT-SPI reads that as disabled — the same
            // false signal the sequencer tabs carried.
            enabled: true,
            label: 'Close error dialog',
            child: SkotiqButton(
              label: 'Close',
              onPressed: widget.onDismiss,
              variant: ButtonVariant.ghost,
              size: ButtonSize.medium,
            ),
          ),
          if (widget.onRetry != null)
            Semantics(
              button: true,
              // Live 2026-08-09: `button: true` without `enabled` publishes no
              // isEnabled flag, and AT-SPI reads that as disabled — the same
              // false signal the sequencer tabs carried.
              enabled: true,
              label: 'Retry the failed operation',
              child: SkotiqButton(
                label: 'Retry',
                icon: LucideIcons.refreshCw,
                onPressed: () {
                  widget.onDismiss?.call();
                  widget.onRetry?.call();
                },
                variant: ButtonVariant.primary,
                size: ButtonSize.medium,
              ),
            ),
        ],
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // User-friendly message
            Semantics(
              label: 'Error message',
              child: Text(
                widget.message,
                style: SkotiqTypography.body.copyWith(
                  color: colors.textSecondary,
                ),
              ),
            ),

            // Technical details toggle
            if (widget.technicalDetails != null) ...[
              const SizedBox(height: SkotiqTokens.spaceLg),
              Semantics(
                button: true,
                // Live 2026-08-09: `button: true` without `enabled` publishes no
                // isEnabled flag, and AT-SPI reads that as disabled — the same
                // false signal the sequencer tabs carried.
                enabled: true,
                label: _showDetails
                    ? 'Hide technical details'
                    : 'Show technical details',
                child: InkWell(
                  onTap: () => setState(() => _showDetails = !_showDetails),
                  borderRadius: SkotiqTokens.borderRadiusMd,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SkotiqTokens.spaceSm,
                      vertical: SkotiqTokens.spaceSm - 2,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _showDetails
                              ? LucideIcons.chevronDown
                              : LucideIcons.chevronRight,
                          size: SkotiqTokens.iconSm,
                          color: colors.primary,
                        ),
                        const SizedBox(width: SkotiqTokens.spaceSm - 2),
                        Text(
                          _showDetails
                              ? 'Hide Technical Details'
                              : 'View Technical Details',
                          style: SkotiqTypography.label.copyWith(
                            color: colors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // Technical details panel
              if (_showDetails) ...[
                const SizedBox(height: SkotiqTokens.spaceMd),
                Semantics(
                  label: 'Technical error details',
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 200),
                    padding: SkotiqTokens.paddingMd,
                    decoration: BoxDecoration(
                      color: colors.background,
                      borderRadius: SkotiqTokens.borderRadiusMd,
                      border: Border.all(color: colors.border),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        widget.technicalDetails!,
                        style: SkotiqTypography.monoSm.copyWith(
                          color: colors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
