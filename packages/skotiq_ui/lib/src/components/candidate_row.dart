import 'package:flutter/material.dart';

import '../theme/skotiq_colors.dart';
import '../theme/skotiq_tokens.dart';
import '../theme/skotiq_typography.dart';
import 'skotiq_panel.dart';
import 'readout.dart';

/// A target candidate on the Plan screen: a panel laid out as a six-column
/// grid — score badge, name and a muted line, two small readouts, a window bar
/// and one button.
class Candidate extends StatelessWidget {
  const Candidate({
    super.key,
    required this.score,
    required this.name,
    required this.detail,
    required this.readouts,
    this.window,
    this.action,
    this.selected = false,
    this.scoreTone,
    this.onTap,
    this.columns,
    this.dense = false,
  });

  /// The score, already formatted (0–100, no decimals).
  final String score;

  /// The target's name.
  final String name;

  /// One muted line: catalogue, type, size.
  final String detail;

  /// Two small readouts — altitude and transit, or whatever the screen ranks
  /// by.
  final List<Readout> readouts;

  /// The imageable window as a fraction of the night, or null when the target
  /// has none tonight.
  final CandidateWindow? window;

  /// One button — never the page's primary.
  final Widget? action;

  /// Draws the `panelSelected` ring.
  final bool selected;

  /// The badge fill. `success` for a candidate worth imaging, `warning` for one
  /// that is marginal. Defaults to `success`.
  final Color? scoreTone;

  /// Makes the whole candidate tappable.
  final VoidCallback? onTap;

  /// Fixed column widths shared with a [CandidateHeader] and every other row
  /// of the same list.
  ///
  /// Null sizes each readout and the action to its own content, which is fine
  /// for a lone candidate but lets the columns drift between rows of a list:
  /// a wider button on one row pushed that row's readouts left of the rest.
  /// When set, the window slot is reserved even on a row without a window so
  /// the action column stays put.
  final CandidateColumns? columns;

  /// Halves the vertical padding, for a long scrolling list where the row
  /// height decides how many targets fit on screen.
  final bool dense;

  /// The score badge's edge length.
  static const double badgeSize = 44;

  /// Gap between the candidate's columns.
  static const double columnGap = SkotiqTokens.spaceMd;

  /// The panel's inner padding on each side.
  static const double padding = SkotiqTokens.spaceMd;

  /// The panel's vertical padding when [dense].
  static const double densePadding = SkotiqTokens.spaceSm;

  /// The width of the panel's hairline outline, selected or not. The content
  /// sits inside it, so a header lining up with the content has to skip it.
  static const double outlineWidth = 1;

  /// The width of a candidate's window bar, in logical pixels.
  static const double windowBarWidth = 120;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final tone = scoreTone ?? colors.success;

    final grid = columns;
    final panel = SkotiqPanel(
      padding: EdgeInsets.symmetric(
        horizontal: padding,
        vertical: dense ? densePadding : padding,
      ),
      selected: selected,
      child: Row(
        children: <Widget>[
          Container(
            width: badgeSize,
            height: badgeSize,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: tone.withValues(alpha: SkotiqTokens.opacityStatusFill),
              borderRadius: SkotiqTokens.borderRadiusLg,
            ),
            child: Text(
              score,
              style: SkotiqTypography.readoutBadge.copyWith(color: tone),
            ),
          ),
          const SizedBox(width: columnGap),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  name,
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  detail,
                  style: SkotiqTypography.bodySm.copyWith(
                    color: colors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (grid != null) ...<Widget>[
            for (final readout in readouts) ...<Widget>[
              const SizedBox(width: columnGap),
              SizedBox(width: grid.readoutWidth, child: readout),
            ],
            const SizedBox(width: columnGap),
            SizedBox(
              width: windowBarWidth,
              child: window == null
                  ? null
                  : CandidateWindowBar(window: window!),
            ),
            const SizedBox(width: columnGap),
            SizedBox(
              width: grid.actionWidth,
              child: action == null
                  ? null
                  : Align(alignment: Alignment.centerRight, child: action),
            ),
          ] else ...<Widget>[
            if (readouts.isNotEmpty) ...<Widget>[
              const SizedBox(width: columnGap),
              ReadoutRow(children: readouts),
            ],
            if (window != null) ...<Widget>[
              const SizedBox(width: columnGap),
              SizedBox(
                width: windowBarWidth,
                child: CandidateWindowBar(window: window!),
              ),
            ],
            if (action != null) ...<Widget>[
              const SizedBox(width: columnGap),
              action!,
            ],
          ],
        ],
      ),
    );

