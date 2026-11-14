// This whole file is the pre-overhaul alert family, deprecated in favour of
// SkotiqBanner; its internal cross-references are not separate mistakes.
// ignore_for_file: deprecated_member_use_from_same_package

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:lucide_icons/lucide_icons.dart';
import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';

enum SkotiqAlertSeverity {
  /// Informational alert (blue)
  info,

  /// Success alert (green)
  success,

  /// Warning alert (yellow/orange)
  warning,

  /// Error alert (red)
  error,
}

/// A styled alert/banner component for notifications and status messages.
///
/// Superseded by `SkotiqBanner` (05 §11), which is the one banner style:
/// title and message on ONE line, tone fill at 8%, no outline, and at most one
/// action. This class keeps its old face so the ~266 call sites in
/// `skotiq_app` compile unchanged; wave 3 migrates them screen by screen
/// and wave 4 deletes this.
@Deprecated('Use SkotiqBanner (05 §11). Removed in wave 4.')
class SkotiqAlert extends StatelessWidget {
  const SkotiqAlert({
    super.key,
    required this.message,
    this.severity = SkotiqAlertSeverity.info,
    this.title,
    this.icon,
    this.action,
    this.onDismiss,
    this.showIcon = true,
    this.compact = false,
  });

  final String message;

  final SkotiqAlertSeverity severity;

  /// Optional title shown above the message
  final String? title;

  /// Custom icon (defaults to severity-appropriate icon)
  final IconData? icon;

  /// Optional action widget (usually a button)
  final Widget? action;

  /// Callback when dismiss button is pressed (shows dismiss button when set)
  final VoidCallback? onDismiss;

  final bool showIcon;

  final bool compact;

