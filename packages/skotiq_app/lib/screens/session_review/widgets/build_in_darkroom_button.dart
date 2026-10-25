/// The session review's way to build masters: a shortcut into the Darkroom's
/// guided build for this session's target.
///
/// Masters are built in one place. The guided build combines every night of a
/// target, checks the framing before it integrates, and registers what it
/// writes, so the review hands the operator to it rather than integrating this
/// one night on its own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/darkroom_navigation.dart';

/// Where the build button goes for [targetName]: the target's framing check,
/// or the Darkroom's target list when the session names no target.
String sessionReviewBuildLocation(String? targetName) {
  final name = targetName?.trim();
  return name == null || name.isEmpty
      ? darkroomTabLocation(DarkroomTab.targets)
      : darkroomFramingLocation(name);
}

/// "Build masters" in the session review.
class BuildInDarkroomButton extends ConsumerWidget {
  /// The session's target, as the guided build names it; null when the
  /// session's frames name none.
  final String? targetName;

  /// The button's key; a screen showing the shortcut twice keys each one.
  final Key buttonKey;

  /// The small secondary size of a page header action.
  final bool compact;

  const BuildInDarkroomButton({
    super.key,
    required this.targetName,
    this.buttonKey = const ValueKey('session_review_build_in_darkroom'),
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final refusal = watchDarkroomHostOnlyRefusal(ref);
    final name = targetName?.trim();
    final where = name == null || name.isEmpty
        ? 'Opens the Darkroom target list, where every target\'s nights are '
            'built into masters together.'
        : 'Opens the framing check for $name in the Darkroom. The build '
            'combines every night of $name, not only this one.';
    const label = 'Build masters in the Darkroom';
    final variant = compact ? ButtonVariant.secondary : ButtonVariant.primary;
    final size = compact ? ButtonSize.small : ButtonSize.medium;
    if (refusal != null) {
      // The reason rides on the accessible name: a tooltip alone does not
      // reach the Linux accessibility bridge.
      return Tooltip(
        message: refusal,
        child: Semantics(
          container: true,
          button: true,
          enabled: false,
          label: unavailableControlName(label, refusal),
          child: ExcludeSemantics(
            child: SkotiqButton(
              key: buttonKey,
              label: label,
              icon: SkotiqIcons.layers,
              variant: variant,
              size: size,
              onPressed: null,
            ),
          ),
        ),
      );
    }
    return Tooltip(
      message: where,
      child: SkotiqButton(
        key: buttonKey,
        label: label,
        icon: SkotiqIcons.layers,
        variant: variant,
        size: size,
        semanticsHint: where,
        onPressed: () => context.go(sessionReviewBuildLocation(targetName)),
      ),
    );
  }
}
