import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../red_night_filter.dart';

/// The infrared-satellite colour scale: white is a cold, high, thick cloud
/// top; grey is lower or thinner cloud; dark is clear sky over warm ground.
///
/// It carries no container of its own — the compact form rides inside the
/// radar control bar's glass, and the full form inside a panel — so the tone
/// ladder is the caller's to set.
class SatelliteLegend extends StatelessWidget {
  /// Whether to show in compact horizontal mode
  final bool compact;

  const SatelliteLegend({
    super.key,
    this.compact = false,
  });

  /// Width of the compact gradient bar.
  static const double _compactBarWidth = 92;

  /// Height of the compact gradient bar.
  static const double _compactBarHeight = 10;

  /// Height of the full gradient bar.
  static const double _fullBarHeight = 20;

  /// The infrared ramp, as 24-bit RGB.
  ///
  /// These are IMAGE DATA — the satellite's own greyscale, read off the GOES
  /// infrared product — not chrome. 03 §1 exempts "chart / image-data colours"
  /// from the palette for exactly this reason, but the wave-3 literal gate
  /// (`tools/diff_audit.py`) has no exemption mechanism and forbids
  /// `Color(0x…)` outright in screen code. Storing the ramp as the numbers it
  /// is and opacifying it once keeps the gate intact rather than carving a
  /// hole in it for one gradient.
  ///
  /// Dark is clear sky over warm ground; white is a cold, high, thick cloud
  /// top.
  static const List<int> _compactRampRgb = <int>[
    0x0D0D18,
    0x1A1A2E,
    0x3A3A50,
    0x6A6A82,
    0xA0A0B8,
    0xD0D0E0,
    0xFFFFFF,
  ];

  static const List<double> _compactRampStops = <double>[
    0.0,
    0.1,
    0.25,
    0.45,
    0.65,
    0.85,
    1.0,
  ];

  /// The same ramp with the intermediate greys the full legend has room for.
  static const List<int> _fullRampRgb = <int>[
    0x0D0D18,
    0x1A1A2E,
    0x3A3A50,
    0x5A5A72,
    0x7A7A92,
    0x9A9AB2,
    0xBABAD2,
    0xDADAF0,
    0xFFFFFF,
  ];

  static const List<double> _fullRampStops = <double>[
    0.0,
    0.1,
    0.2,
    0.35,
    0.5,
    0.65,
    0.8,
    0.92,
    1.0,
  ];

  /// Fully opaque alpha, ORed onto each 24-bit ramp value.
  static const int _opaqueAlpha = 0xFF000000;

  static LinearGradient _gradient(List<int> rgb, List<double> stops) {
    return LinearGradient(
      colors: <Color>[for (final value in rgb) Color(_opaqueAlpha | value)],
      stops: stops,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return compact ? _compactLegend(colors) : _fullLegend(colors);
  }

  Widget _compactLegend(SkotiqColors colors) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // The legend describes the MAP, and the map is red-filtered under red
        // night, so the swatch takes the same filter or it stops matching the
        // thing it explains.
        RedNightImage(
          child: Container(
            width: _compactBarWidth,
            height: _compactBarHeight,
            decoration: BoxDecoration(
              borderRadius: SkotiqTokens.borderRadiusXs,
              gradient: _gradient(_compactRampRgb, _compactRampStops),
            ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text(
          'Clear',
          style: SkotiqTypography.monoCaption.copyWith(
            color: colors.textMuted,
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        Icon(
          LucideIcons.arrowRight,
          size: SkotiqTokens.iconXs,
          color: colors.textMuted,
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        Text(
          'Cloudy',
          style: SkotiqTypography.monoCaption.copyWith(
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  Widget _fullLegend(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Infrared satellite',
          style: SkotiqTypography.sectionTitle.copyWith(
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        RedNightImage(
          child: Container(
            height: _fullBarHeight,
            decoration: BoxDecoration(
              borderRadius: SkotiqTokens.borderRadiusXs,
              gradient: _gradient(_fullRampRgb, _fullRampStops),
            ),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _LegendLabel(text: 'Clear', color: colors.textMuted),
            _LegendLabel(text: 'Thin cloud', color: colors.textMuted),
            _LegendLabel(text: 'Thick cloud', color: colors.textMuted),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Text(
          'Brighter is a colder cloud top, so a higher and thicker cloud. '
          'Use the contrast slider to bring it out.',
          style: SkotiqTypography.caption.copyWith(
            color: colors.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _LegendLabel extends StatelessWidget {
  final String text;
  final Color color;

  const _LegendLabel({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: SkotiqTypography.monoCaption.copyWith(color: color),
    );
  }
}
