// Preview FOV slider, presets and equipment FOV overlay controls.
part of '../framing_controls.dart';

/// Preview FOV slider with current value, optional equipment-FOV badge, and a
/// [SegmentedControl] of quick presets (0.5°, 1°, 2°, 5°, equipment).
class FramingPreviewFovSlider extends StatelessWidget {
  final SkotiqColors colors;
  final double value;
  final bool hasEquipment;
  final double? equipmentFov;
  final ValueChanged<double> onChanged;

  const FramingPreviewFovSlider({
    super.key,
    required this.colors,
    required this.value,
    required this.hasEquipment,
    this.equipmentFov,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${value.toStringAsFixed(1)}°',
                  style: SkotiqTypography.readoutMd.copyWith(
                    color: colors.primary,
                  ),
                ),
                if (hasEquipment && equipmentFov != null)
                  // Flexible so the equipment badge clips/ellipsizes rather than
                  // overflowing the row when this slider is hosted in a narrow
                  // column (the guided framing rail inside the 250-500px sidebar).
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration:
                          SkotiqDecorations.chip(colors, tone: colors.info),
                      child: Text(
                        'Equipment: ${equipmentFov!.toStringAsFixed(2)}°',
                        overflow: TextOverflow.ellipsis,
                        style: SkotiqTypography.caption
                            .copyWith(color: colors.info),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 4,
                activeTrackColor: colors.primary,
                inactiveTrackColor: colors.border,
                thumbColor: colors.primary,
                overlayColor: colors.primary.withValues(alpha: 0.1),
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              ),
              child: Slider(
                value: value,
                min: 0.1,
                max: 20.0,
                divisions: 199,
                onChanged: onChanged,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('0.1°',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted)),
                Text('20°',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textMuted)),
              ],
            ),
            const SizedBox(height: SkotiqTokens.spaceSm),
            // Quick presets as the one second-level switch style inside a panel
            // (05 §5). The equipment FOV joins the row as a last segment when a
            // profile resolves; when the slider sits between presets nothing is
            // selected, which SegmentedControl renders for index -1.
            Builder(builder: (context) {
              final values = <double>[
                0.5,
                1.0,
                2.0,
                5.0,
                if (hasEquipment && equipmentFov != null) equipmentFov!,
              ];
              final labels = <String>[
                '0.5°',
                '1°',
                '2°',
                '5°',
                if (hasEquipment && equipmentFov != null) 'Equip',
              ];
              final selected =
                  values.indexWhere((preset) => (value - preset).abs() < 0.05);
              // SegmentedControl is a mainAxisSize.min Row with no wrap, and
              // this panel is hosted in a 250-500 px column (and a phone
              // bottom sheet). Let the presets scroll instead of overflowing.
              return SizedBox(
                height: SegmentedControl.segmentHeight,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedControl(
                    segments: labels,
                    selectedIndex: selected,
                    onSelected: (index) => onChanged(values[index]),
                  ),
                ),
              );
            }),
          ],
        ));
  }
}

class FramingEquipmentFovOverlayControls extends StatelessWidget {
  final SkotiqColors colors;
  final bool showOverlay;
  final double opacity;
  final VoidCallback onToggle;
  final ValueChanged<double> onOpacityChanged;

  const FramingEquipmentFovOverlayControls({
    super.key,
    required this.colors,
    required this.showOverlay,
    required this.opacity,
    required this.onToggle,
    required this.onOpacityChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.info.withValues(alpha: 0.05),
        borderRadius: SkotiqTokens.borderRadiusInline8,
        border: Border.all(color: colors.info.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(SkotiqIcons.frame, size: 14, color: colors.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Equipment FOV Overlay',
                  style: SkotiqTypography.labelStrongSm
                      .copyWith(color: colors.info),
                ),
              ),
              SkotiqSwitch(
                value: showOverlay,
                onChanged: (_) => onToggle(),
              ),
            ],
          ),
          if (showOverlay) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'Opacity',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textSecondary),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      activeTrackColor: colors.info,
                      inactiveTrackColor: colors.border,
                      thumbColor: colors.info,
                      overlayColor: colors.info.withValues(alpha: 0.1),
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                    ),
                    child: Slider(
                      value: opacity,
                      min: 0.1,
                      max: 0.8,
                      onChanged: onOpacityChanged,
                    ),
                  ),
                ),
                SizedBox(
                  width: 35,
                  child: Text(
                    '${(opacity * 100).round()}%',
                    style: SkotiqTypography.caption
                        .copyWith(color: colors.textSecondary),
                    textAlign: TextAlign.right,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Shows your actual equipment field of view as an overlay',
              style: SkotiqTypography.caption
                  .copyWith(color: colors.textMuted),
            ),
          ],
        ],
      ),
    );
  }
}
