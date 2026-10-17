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

  /// The score badge's edge length.
  static const double badgeSize = 44;

  /// Gap between the candidate's columns.
  static const double columnGap = SkotiqTokens.spaceMd;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final tone = scoreTone ?? colors.success;

    final panel = SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
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
          if (readouts.isNotEmpty) ...<Widget>[
            const SizedBox(width: columnGap),
            ReadoutRow(children: readouts),
          ],
          if (window != null) ...<Widget>[
            const SizedBox(width: columnGap),
            SizedBox(
              width: _windowBarWidth,
              child: CandidateWindowBar(window: window!),
            ),
          ],
          if (action != null) ...<Widget>[
            const SizedBox(width: columnGap),
            action!,
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

/// The width of a candidate's window bar, in logical pixels.
const double _windowBarWidth = 120;

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
