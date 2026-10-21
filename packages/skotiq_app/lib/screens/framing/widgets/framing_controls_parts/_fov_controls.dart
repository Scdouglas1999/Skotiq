// Preview FOV slider, presets and equipment FOV overlay controls.
part of '../framing_controls.dart';

/// The preview field of view: the value (and the camera's own field, when a
/// profile resolves) on the label row, the slider, then quick presets as a
/// [SegmentedControl] (0.5°, 1°, 2°, 5°, and the camera's field).
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
    final camera = hasEquipment ? equipmentFov : null;
    final values = <double>[0.5, 1.0, 2.0, 5.0, if (camera != null) camera];
    final labels = <String>[
      '0.5°',
      '1°',
      '2°',
      '5°',
      if (camera != null) 'Camera'
    ];
    // When the slider sits between presets nothing is selected, which
    // SegmentedControl renders for index -1.
    final selected =
        values.indexWhere((preset) => (value - preset).abs() < 0.05);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        FramingFormRow(
          label: 'Preview',
          child: FramingSlider(
            value: value,
            min: 0.1,
            max: 20.0,
            divisions: 199,
            semanticLabel: 'Preview field of view',
            valueLabel: '${value.toStringAsFixed(1)}°',
            onChanged: onChanged,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        // Under the slider, in the control column when there is room for
        // the presets there; across the full width when there is not.
        LayoutBuilder(
          builder: (context, constraints) {
            final indent = constraints.maxWidth >= 300
                ? kFramingLabelWidth + FormRow.columnGap
                : 0.0;
            return Padding(
              padding: EdgeInsets.only(left: indent),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // SegmentedControl is a mainAxisSize.min Row with no wrap;
                  // let the presets scroll rather than overflow.
                  SizedBox(
                    height: SegmentedControl.segmentHeight,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SegmentedControl(
                        segments: labels,
                        selectedIndex: selected,
                        onSelected: (index) => onChanged(values[index]),
                      ),
                    ),
                  ),
                  if (camera != null) ...[
                    const SizedBox(height: SkotiqTokens.spaceXs),
                    FramingNote(
                      'Camera field ${camera.toStringAsFixed(2)}° wide',
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }
}

/// The equipment-FOV overlay, offered when the preview is wider than the
/// camera's field: a switch row and, while it is on, the overlay's opacity.
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqSwitchRow(
          label: 'Camera field overlay',
          tooltip: 'Draws your camera\'s actual field of view on the wider '
              'preview',
          value: showOverlay,
          compact: true,
          onChanged: (_) => onToggle(),
        ),
        if (showOverlay) ...[
          const SizedBox(height: SkotiqTokens.spaceXs),
          FramingFormRow(
            label: 'Opacity',
            child: FramingSlider(
              value: opacity,
              min: 0.1,
              max: 0.8,
              semanticLabel: 'Overlay opacity',
              valueLabel: '${(opacity * 100).round()}%',
              onChanged: onOpacityChanged,
            ),
          ),
        ],
      ],
    );
  }
}
