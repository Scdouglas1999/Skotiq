import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import '../utils/touch_target.dart';
import '../tokens/shell_chrome_metrics.dart';

/// What an [InstrumentPill]'s dot means.
///
/// Deliberately not the full status palette: an instrument pill says whether
/// the thing it names is there and whether it is happy, and a bar of five
/// colours says neither at a glance.
enum InstrumentTone {
  /// Nothing attached, nothing running. A muted dot.
  idle,

  /// Attached and ready, or the state the operator is aiming at.
  primary,

  /// Connected, running, safe.
  success,

  /// Attention, but not a failure.
  warning,

  /// Disconnected mid-session, failed, unsafe.
  error;

  Color _color(SkotiqColors colors) => switch (this) {
    InstrumentTone.idle => colors.textMuted,
    InstrumentTone.primary => colors.primary,
    InstrumentTone.success => colors.success,
    InstrumentTone.warning => colors.warning,
    InstrumentTone.error => colors.error,
  };
}

/// One readout in the instrument bar (05-components §10b).
///
/// 22 px tall, 8 px of horizontal padding, `radiusXs`, `surfaceHover` on hover.
/// The instrument bar is built ONLY from these and [InstrumentSeparator]: one
/// shape for every fact means the bar can be read by position instead of by
/// re-parsing a different chip design at every stop.
///
/// The value is the loud part and the icon is the quiet part, per the "numbers
/// are loud, labels are quiet" rule — which is why there is no `label`
/// parameter. "Camera: ASI2600MM" spends half a pill saying what the camera
/// glyph already said.
class InstrumentPill extends StatefulWidget {
  /// 13 px, `textMuted`. Says what KIND of fact this is.
  final IconData? icon;

  /// Draws the 7 px state dot between the icon and the value.
  final InstrumentTone? dotTone;

  /// The fact itself.
  final String value;

  /// Renders [value] in the mono, tabular readout face. For a clock, a
  /// temperature, a focuser position — anything whose digits should not shift
  /// as they tick.
  final bool mono;

  /// Where clicking goes. A pill with no destination is not clickable and does
  /// not light up on hover, because a hover state on something inert is a
  /// promise the pill cannot keep.
  final VoidCallback? onTap;

  /// Adds the halo that marks a live, running state. Reserved for the run-state
  /// pill: it is the only thing in the chrome that is allowed to draw the eye.
  final bool live;

  /// Overrides the accessible name. Defaults to the value, which is right for
  /// "22:41:08" but not for a bare device name whose glyph carries the noun.
  final String? semanticLabel;

  /// Longest the value may run before it ellipsizes.
  final double? maxValueWidth;

  /// A quiet label and a second readout after [value], in one pill.
  ///
  /// Exists for exactly one case: the clock, where local time and sidereal
  /// time are a single glance ("22:41:08  LST 03:12:44"). Two pills would put
  /// a hover boundary and 16 px of padding between two numbers an operator
  /// reads together.
  final String? trailingLabel;
  final String? trailingValue;

  const InstrumentPill({
    super.key,
    required this.value,
    this.icon,
    this.dotTone,
    this.mono = false,
    this.onTap,
    this.live = false,
    this.semanticLabel,
    this.maxValueWidth,
    this.trailingLabel,
    this.trailingValue,
  });

  /// The bar's own height is 32; the pill sits inside it with 5 px of air.
  static const double height = 22.0;

  /// The state dot.
  static const double dotSize = 7.0;

  /// 03-tokens §6 puts chip and instrument-pill glyphs at 13.
  static const double iconSize = SkotiqTokens.iconPillGlyph;

  @override
  State<InstrumentPill> createState() => _InstrumentPillState();
}

class _InstrumentPillState extends State<InstrumentPill> {
  bool _isHovered = false;

  /// The face a readout wears. Mono and tabular for anything whose digits
  /// tick, so the pill does not change width as the seconds roll.
  TextStyle _valueStyle(SkotiqColors colors) => widget.mono
      ? SkotiqTypography.readoutXs.copyWith(color: colors.textPrimary)
      : SkotiqTypography.bodySm.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w500,
        );

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final tappable = widget.onTap != null;

    final content = Container(
      height: InstrumentPill.height,
      padding: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceSm),
      decoration: BoxDecoration(
        color: _isHovered && tappable
            ? colors.surfaceHover
            : Colors.transparent,
        borderRadius: SkotiqTokens.borderRadiusXs,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.icon != null) ...[
            Icon(
              widget.icon,
              size: InstrumentPill.iconSize,
              color: colors.textMuted,
            ),
            const SizedBox(width: SkotiqTokens.spaceXs + 2),
          ],
          if (widget.dotTone != null) ...[
            _Dot(tone: widget.dotTone!, live: widget.live, colors: colors),
            const SizedBox(width: SkotiqTokens.spaceXs + 2),
          ],
          ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: widget.maxValueWidth ?? double.infinity,
            ),
            child: Text(
              widget.value,
              style: _valueStyle(colors),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ),
          if (widget.trailingLabel != null) ...[
            const SizedBox(width: SkotiqTokens.spaceSm),
            Text(
              widget.trailingLabel!,
              style: SkotiqTypography.captionSm.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
          if (widget.trailingValue != null) ...[
            const SizedBox(width: SkotiqTokens.spaceXs + 2),
            Text(
              widget.trailingValue!,
              style: _valueStyle(colors),
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
            ),
          ],
        ],
      ),
    );

    // A pill that navigates is a button and says so; one that only reports is
    // static text. Publishing `button` on an inert pill would offer assistive
    // tech an action that does nothing.
    if (!tappable) {
      return Semantics(
        label: widget.semanticLabel ?? widget.value,
        excludeSemantics: true,
        child: content,
      );
    }

    return Semantics(
      button: true,
      enabled: true,
      label: widget.semanticLabel ?? widget.value,
      excludeSemantics: true,
      // 22px is a POINTER size; a finger needs 48. The box grows, the pill
      // itself stays the height the instrument bar gives it.
      child: SkotiqTouchTarget.hitBox(
        context,
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: GestureDetector(onTap: widget.onTap, child: content),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  final InstrumentTone tone;
  final bool live;
  final SkotiqColors colors;

  const _Dot({required this.tone, required this.live, required this.colors});

  @override
  Widget build(BuildContext context) {
    final color = tone._color(colors);
    return Container(
      width: InstrumentPill.dotSize,
      height: InstrumentPill.dotSize,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        // A ring, not a pulse. The bar is on screen on every route, and a
        // pulsing dot there cost a full-window frame per vsync for as long as
        // the run lasted.
        boxShadow: live
            ? [
                BoxShadow(
                  color: color.withValues(
                    alpha: SkotiqTokens.opacityLiveHalo,
                  ),
                  spreadRadius: 3,
                ),
              ]
            : null,
      ),
    );
  }
}

/// The 1 x 14 hairline that groups instrument pills.
///
/// The instrument bar's only divider. Groups are separated by one of these and
/// nothing else — no boxes, no background changes, no gaps wide enough to read
/// as a gap.
class InstrumentSeparator extends StatelessWidget {
  const InstrumentSeparator({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      width: 1,
      height: ShellChromeMetrics.statusBarDividerHeight,
      margin: const EdgeInsets.symmetric(horizontal: SkotiqTokens.spaceXs),
      color: colors.border,
    );
  }
}
