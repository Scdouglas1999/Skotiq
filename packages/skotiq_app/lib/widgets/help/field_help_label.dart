import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A form-field label paired with a small help affordance.
///
/// Renders a [SkotiqTypography.label] (in [SkotiqColors.textSecondary])
/// followed by a tooltipped [LucideIcons.helpCircle] icon. Used throughout the
/// Onboarding & First-Light flows (the wizard spine, the equipment-profile
/// editor, and the hardware-preset editor) so every field that needs a hint
/// gets a consistent, discoverable explanation.
///
/// Two help payload shapes are supported:
///   * a single [help] string — shown as a plain tooltip; or
///   * a [helpTitle] + [helpBody] pair — shown as a richer two-line popover
///     (bold title over a muted body), for fields that warrant more than a
///     one-liner (e.g. "Gain" / "Offset" trade-offs).
///
/// Exactly one of [help] or ([helpTitle] + [helpBody]) must be supplied; the
/// constructor asserts this rather than silently rendering an empty tooltip —
/// a missing help string is a programmer error, not a runtime fallback.
class FieldHelpLabel extends StatelessWidget {
  /// The visible field label, e.g. `Focal length (mm)`.
  final String label;

  /// Plain-text help shown in the tooltip. Mutually exclusive with the
  /// [helpTitle]/[helpBody] pair.
  final String? help;

  /// Optional rich-popover title. When supplied, [helpBody] is required and
  /// [help] must be null.
  final String? helpTitle;

  /// Optional rich-popover body. Required when [helpTitle] is supplied.
  final String? helpBody;

  /// Position of the tooltip relative to the help icon. Defaults to
  /// [SkotiqTooltipPosition.top].
  final SkotiqTooltipPosition tooltipPosition;

  const FieldHelpLabel({
    super.key,
    required this.label,
    this.help,
    this.helpTitle,
    this.helpBody,
    this.tooltipPosition = SkotiqTooltipPosition.top,
  }) : assert(
          (help != null) ^ (helpTitle != null && helpBody != null),
          'FieldHelpLabel requires either `help` or both `helpTitle` and '
          '`helpBody` (and not both forms at once).',
        );

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            label,
            style: SkotiqTypography.label.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        helpAffordance(
          context,
          message: help,
          title: helpTitle,
          body: helpBody,
          position: tooltipPosition,
        ),
      ],
    );
  }
}

/// A standalone, tooltipped help icon for inline use beside existing labels
/// (e.g. next to a [SkotiqTextField]'s built-in `label`, where a full
/// [FieldHelpLabel] would duplicate the text).
///
/// Supply either [message] (plain tooltip) or [title] + [body] (rich popover).
/// Exactly one form must be provided; mixing or omitting both throws an
/// [ArgumentError] so a misconfigured affordance surfaces immediately instead
/// of rendering an empty, mysterious icon.
Widget helpAffordance(
  BuildContext context, {
  String? message,
  String? title,
  String? body,
  SkotiqTooltipPosition position = SkotiqTooltipPosition.top,
}) {
  final hasPlain = message != null;
  final hasRich = title != null && body != null;
  if (hasPlain == hasRich) {
    throw ArgumentError(
      'helpAffordance requires either `message` or both `title` and `body` '
      '(and not both forms at once).',
    );
  }

  final colors = SkotiqColors.of(context);
  final icon = Icon(
    LucideIcons.helpCircle,
    size: SkotiqTokens.iconXs,
    color: colors.textMuted,
  );

  // A bare icon is not a focusable/hoverable target on its own across all
  // pointer surfaces; wrap it so the cursor signals interactivity and the
  // hit area is comfortable.
  final affordance = MouseRegion(
    cursor: SystemMouseCursors.help,
    child: Semantics(
      // The tooltip content is the accessible description for this icon.
      label: hasRich ? '$title. $body' : message,
      child: icon,
    ),
  );

  if (hasRich) {
    return SkotiqTooltip(
      message: '$title\n$body',
      position: position,
      richMessage: _RichHelpContent(title: title, body: body),
      child: affordance,
    );
  }

  return SkotiqTooltip(
    message: message!,
    position: position,
    child: affordance,
  );
}

/// Two-line rich tooltip body: a bold title over a muted explanatory line.
class _RichHelpContent extends StatelessWidget {
  final String title;
  final String body;

  const _RichHelpContent({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: SkotiqTypography.labelSm.copyWith(
            color: colors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          body,
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textSecondary,
          ),
        ),
      ],
    );
  }
}