  IconData get _defaultIcon {
    return switch (severity) {
      SkotiqAlertSeverity.info => LucideIcons.info,
      SkotiqAlertSeverity.success => LucideIcons.checkCircle2,
      SkotiqAlertSeverity.warning => LucideIcons.alertTriangle,
      SkotiqAlertSeverity.error => LucideIcons.xCircle,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final (bgColor, borderColor, iconColor, textColor) = _getColors(colors);

    final padding = compact
        ? const EdgeInsets.symmetric(
            horizontal: SkotiqTokens.spaceMd,
            vertical: SkotiqTokens.spaceSm,
          )
        : const EdgeInsets.all(SkotiqTokens.spaceLg);

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: SkotiqTokens.borderRadiusMd,
        border: Border.all(color: borderColor),
      ),
      padding: padding,
      // Only an alert with an ACTION reads its own width: the action's
      // half-width bound and the narrow-screen decision to stack it under the
      // title are the sole readers of the incoming constraints (see [_body]). A
      // plain banner ignores them, so it skips the width-adaptive path and is
      // laid out directly.
      //
      // That same distinction is what lets a plain banner report an intrinsic
      // HEIGHT. The width-adaptive path defers its build to a [LayoutBuilder],
      // which by framework design throws on every intrinsic query, so it is
      // shielded by [_IntrinsicSafeLayout] — the shield [AlertDialog]'s
      // `IntrinsicWidth` needs, but it answers a zero height too, which
      // collapses the banner to nothing inside an `IntrinsicHeight`. A banner
      // built directly is an ordinary `Row` that measures its own height.
      child: action == null
          ? _body(const BoxConstraints(), iconColor, textColor)
          : _IntrinsicSafeLayout(
              child: LayoutBuilder(
                builder: (context, constraints) =>
                    _body(constraints, iconColor, textColor),
              ),
            ),
    );
  }

  /// The alert's contents, laid out against the width it was actually given.
  ///
  /// A `Row` measures its INFLEXIBLE children against the full incoming width
  /// before it hands what is left to the flexible ones. An action appended
  /// unbounded therefore takes whatever it wants — a `Wrap` of two buttons
  /// measures as one ~450px run and never wraps — and the text column, the only
  /// `Expanded` child, is left the remainder. Measured on this component: at a
  /// 430px window the Darkroom's branch-delete refusal gave its title 0px and
  /// laid it out one glyph per line down a 6,395px column that took the whole
  /// editor off screen; at 700px the title still measured 0px.
  ///
  /// Two rules, and the width chooses between them:
  ///
  ///  - **Wide** (at least [SkotiqTokens.breakpointMobile]): the action
  ///    stays beside the text and is bounded to half the alert. Bounded, a
  ///    `Wrap` reflows onto extra runs instead of running off the edge, and the
  ///    sentence it answers always keeps the other half. A small action is
  ///    unaffected — natural width, flush against the trailing edge, exactly
  ///    where it has always been.
  ///  - **Narrow**: bounding is not enough. Half of 430px is a column the
  ///    message wraps down for 800px, which removes the screen just as surely
  ///    as the glyph column did. So the action moves into the text column,
  ///    under the title and above the message, at the alert's own width.
  ///
  /// Under the TITLE, not under the whole text, and that placement is load
  /// bearing: the Darkroom's recipe panel is a ~330px scrolling column whose
  /// "Show more" lives inside the alert precisely so the truncated sentence and
  /// the control that completes it share one viewport. Below a seven-line
  /// message that control lands past the panel's fold — measured, not
  /// supposed — which trades this defect for the one it was built to fix.
  /// Under the title it stays where the reader already is. An alert with no
  /// title has nothing to sit under, so its action follows the message.
  ///
  /// An unbounded width (an alert inside a horizontal scroller) has no half to
  /// take and no width to compare, and keeps the plain row.
  Widget _body(BoxConstraints constraints, Color iconColor, Color textColor) {
    final gap = compact ? SkotiqTokens.spaceSm : SkotiqTokens.spaceMd;
    final bounded = constraints.maxWidth.isFinite;
    final stacked =
        action != null &&
        bounded &&
        constraints.maxWidth < SkotiqTokens.breakpointMobile;

    return Row(
      crossAxisAlignment: title != null
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (showIcon) ...[
          Icon(
            icon ?? _defaultIcon,
            size: compact ? SkotiqTokens.iconSm : SkotiqTokens.iconMd,
            color: iconColor,
          ),
          SizedBox(
            width: compact ? SkotiqTokens.spaceSm : SkotiqTokens.spaceMd,
          ),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (title != null) ...[
                Text(
                  title!,
                  style:
                      (compact
                              ? SkotiqTypography.labelSm
                              : SkotiqTypography.label)
                          .copyWith(color: textColor),
                ),
                const SizedBox(height: SkotiqTokens.spaceXs),
              ],
              if (stacked && title != null) ...[
                Align(alignment: Alignment.centerRight, child: action!),
                SizedBox(height: gap),
              ],
              Text(
                message,
                style:
                    (compact ? SkotiqTypography.bodySm : SkotiqTypography.body)
                        .copyWith(color: textColor.withValues(alpha: 0.9)),
              ),
              if (stacked && title == null) ...[
                SizedBox(height: gap),
                Align(alignment: Alignment.centerRight, child: action!),
              ],
            ],
          ),
        ),
        if (action != null && !stacked) ...[
          SizedBox(width: gap),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: bounded ? constraints.maxWidth / 2 : double.infinity,
            ),
            child: action!,
          ),
        ],
        if (onDismiss != null) ...[
          SizedBox(
            width: compact ? SkotiqTokens.spaceSm : SkotiqTokens.spaceMd,
          ),
          IconButton(
            icon: Icon(
              LucideIcons.x,
              size: compact ? SkotiqTokens.iconSm : SkotiqTokens.iconMd,
              // An icon-only control with no text of its own; without a name
              // the only way out of the alert is a blank button.
              semanticLabel: 'Dismiss',
            ),
            tooltip: 'Dismiss',
            onPressed: onDismiss,
            color: textColor.withValues(alpha: 0.7),
            padding: EdgeInsets.zero,
            constraints: BoxConstraints(
              minWidth: compact ? 24 : 32,
              minHeight: compact ? 24 : 32,
            ),
            splashRadius: compact ? 16 : 20,
          ),
        ],
      ],
    );
  }

  (Color bg, Color border, Color icon, Color text) _getColors(
    SkotiqColors colors,
  ) {
    return switch (severity) {
      SkotiqAlertSeverity.info => (
        Color.alphaBlend(
          colors.info.withValues(alpha: 0.06),
          colors.surfaceAlt,
        ),
        colors.info.withValues(alpha: 0.35),
        colors.info,
        colors.textPrimary,
      ),
      SkotiqAlertSeverity.success => (
        Color.alphaBlend(
          colors.success.withValues(alpha: 0.06),
          colors.surfaceAlt,
        ),
        colors.success.withValues(alpha: 0.35),
        colors.success,
        colors.textPrimary,
      ),
      SkotiqAlertSeverity.warning => (
        Color.alphaBlend(
          colors.warning.withValues(alpha: 0.06),
          colors.surfaceAlt,
        ),
        colors.warning.withValues(alpha: 0.35),
        colors.warning,
        colors.textPrimary,
      ),
      SkotiqAlertSeverity.error => (
        Color.alphaBlend(
          colors.error.withValues(alpha: 0.06),
          colors.surfaceAlt,
        ),
        colors.error.withValues(alpha: 0.35),
        colors.error,
        colors.textPrimary,
      ),
    };
  }
}

