import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../../utils/coordinate_format_utils.dart';

class BottomInfoBar extends ConsumerWidget {
  final SkotiqColors colors;

  const BottomInfoBar({super.key, required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final viewState = ref.watch(skyViewStateProvider);
    // NOT viewState.centerRA/centerDec: in the horizontal (Alt/Az) frame those
    // two fields hold the PRESERVED equatorial pose from before the mode
    // switch, so the bar reported a centre tens of degrees from where the view
    // was actually pointing (and never moved as you dragged). This provider
    // converts the live alt/az camera back to RA/Dec in that mode.
    final (centerRA, centerDec) = ref.watch(viewCenterEquatorialProvider);
    final selectedAltAz = ref.watch(selectedObjectAltAzProvider);
    final sunAltitude = ref.watch(sunAltitudeProvider);
    final bortle = ref.watch(bortleClassProvider);
    final limMag = BortleScale.limitingMagnitude(bortle);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isCompact = constraints.maxWidth < 900;
        final isVeryCompact = constraints.maxWidth < 720;
        final horizontalPadding =
            isVeryCompact ? 12.0 : (isCompact ? 16.0 : 20.0);
        final itemSpacing = isVeryCompact ? 8.0 : (isCompact ? 12.0 : 20.0);

        final items = <Widget>[
          InfoItem(
            label: 'Center RA',
            compactLabel: 'RA',
            value: CoordinateFormatUtils.formatRAShort(centerRA),
            colors: colors,
            compact: isCompact,
          ),
          SizedBox(width: itemSpacing),
          InfoItem(
            label: 'Center Dec',
            compactLabel: 'Dec',
            value: isCompact
                ? CoordinateFormatUtils.formatDecCompact(centerDec)
                : CoordinateFormatUtils.formatDec(centerDec),
            colors: colors,
            compact: isCompact,
          ),
          SizedBox(width: itemSpacing),
          InfoItem(
            // The renderer scales by min(width, height), so the field of view
            // spans the canvas's SHORT axis; the long axis is wider. The compact
            // form keeps the qualifier — a bare "FOV: 60.0deg" reads as the
            // whole frame, which is the very ambiguity the full label exists to
            // remove.
            label: 'FOV (short axis)',
            compactLabel: 'FOV (short)',
            value: CoordinateFormatUtils.formatFOV(viewState.fieldOfView),
            colors: colors,
            compact: isCompact,
          ),
          if (!isVeryCompact) ...[
            SizedBox(width: itemSpacing),
            InfoItem(
              label: 'Bortle',
              value: '$bortle (lim ${limMag.toStringAsFixed(1)}m)',
              colors: colors,
              compact: isCompact,
              valueColor: bortle <= 3
                  ? colors.success
                  : bortle <= 5
                      ? colors.warning
                      : colors.error,
            ),
          ],
          if (!isCompact && selectedAltAz != null) ...[
            SizedBox(width: itemSpacing * 2),
            InfoItem(
              label: 'Selected Alt',
              value: CoordinateFormatUtils.formatAltitude(selectedAltAz.$1),
              colors: colors,
              compact: isCompact,
              // Green here means "usable now", so it has to survive daylight
              // too: a target 63 deg up with the Sun 63 deg up is not green.
              valueColor: switch (gradeObservability(
                altitudeDeg: selectedAltAz.$1,
                sunAltitudeDeg: sunAltitude,
              )) {
                ObservabilityGrade.excellent => colors.success,
                ObservabilityGrade.good ||
                ObservabilityGrade.low ||
                ObservabilityGrade.twilight =>
                  colors.warning,
                ObservabilityGrade.belowHorizon ||
                ObservabilityGrade.daylight =>
                  colors.error,
              },
            ),
            SizedBox(width: itemSpacing),
            InfoItem(
              label: 'Az',
              value: CoordinateFormatUtils.formatAzimuth(selectedAltAz.$2),
              colors: colors,
              compact: isCompact,
            ),
          ],
        ];

        return Container(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            isCompact ? 8 : 12,
            horizontalPadding,
            (isCompact ? 8 : 12) + MediaQuery.viewPaddingOf(context).bottom,
          ),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
              colors: [
                // absolute: bottom scrim over the planetarium sky canvas
                Colors.black.withValues(alpha: 0.8),
                Colors.transparent,
              ],
            ),
          ),
          // Scale-to-fit at every width, not just the very-compact branch: the
          // two "Selected Alt / Az" items only appear once something is
          // selected, and the six-item row overflows a ~1200 px window (195 px
          // on the right) the moment it does. A HUD that reports the sky must
          // not itself be the thing that breaks.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: items),
          ),
        );
      },
    );
  }
}

class InfoItem extends StatelessWidget {
  final String label;

  /// Label to use when [compact] is set.
  ///
  /// Defaults to [label]'s first word, which is fine for "FOV (short axis)" but
  /// was actively wrong for the coordinate pair: "Center RA" and "Center Dec"
  /// both compacted to "Center", so a 900 px window printed two adjacent,
  /// identically-labelled fields holding different quantities. Fields whose
  /// discriminator is not the first word pass it explicitly.
  final String? compactLabel;
  final String value;
  final SkotiqColors colors;
  final Color? valueColor;
  final bool compact;

  const InfoItem({
    super.key,
    required this.label,
    this.compactLabel,
    required this.value,
    required this.colors,
    this.valueColor,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final shown = compact ? (compactLabel ?? label.split(' ').first) : label;
    // Its OWN accessible node, named label AND value together.
    //
    // Two bare Texts publish two label fragments with no boundary of their own,
    // and Flutter merges compatible sibling fragments into the nearest
    // enclosing node — which on the planetarium is the sky canvas, a node that
    // carries a tap action. The whole HUD therefore arrived at AT-SPI as ONE
    // focusable panel named "20:37:18 / 1x / Center RA: ... / Bortle: 5" and
    // flagged interactive-but-disabled. `container: true` gives each readout a
    // node; `excludeSemantics` stops the glyphs being read a second time.
    return Semantics(
      container: true,
      label: '$shown $value',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$shown:',
            style: TextStyle(
              fontSize: compact
                  ? SkotiqTypography.fontSize10
                  : SkotiqTypography.fontSize11,
              // absolute: HUD label over the planetarium sky canvas
              color: Colors.white.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: compact
                  ? SkotiqTypography.fontSize11
                  : SkotiqTypography.fontSize12,
              fontWeight: FontWeight.w500,
              // absolute: HUD value over the planetarium sky canvas
              color: valueColor ?? Colors.white70,
              fontFeatures: const [ui.FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
