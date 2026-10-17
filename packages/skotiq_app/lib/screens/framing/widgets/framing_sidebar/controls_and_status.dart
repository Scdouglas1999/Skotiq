part of '../framing_sidebar.dart';

/// "Frame" section of the framing side panel: rotation, the equipment field of
/// view as readouts, the preview-FOV control, the equipment-overlay controls,
/// the survey source, and the display toggles — every row a [FormRow] under one
/// [SectionTitle].
class FramingControlsSection extends ConsumerWidget {
  final SkotiqColors colors;
  final FramingState framingState;
  final AsyncValue<FramingEquipmentResult> equipmentAsync;

  const FramingControlsSection({
    super.key,
    required this.colors,
    required this.framingState,
    required this.equipmentAsync,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = equipmentAsync.valueOrNull;
    final equipment = result?.equipment;
    final hasEquipment = result?.isReady ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionTitle(icon: SkotiqIcons.frame, title: 'Frame'),

        // Rotation (only useful with equipment). Slider + exact numeric entry +
        // ±1/±90 steps — see [FramingRotationField]. Not wrapped in a FormRow:
        // the field already carries its own label-left row, and a FormRow round
        // it printed "Rotation" twice.
        FramingRotationField(
          key: FramingTutorialKeys.rotation,
          value: framingState.rotation,
          colors: colors,
          onChanged: hasEquipment
              ? (value) => ref.read(framingProvider.notifier).setRotation(value)
              : null,
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),

        // The equipment field of view, as readouts (05 §3), once a profile
        // resolves; otherwise the section says so in one quiet line.
        if (hasEquipment && equipment != null) ...[
          ReadoutRow(
            gap: SkotiqTokens.spaceLg,
            children: [
              Readout(
                size: ReadoutSize.sm,
                label: 'FOV',
                value: '${equipment.fovWidthDeg.toStringAsFixed(2)}° × '
                    '${equipment.fovHeightDeg.toStringAsFixed(2)}°',
              ),
              Readout(
                size: ReadoutSize.sm,
                label: 'Scale',
                value: equipment.imageScale.toStringAsFixed(2),
                unit: '"/px',
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          KeyValueList(rows: [
            ('Sensor', '${equipment.pixelsX} × ${equipment.pixelsY}'),
          ]),
        ] else ...[
          Text(
            'Configure equipment to see the field-of-view overlay',
            style:
                SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
          ),
        ],

        const SizedBox(height: SkotiqTokens.spaceLg),

        // Preview FOV (always available for browsing). A full-width composite
        // rather than a FormRow: the label column would squeeze the preset
        // row, and the panel already carries its own value readout.
        Text(
          'Preview field of view',
          style:
              SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        FramingPreviewFovSlider(
          colors: colors,
          value: framingState.previewFovDegrees,
          hasEquipment: hasEquipment,
          equipmentFov: equipment?.fovWidthDeg,
          onChanged: (value) {
            ref.read(framingProvider.notifier).setPreviewFov(value);
          },
        ),

        // Equipment FOV overlay controls (only when equipment is configured and
        // the preview FOV is wider than the equipment FOV).
        if (hasEquipment &&
            equipment != null &&
            framingState.previewFovDegrees > equipment.fovWidthDeg) ...[
          const SizedBox(height: SkotiqTokens.spaceLg),
          FramingEquipmentFovOverlayControls(
            colors: colors,
            showOverlay: framingState.showEquipmentFovOverlay,
            opacity: framingState.equipmentFovOverlayOpacity,
            onToggle: () {
              ref.read(framingProvider.notifier).toggleEquipmentFovOverlay();
            },
            onOpacityChanged: (value) {
              ref
                  .read(framingProvider.notifier)
                  .setEquipmentFovOverlayOpacity(value);
            },
          ),
        ],

        const SizedBox(height: SkotiqTokens.spaceLg),

        // Survey source (always available — the sky is browsable without a
        // profile).
        FormRow(
          label: 'Survey',
          child: SkotiqDropdown(
            value: framingState.surveySource.name,
            isExpanded: true,
            items: SurveySource.values.map((s) => s.name).toList(),
            itemLabels: SurveySource.values.map((s) => s.displayName).toList(),
            onChanged: (name) {
              if (name == null) return;
              ref
                  .read(framingProvider.notifier)
                  .setSurveySource(SurveySource.values.byName(name));
            },
          ),
        ),

        const SizedBox(height: SkotiqTokens.spaceLg),

        // Display toggles.
        FormRow(
          label: 'Show',
          child: Wrap(
            spacing: SkotiqTokens.spaceSm,
            runSpacing: SkotiqTokens.spaceSm,
            children: [
              SkotiqChip(
                label: 'Grid',
                selected: framingState.showGrid,
                onTap: () => ref.read(framingProvider.notifier).toggleGrid(),
              ),
              SkotiqChip(
                label: 'Labels',
                selected: framingState.showLabels,
                onTap: () => ref.read(framingProvider.notifier).toggleLabels(),
              ),
              if (hasEquipment)
                SkotiqChip(
                  label: 'Directions',
                  selected: framingState.showCardinalDirections,
                  onTap: () => ref
                      .read(framingProvider.notifier)
                      .toggleCardinalDirections(),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Coordinates panel: RA/Dec readout for where the telescope will point (the
/// reticle's effective aim — the dragged box position, or the picked target
/// while the box is centered), plus computed Alt/Az with horizon warning.
/// Copy-to-clipboard icon for the aim's RA/Dec string.
class FramingCoordinatesPanel extends StatelessWidget {
  final SkotiqColors colors;
  final FramingState framingState;
  final (double, double)? currentAltAz;

  const FramingCoordinatesPanel({
    super.key,
    required this.colors,
    required this.framingState,
    required this.currentAltAz,
  });

  @override
  Widget build(BuildContext context) {
    final target = framingState.effectiveAimTarget;

    return SkotiqPanel(
        key: FramingTutorialKeys.coordinates,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Frame center',
                  style: SkotiqTypography.labelStrongSm
                      .copyWith(color: colors.textPrimary),
                ),
                if (target != null)
                  SkotiqIconButton(
                    icon: SkotiqIcons.copy,
                    tooltip: 'Copy coordinates',
                    size: IconButtonSize.sm,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(
                        text: '${target.raFormatted}, ${target.decFormatted}',
                      ));
                      context.showInfoSnackBar('Coordinates copied');
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            FramingCoordRow(
              label: 'RA',
              value: target?.raFormatted ?? kReadoutUnknown,
              colors: colors,
            ),
            const SizedBox(height: 6),
            FramingCoordRow(
              label: 'Dec',
              value: target?.decFormatted ?? kReadoutUnknown,
              colors: colors,
            ),
            const Divider(height: 20),
            FramingCoordRow(
              label: 'Alt',
              value: currentAltAz != null
                  ? '${currentAltAz!.$1.toStringAsFixed(1)}°'
                  : kReadoutUnknown,
              colors: colors,
              isGood: currentAltAz != null && currentAltAz!.$1 > 30,
              isBad: currentAltAz != null && currentAltAz!.$1 < 15,
            ),
            const SizedBox(height: 6),
            FramingCoordRow(
              label: 'Az',
              value: currentAltAz != null
                  ? '${currentAltAz!.$2.toStringAsFixed(1)}°'
                  : kReadoutUnknown,
              colors: colors,
            ),
            if (currentAltAz != null && currentAltAz!.$1 < 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(SkotiqIcons.warning,
                        size: 12, color: colors.warning),
                    const SizedBox(width: 6),
                    Text(
                      'Target below horizon',
                      style: SkotiqTypography.caption
                          .copyWith(color: colors.warning),
                    ),
                  ],
                ),
              ),
          ],
        ));
  }
}

/// Altitude chart panel: shows tonight's altitude curve for the current
/// target, or a placeholder card when no target is selected.
class FramingAltitudePanel extends StatelessWidget {
  final SkotiqColors colors;
  final FramingState framingState;

  const FramingAltitudePanel({
    super.key,
    required this.colors,
    required this.framingState,
  });

  @override
  Widget build(BuildContext context) {
    // Chart the altitude of where the telescope will actually point (the
    // dragged reticle's effective aim), which carries the picked target's
    // name for the chart title.
    final target = framingState.effectiveAimTarget;

    if (target == null) {
      return SkotiqPanel(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(LucideIcons.trendingUp,
                      size: 14, color: colors.textMuted),
                  const SizedBox(width: 8),
                  Text(
                    'Altitude',
                    style: SkotiqTypography.labelStrongSm
                        .copyWith(color: colors.textPrimary),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Select a target to view altitude chart',
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textMuted),
                ),
              ),
            ],
          ));
    }

    return SkotiqPanel(
        padding: const EdgeInsets.all(14),
        child: AltitudeChart(
          key: FramingTutorialKeys.altitudeChart,
          raHours: target.raHours,
          decDegrees: target.decDegrees,
          targetName: target.name,
        ));
  }
}