/// Answers intrinsic-dimension queries so they never reach the
/// [LayoutBuilder] beneath it, which cannot answer them — measuring a
/// LayoutBuilder speculatively would run its build callback against the live
/// tree, so the framework throws instead. [AlertDialog] measures its content
/// with `IntrinsicWidth`, which made every alert-with-action inside a dialog
/// crash at layout.
///
/// Zero is the honest answer for a wrapping banner's WIDTH: the alert conforms
/// to whatever width its parent chooses and wraps its text there, so it has no
/// preferred width of its own to report, and letting it drive an
/// `IntrinsicWidth` parent wider would size a dialog to the alert's longest
/// unwrapped line. Inside a measuring parent the alert therefore defers to
/// its siblings for sizing; everywhere else these overrides are never called
/// and layout is untouched.
///
/// The HEIGHT overrides are a different case, and a shortcoming: zero there is
/// not honest, it is simply all this shield can answer, because the
/// LayoutBuilder beneath it cannot be measured speculatively at any width. An
/// alert wrapped in this — one WITH an action, the only kind that reads its own
/// width — therefore still collapses to nothing inside an `IntrinsicHeight`.
/// That is why [SkotiqAlert] only reaches for this shield when it has an
/// action: a plain banner is laid out directly, is an ordinary `Row`, and
/// measures its own height like any other widget. No screen in this repo places
/// an alert WITH an action inside an `IntrinsicHeight`; making that case
/// measurable means replacing the LayoutBuilder with a render object that lays
/// out both arrangements, which is a larger change than this shield.
class _IntrinsicSafeLayout extends SingleChildRenderObjectWidget {
  const _IntrinsicSafeLayout({super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderIntrinsicSafeLayout();
}

class _RenderIntrinsicSafeLayout extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => 0;

  @override
  double computeMaxIntrinsicWidth(double height) => 0;

  @override
  double computeMinIntrinsicHeight(double width) => 0;

  @override
  double computeMaxIntrinsicHeight(double width) => 0;
}

/// An inline banner alert that can be placed within content.
class SkotiqInlineBanner extends StatelessWidget {
  const SkotiqInlineBanner({
    super.key,
    required this.message,
    this.severity = SkotiqAlertSeverity.info,
    this.icon,
    this.showIcon = true,
  });

  final String message;
  final SkotiqAlertSeverity severity;
  final IconData? icon;
  final bool showIcon;

  IconData get _defaultIcon {
    return switch (severity) {
      SkotiqAlertSeverity.info => LucideIcons.info,
      SkotiqAlertSeverity.success => LucideIcons.check,
      SkotiqAlertSeverity.warning => LucideIcons.alertTriangle,
      SkotiqAlertSeverity.error => LucideIcons.alertCircle,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final color = _getColor(colors);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showIcon) ...[
          Icon(icon ?? _defaultIcon, size: SkotiqTokens.iconSm, color: color),
          const SizedBox(width: SkotiqTokens.spaceSm),
        ],
        Flexible(
          child: Text(
            message,
            style: SkotiqTypography.bodySm.copyWith(color: color),
          ),
        ),
      ],
    );
  }

  Color _getColor(SkotiqColors colors) {
    return switch (severity) {
      SkotiqAlertSeverity.info => colors.info,
      SkotiqAlertSeverity.success => colors.success,
      SkotiqAlertSeverity.warning => colors.warning,
      SkotiqAlertSeverity.error => colors.error,
    };
  }
}
