part of '../framing_sidebar.dart';

/// The Sequence section: turn the framed target into imaging work.
///
/// Auto-build writes a complete Smart Night sequence for the frame center and
/// loads it into the Sequencer; Add to sequence inserts a bare target header
/// (name / RA / Dec / rotation, and the drawn mosaic's panels) into a sequence
/// the user picks.
class FramingSequenceSection extends StatelessWidget {
  final SkotiqColors colors;
  final FramingState framingState;

  /// Auto-build a complete Smart Night instruction tree for the framed target
  /// and load it into the sequencer.
  final VoidCallback onAddToSequence;

  /// Insert a bare target header (no generated instructions) into a sequence
  /// the user picks, leaving the instruction tree for them to build.
  final VoidCallback onAddToExistingSequence;

  const FramingSequenceSection({
    super.key,
    required this.colors,
    required this.framingState,
    required this.onAddToSequence,
    required this.onAddToExistingSequence,
  });

  @override
  Widget build(BuildContext context) {
    final hasTarget = framingState.target != null;
    final panels =
        framingState.mosaicEnabled ? framingState.mosaicPanels.length : 0;
    return FramingPanelSection(
      title: 'Sequence',
      note: panels >= 2 ? '$panels mosaic panels' : null,
      children: [
        FramingButtonPair(
          first: SkotiqButton(
            icon: LucideIcons.wand2,
            label: 'Auto-build sequence',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: hasTarget ? onAddToSequence : null,
          ),
          second: SkotiqButton(
            icon: LucideIcons.listPlus,
            label: 'Add to sequence',
            variant: ButtonVariant.secondary,
            size: ButtonSize.small,
            onPressed: hasTarget ? onAddToExistingSequence : null,
          ),
        ),
      ],
    );
  }
}

/// The Mosaic section: the switch on the title row, then the grid (columns,
/// rows, overlap), the capture order (serpentine, panel numbers, start
/// corner), the panel list and the create-project action.
class FramingMosaicSection extends ConsumerWidget {
  final SkotiqColors colors;
  final FramingState framingState;
  final AsyncValue<FramingEquipmentResult> equipmentAsync;

  const FramingMosaicSection({
    super.key,
    required this.colors,
    required this.framingState,
    required this.equipmentAsync,
  });

  /// Height of one row of the panel list.
  static const double panelRowExtent = 24;

  /// The panel list shows this many rows before it scrolls.
  static const int visiblePanels = 6;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = equipmentAsync.valueOrNull;
    final hasEquipment = result?.isReady ?? false;
    final config = framingState.mosaicConfig;
    final notifier = ref.read(framingProvider.notifier);
    final on = framingState.mosaicEnabled && hasEquipment;

    return FramingPanelSection(
      key: FramingTutorialKeys.mosaicBtn,
      title: 'Mosaic',
      note: on ? '${config.columns}×${config.rows}' : null,
      divider: false,
      actions: [
        Semantics(
          label: 'Plan a mosaic',
          child: SkotiqSwitch(
            value: framingState.mosaicEnabled,
            onChanged: hasEquipment ? notifier.setMosaicEnabled : null,
          ),
        ),
      ],
      children: [
        if (!hasEquipment)
          const FramingNote('Set up equipment to plan a mosaic.'),
        if (on) ...[
          FramingFormRow(
            label: 'Grid',
            // Scales down rather than overflowing in the 250 px column.
            child: Align(
              alignment: Alignment.centerLeft,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SkotiqStepper(
                      value: config.columns,
                      min: 1,
                      max: 10,
                      compact: true,
                      semanticLabel: 'Columns',
                      onChanged: notifier.setMosaicColumns,
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SkotiqTokens.spaceXs,
                      ),
                      child: ExcludeSemantics(
                        child: Text(
                          '×',
                          style: SkotiqTypography.caption
                              .copyWith(color: colors.textMuted),
                        ),
                      ),
                    ),
                    SkotiqStepper(
                      value: config.rows,
                      min: 1,
                      max: 10,
                      compact: true,
                      semanticLabel: 'Rows',
                      onChanged: notifier.setMosaicRows,
                    ),
                  ],
                ),
              ),
            ),
          ),
          FramingFormRow(
            label: 'Overlap',
            child: FramingSlider(
              value: config.overlapPercent,
              min: 0,
              max: 50,
              semanticLabel: 'Panel overlap',
              valueLabel: '${config.overlapPercent.toInt()}%',
              onChanged: notifier.setMosaicOverlap,
            ),
          ),
          FramingFormRow(
            label: 'Order',
            child: NightPanelGrid(
              columns: 2,
              children: [
                NightPanelButton(
                  label: 'Serpentine',
                  selected: config.serpentine,
                  onPressed: notifier.toggleSerpentine,
                ),
                NightPanelButton(
                  label: 'Numbers',
                  semanticLabel: 'Show panel numbers',
                  selected: framingState.showPanelNumbers,
                  onPressed: notifier.togglePanelNumbers,
                ),
              ],
            ),
          ),
          FramingFormRow(
            label: 'Start',
            child: FramingStartCornerSelector(
              selected: config.startCorner,
              onChanged: notifier.setMosaicStartCorner,
            ),
          ),
          if (framingState.mosaicPanels.isNotEmpty) ...[
            const SizedBox(height: SkotiqTokens.spaceXs),
            _panelList(notifier),
            const SizedBox(height: SkotiqTokens.spaceXs),
            // A durable mosaic project (project + per-panel rows), routed to
            // /mosaic/:id so the scheduler/sequencer can drive it.
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

  Widget _panelList(FramingNotifier notifier) {
    final panels = framingState.mosaicPanels;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Row(
          children: [
            SizedBox(width: 28),
            Expanded(child: NightPanelLabel('PANEL CENTER · RA')),
            NightPanelLabel('DEC'),
          ],
        ),
        const SizedBox(height: 2),
        ConstrainedBox(
          constraints: const BoxConstraints(
            maxHeight: panelRowExtent * visiblePanels,
          ),
          child: ListView.builder(
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            itemExtent: panelRowExtent,
            itemCount: panels.length,
            itemBuilder: (context, index) {
              final panel = panels[index];
              final isSelected = index == framingState.selectedPanelIndex;
              final ink =
                  isSelected ? colors.textPrimary : colors.textSecondary;
              return Semantics(
                button: true,
                selected: isSelected,
                label: 'Panel ${panel.index + 1}',
                child: InkWell(
                  onTap: () => notifier.selectPanel(index),
                  borderRadius: SkotiqTokens.borderRadiusInline4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SkotiqTokens.spaceXs,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? colors.primary.withValues(
                              alpha: PanelTabStrip.selectedAlpha,
                            )
                          : null,
                      borderRadius: SkotiqTokens.borderRadiusInline4,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 24,
                          child: Text(
                            '${panel.index + 1}',
                            style: SkotiqTypography.monoXs.copyWith(
                              color: isSelected
                                  ? colors.primary
                                  : colors.textMuted,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            panel.raFormatted,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: SkotiqTypography.monoXs.copyWith(color: ink),
                          ),
                        ),
                        Text(
                          panel.decFormatted,
                          style: SkotiqTypography.monoXs.copyWith(color: ink),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
