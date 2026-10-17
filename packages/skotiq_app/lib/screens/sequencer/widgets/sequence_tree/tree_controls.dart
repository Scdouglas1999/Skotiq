part of '../sequence_tree.dart';

// The canvas bar (widgets/sequence_toolbar.dart) took over the sequence
// name, the validation counts, the Timeline / Map toggles, collapse-all
// and the jump-to-step search in wave 3, so the row of header controls
// that used to live here is gone with the header that hosted them. The
// node-category legend went with the category colours it explained.
// What remains is the per-node validation overlay the tree draws itself.

/// Wraps a node widget with a validation badge overlay.
/// Shows a small warning/error indicator in the top-right corner when the node
/// has validation issues.
class _NodeValidationWrapper extends StatelessWidget {
  final SkotiqColors colors;
  final ValidationSeverity? validationSeverity;
  final List<ValidationIssue>? validationIssues;
  final Widget child;

  const _NodeValidationWrapper({
    required this.colors,
    required this.validationSeverity,
    required this.validationIssues,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (validationSeverity == null ||
        validationIssues == null ||
        validationIssues!.isEmpty) {
      return child;
    }

    final Color badgeColor;
    final IconData badgeIcon;
    switch (validationSeverity!) {
      case ValidationSeverity.error:
        badgeColor = colors.error;
        badgeIcon = LucideIcons.xCircle;
        break;
      case ValidationSeverity.warning:
        badgeColor = colors.warning;
        badgeIcon = LucideIcons.alertTriangle;
        break;
      case ValidationSeverity.info:
        badgeColor = colors.info;
        badgeIcon = LucideIcons.info;
        break;
    }

    final badgeForeground =
        ThemeData.estimateBrightnessForColor(badgeColor) == Brightness.dark
            ? const Color(0xFFFFFFFF)
            : const Color(0xFF000000);

    return Stack(
      clipBehavior: Clip.none,
      children: [
        child,
        Positioned(
          top: 0,
          right: 0,
          child: Tooltip(
            richMessage: TextSpan(
              children: [
                for (int i = 0; i < validationIssues!.length; i++) ...[
                  if (i > 0) const TextSpan(text: '\n'),
                  TextSpan(
                    text: validationIssues![i].title,
                    style: SkotiqTypography.h6,
                  ),
                  TextSpan(
                    text: ': ${validationIssues![i].description}',
                    style: SkotiqTypography.caption,
                  ),
                ],
              ],
            ),
            child: Container(
              width: 18,
              height: 18,
              decoration: BoxDecoration(
                color: badgeColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: badgeColor.withValues(alpha: 0.3),
                    blurRadius: 4,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: Center(
                child: validationIssues!.length > 1
                    ? Text(
                        '${validationIssues!.length}',
                        style: SkotiqTypography.monoCaption.copyWith(
                          color: badgeForeground,
                        ),
                      )
                    : Icon(
                        badgeIcon,
                        size: 10,
                        color: badgeForeground,
                      ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