    if (onTap == null) return panel;

    return Semantics(
      button: true,
      enabled: true,
      selected: selected,
      label: name,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: ExcludeSemantics(child: panel),
        ),
      ),
    );
  }
}

/// The fixed widths a list of [Candidate]s and its [CandidateHeader] share,
/// so a column's name sits over its values on every row.
@immutable
class CandidateColumns {
  const CandidateColumns({
    required this.readoutWidth,
    required this.actionWidth,
  });

  /// The width of each readout column.
  final double readoutWidth;

  /// The width of the action slot. Wide enough for the widest button the list
  /// shows, so a row with a longer label does not shift its own columns.
  final double actionWidth;

  @override
  bool operator ==(Object other) =>
      other is CandidateColumns &&
      other.readoutWidth == readoutWidth &&
      other.actionWidth == actionWidth;

  @override
  int get hashCode => Object.hash(readoutWidth, actionWidth);
}

/// The column-name row above a list of [Candidate]s laid out with the same
/// [columns]: [leading] over the badge-and-name column, then one label per
/// readout and one over the window bar, each starting where its column does.
class CandidateHeader extends StatelessWidget {
  const CandidateHeader({
    super.key,
    required this.leading,
    required this.readoutLabels,
    required this.windowLabel,
    required this.columns,
  });

  /// What sits over the name column, typically the list's count.
  final Widget leading;

  /// One label per readout column, in the rows' order.
  final List<String> readoutLabels;

  /// The label over the window bar.
  final String windowLabel;

  /// The widths the rows beneath use.
  final CandidateColumns columns;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final style = SkotiqTypography.eyebrow.copyWith(color: colors.textMuted);
    Widget label(String text) => Text(
      text.toUpperCase(),
      style: style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );

    const inset = Candidate.padding + Candidate.outlineWidth;
    return Padding(
      padding: const EdgeInsets.only(
        left: inset + Candidate.badgeSize + Candidate.columnGap,
        right: inset,
      ),
      child: Row(
        children: <Widget>[
          Expanded(child: leading),
          for (final text in readoutLabels) ...<Widget>[
            const SizedBox(width: Candidate.columnGap),
            SizedBox(width: columns.readoutWidth, child: label(text)),
          ],
          const SizedBox(width: Candidate.columnGap),
          SizedBox(width: Candidate.windowBarWidth, child: label(windowLabel)),
          const SizedBox(width: Candidate.columnGap),
          SizedBox(width: columns.actionWidth),
        ],
      ),
    );
  }
}

/// A candidate's imageable window, expressed as fractions of the night.
@immutable
class CandidateWindow {
  const CandidateWindow({
    required this.start,
    required this.end,
    required this.now,
  });

  /// Where the imageable span starts, 0 = the left edge of the night.
  final double start;

  /// Where it ends, 1 = the right edge.
  final double end;

  /// Where "now" is on the same axis.
  final double now;
}

/// The 8px `well` track with a `primary` span and a 2px `textPrimary` tick at
/// "now".
class CandidateWindowBar extends StatelessWidget {
  const CandidateWindowBar({super.key, required this.window});

  final CandidateWindow window;

  /// The track's height.
  static const double trackHeight = 8;

  /// The "now" tick's width.
  static const double tickWidth = 2;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final left = (window.start.clamp(0.0, 1.0)) * width;
        final right = (window.end.clamp(0.0, 1.0)) * width;
        final now = (window.now.clamp(0.0, 1.0)) * width;
        return SizedBox(
          height: trackHeight,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.well,
                    borderRadius: SkotiqTokens.borderRadiusXs,
                  ),
                ),
              ),
              Positioned(
                left: left,
                width: (right - left).clamp(0.0, width),
                top: 0,
                bottom: 0,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: SkotiqTokens.borderRadiusXs,
                  ),
                ),
              ),
              Positioned(
                left: (now - tickWidth / 2).clamp(0.0, width - tickWidth),
                width: tickWidth,
                top: 0,
                bottom: 0,
                child: ColoredBox(color: colors.textPrimary),
              ),
            ],
          ),
        );
      },
    );
  }
}
