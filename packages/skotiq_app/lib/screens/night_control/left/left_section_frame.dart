// The frame every plan-column section shares: padding, a bold title with an
// optional muted note on the right, and a hairline under it.
import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../night_control_contracts.dart';

class NightLeftSectionFrame extends StatelessWidget {
  const NightLeftSectionFrame({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.divider = true,
    this.gap = 6,
  });

  final String title;

  /// A short muted note or link beside the title ("Psc · galaxy 9.9′").
  final Widget? trailing;

  final Widget child;

  /// The hairline under the section; the last section has none.
  final bool divider;

  /// Space between the title row and the body.
  final double gap;

  /// The most of the row the title takes when a note sits beside it.
  static const double titleShare = 0.62;

  static const EdgeInsets padding = EdgeInsets.symmetric(
    horizontal: SkotiqTokens.spaceMd,
    vertical: 10,
  );

  static TextStyle titleStyle(SkotiqColors colors) =>
      SkotiqTypography.labelStrong.copyWith(color: colors.textPrimary);

  static TextStyle noteStyle(SkotiqColors colors) =>
      SkotiqTypography.caption.copyWith(color: colors.textMuted);

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final trailing = this.trailing;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: divider
            ? Border(bottom: BorderSide(color: colors.border))
            : const Border(),
      ),
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            LayoutBuilder(
              builder: (context, constraints) {
                final heading = Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: titleStyle(colors),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                  ),
                );
                if (trailing == null) return heading;
                // The title keeps its natural width up to a cap, so a long
                // target name ellipsizes and the note beside it still shows.
                return Row(
                  children: <Widget>[
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: constraints.maxWidth * titleShare,
                      ),
                      child: heading,
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Expanded(
                      child: Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: trailing,
                      ),
                    ),
                  ],
                );
              },
            ),
            SizedBox(height: gap),
            child,
          ],
        ),
      ),
    );
  }
}

/// A muted one-liner for a section with nothing to show.
class NightLeftEmpty extends StatelessWidget {
  const NightLeftEmpty(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: NightLeftSectionFrame.noteStyle(context.skotiqColors),
      );
}

/// The color a [MetricTone] reads in, on [colors].
Color nightToneColor(MetricTone tone, SkotiqColors colors) => switch (tone) {
      MetricTone.neutral => colors.textPrimary,
      MetricTone.good => colors.success,
      MetricTone.warning => colors.warning,
      MetricTone.bad => colors.error,
    };
