import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Inline banner surfaced from any operation that requires a plate solver
/// (centering, framing wizard verify, polar alignment) when none is
/// configured. The "Set up plate solver" button routes the user to the
/// dedicated `/settings/plate-solving` page where the detection card,
/// browse pickers, and verify-solver tooling live.
///
/// Designed for inline use inside a dialog or screen body — it does NOT
/// wrap itself in a Scaffold or full-width Material container; callers
/// place it where they want it.
class PlateSolverRequiredBanner extends StatelessWidget {
  /// Optional context line shown above the call-to-action — typically a
  /// 1-2 sentence explanation of why the current operation needs a solver
  /// (e.g. "Centering needs ASTAP to compare the solved image to the
  /// target coordinates.").
  final String? contextMessage;

  /// Hide the call-to-action button when the parent already provides a
  /// "Configure" path of its own. Defaults to `false`.
  final bool showActionButton;
  final VoidCallback? onBeforeNavigate;

  const PlateSolverRequiredBanner({
    super.key,
    this.contextMessage,
    this.showActionButton = true,
    this.onBeforeNavigate,
  });

  void _navigateToSettings(BuildContext context) {
    final router = GoRouter.of(context);
    onBeforeNavigate?.call();
    router.push('/settings/plate-solving');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: SkotiqDecorations.emphasisSurface(
        colors.warning,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.alertTriangle,
                color: colors.warning,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Plate solver not configured',
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: colors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            contextMessage ??
                'Skotiq needs ASTAP (or Astrometry.net) installed and '
                    'reachable to perform this operation. Set one up to '
                    'continue.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colors.textPrimary,
            ),
          ),
          if (showActionButton) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerRight,
              child: SkotiqButton(
                label: 'Set up plate solver',
                icon: LucideIcons.settings,
                variant: ButtonVariant.primary,
                onPressed: () => _navigateToSettings(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
