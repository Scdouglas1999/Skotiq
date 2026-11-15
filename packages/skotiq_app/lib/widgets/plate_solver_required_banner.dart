import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_app/router/app_routes.dart';

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
    router.push(AppRoute.plateSolvingSettings.path);
  }

  @override
  Widget build(BuildContext context) {
    return SkotiqBanner(
      tone: BannerTone.warning,
      title: 'Plate solver not configured.',
      message: contextMessage ??
          'Skotiq needs ASTAP or Astrometry.net installed and reachable for '
              'this. Set one up to continue.',
      action: showActionButton
          ? SkotiqButton(
              label: 'Set up plate solver',
              variant: ButtonVariant.secondary,
              size: ButtonSize.small,
              onPressed: () => _navigateToSettings(context),
            )
          : null,
    );
  }
}
