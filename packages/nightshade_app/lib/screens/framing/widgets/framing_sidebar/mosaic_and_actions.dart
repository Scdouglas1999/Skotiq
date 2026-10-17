part of '../framing_sidebar.dart';

/// Mosaic planning panel: enable switch, columns/rows spinners, overlap
/// slider, capture pattern (serpentine/numbers), start-corner selector, panel
/// list, and export-to-targets button.
class FramingMosaicSection extends ConsumerWidget {
  final NightshadeColors colors;
  final FramingState framingState;
  final AsyncValue<FramingEquipmentResult> equipmentAsync;

  const FramingMosaicSection({
    super.key,
    required this.colors,
    required this.framingState,
    required this.equipmentAsync,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = equipmentAsync.valueOrNull;
    final hasEquipment = result?.isReady ?? false;
    final config = framingState.mosaicConfig;
    final notifier = ref.read(framingProvider.notifier);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header with toggle
        Row(
          key: FramingTutorialKeys.mosaicBtn,
          children: [
            Expanded(
              child: Text(
                'Mosaic',
                style: NightshadeTypography.eyebrow
                    .copyWith(color: colors.textPrimary),
              ),
            ),
            NightshadeSwitch(
              value: framingState.mosaicEnabled,
              onChanged:
                  hasEquipment ? (v) => notifier.setMosaicEnabled(v) : null,
            ),
          ],
        ),

        if (!hasEquipment)
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: colors.well,
              borderRadius: NightshadeTokens.borderRadiusInline8,
            ),
            child: Row(
              children: [
                Icon(NightshadeIcons.info, size: 14, color: colors.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Configure equipment to enable mosaic planning',
                    style: NightshadeTypography.caption
                        .copyWith(color: colors.textMuted),
                  ),
                ),
              ],
            ),
          ),

        if (framingState.mosaicEnabled && hasEquipment) ...[
          const SizedBox(height: 12),

          // Grid configuration
          Row(
            children: [
              Expanded(
                child: FramingMosaicSpinner(
                  label: 'Columns',
                  value: config.columns,
                  min: 1,
                  max: 10,
                  onChanged: notifier.setMosaicColumns,
                  colors: colors,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FramingMosaicSpinner(
                  label: 'Rows',
                  value: config.rows,
                  min: 1,
                  max: 10,
                  onChanged: notifier.setMosaicRows,
                  colors: colors,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Overlap slider
          FramingSliderField(
            label: 'Overlap',
            value: config.overlapPercent,
            min: 0,
            max: 50,
            suffix: '%',
            colors: colors,
            onChanged: notifier.setMosaicOverlap,
          ),
          const SizedBox(height: 12),

          // Capture pattern options
          Row(
            children: [
              Expanded(
                child: FramingOptionButton(
                  icon: LucideIcons.moveHorizontal,
                  label: 'Serpentine',
                  isSelected: config.serpentine,
                  onTap: notifier.toggleSerpentine,
                  colors: colors,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FramingOptionButton(
                  icon: LucideIcons.hash,
                  label: 'Numbers',
                  isSelected: framingState.showPanelNumbers,
                  onTap: notifier.togglePanelNumbers,
                  colors: colors,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Start corner dropdown
          Text(
            'Start Corner',
            style: NightshadeTypography.caption
                .copyWith(color: colors.textSecondary),
          ),
          const SizedBox(height: 6),
          FramingStartCornerSelector(
            selected: config.startCorner,
            onChanged: notifier.setMosaicStartCorner,
            colors: colors,
          ),
          const SizedBox(height: 12),

          // Panel summary
          NightshadePanel(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(NightshadeIcons.layoutGrid,
                          size: 14, color: colors.primary),
                      const SizedBox(width: 8),
                      Text(
                        '${config.totalPanels} Panels',
                        style: NightshadeTypography.eyebrow
                            .copyWith(color: colors.textPrimary),
                      ),
                    ],
                  ),
                  if (framingState.mosaicPanels.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 100,
                      child: ListView.builder(
                        // Fixed-height panel rows: 20 box + 4*2 vertical padding = 28.
                        itemExtent: 28,
                        itemCount: framingState.mosaicPanels.length,
                        itemBuilder: (context, index) {
                          final panel = framingState.mosaicPanels[index];
                          final isSelected =
                              index == framingState.selectedPanelIndex;
                          return InkWell(
                            onTap: () => notifier.selectPanel(index),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? colors.primary.withValues(alpha: 0.2)
                                    : Colors.transparent,
                                borderRadius:
                                    NightshadeTokens.borderRadiusInline4,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 20,
                                    height: 20,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isSelected
                                          ? colors.primary
                                          : colors.surface,
                                      borderRadius:
                                          NightshadeTokens.borderRadiusInline4,
                                      border: Border.all(
                                        color: isSelected
                                            ? colors.primary
                                            : colors.border,
                                      ),
                                    ),
                                    child: Text(
                                      '${panel.index + 1}',
                                      style: NightshadeTypography.caption
                                          .copyWith(
                                              color: isSelected
                                                  ? colors.textPrimary
                                                  : colors.textSecondary,
                                              fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      panel.raFormatted,
                                      style: NightshadeTypography.monoCaption
                                          .copyWith(
                                              color: colors.textSecondary),
                                    ),
                                  ),
                                  Text(
                                    panel.decFormatted,
                                    style: NightshadeTypography.monoCaption
                                        .copyWith(color: colors.textSecondary),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ],
              )),

          // Create durable mosaic project (project + per-panel rows), routes
          // to /mosaic/:id so the scheduler/sequencer can drive it.
          if (framingState.mosaicPanels.isNotEmpty) ...[
            const SizedBox(height: 12),
            FramingExportMosaicButton(
              colors: colors,
              panels: framingState.mosaicPanels,
              targetName: framingState.target?.name ?? 'Mosaic',
            ),
          ],
        ],
      ],
    );
  }
}

/// Actions surface at the bottom of the framing sidebar.
///
/// The canonical, guided "resolve → frame → solve → slew" flow lives in
/// [FramingActionRail], which owns slew; this panel mounts that single rail and
/// exposes only the supplementary utility actions the rail does not own (add
/// the framed target to a sequence, save it, cache the survey cutout, and
/// reload it), so the slew/survey controls are not duplicated across two
/// surfaces. The survey source and rotation are read from `framingProvider`, so
/// the rail and the [FramingControlsSection] dropdown stay in lockstep.
class FramingActionsPanel extends ConsumerWidget {
  final NightshadeColors colors;
  final FramingState framingState;

  /// Auto-build a complete Smart Night instruction tree for the framed target
  /// and load it into the sequencer.
  final VoidCallback onAddToSequence;

  /// Insert a bare target header (name / RA / Dec / rotation, no generated
  /// instructions) into a sequence the user picks, leaving the instruction
  /// tree for them to build manually in the Sequencer.
  final VoidCallback onAddToExistingSequence;
  final VoidCallback onSaveTarget;
  final VoidCallback onCacheImage;

  const FramingActionsPanel({
    super.key,
    required this.colors,
    required this.framingState,
    required this.onAddToSequence,
    required this.onAddToExistingSequence,
    required this.onSaveTarget,
    required this.onCacheImage,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hasTarget = framingState.target != null;
    final hasSurveyImage = framingState.surveyImageBytes != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (framingState.effectiveAimTarget case final target?) ...[
          Text('Frame center · slew destination',
              style: NightshadeTypography.labelStrongSm
                  .copyWith(color: colors.textPrimary)),
          Text('${target.raFormatted}  ${target.decFormatted}',
              style: NightshadeTypography.monoCaption
                  .copyWith(color: colors.textSecondary)),
          const SizedBox(height: NightshadeTokens.spaceSm),
          SlewDropdownButton(
            ra: target.raHours,
            dec: target.decDegrees,
            targetName: target.name,
            targetRotation: framingState.rotation,
            defaultMode: SlewMode.slewAndCenter,
            isEnabled: !ref.watch(mountStateProvider).isParked,
          ),
          const SizedBox(height: NightshadeTokens.spaceSm),
        ],
        SizedBox(
            width: double.infinity,
            child: NightshadeButton(
              icon: LucideIcons.wand2,
              label: 'Auto-build sequence',
              onPressed: hasTarget ? onAddToSequence : null,
            )),
        const SizedBox(height: NightshadeTokens.spaceSm),
        const Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            title: Text('Framing checks and manual solve'),
            children: [FramingActionRail()],
          ),
        ),

        const SizedBox(height: NightshadeTokens.spaceXl),

        // Supplementary utility actions not covered by the guided rail.
        Text(
          'Utilities',
          style:
              NightshadeTypography.eyebrow.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: NightshadeTokens.spaceMd),
        // Utility actions use the design-system NightshadeButton (outline)
        // so the whole panel — guided rail + utilities — speaks one button
        // language (matching the rail's NightshadeButton solve action) rather
        // than mixing in a bespoke local button with different heights/radii.
        Row(
          children: [
            // Bare-header insert: drops the framed target into a chosen
            // sequence with no generated instructions — the user builds the
            // imaging tree under it manually in the Sequencer.
            Expanded(
              child: NightshadeButton(
                icon: LucideIcons.listPlus,
                label: 'Add to Sequence',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: hasTarget ? onAddToExistingSequence : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: NightshadeTokens.spaceSm),
        Row(
          children: [
            Expanded(
              child: NightshadeButton(
                icon: LucideIcons.bookmark,
                label: 'Save target',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: hasTarget ? onSaveTarget : null,
              ),
            ),
            const SizedBox(width: NightshadeTokens.spaceSm),
            Expanded(
              child: NightshadeButton(
                icon: NightshadeIcons.download,
                label: 'Cache image',
                variant: ButtonVariant.secondary,
                size: ButtonSize.small,
                onPressed: hasSurveyImage ? onCacheImage : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: NightshadeTokens.spaceSm),
        SizedBox(
          width: double.infinity,
          child: NightshadeButton(
            icon: NightshadeIcons.refresh,
            label: 'Reload',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: hasTarget
                ? () => ref.read(framingProvider.notifier).loadSurveyImage()
                : null,
          ),
        ),
      ],
    );
  }
}
