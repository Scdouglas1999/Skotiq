// Meridian-flip and polar-alignment instruction property editors.
part of '../node_properties_panel.dart';

class _MeridianFlipProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final MeridianFlipNode node;

  const _MeridianFlipProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Meridian flip settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Trigger method',
          child: NodeDropdown<MeridianTriggerMethod>(
            colors: colors,
            value: node.triggerMethod,
            items: MeridianTriggerMethod.values,
            labelBuilder: (m) {
              switch (m) {
                case MeridianTriggerMethod.minutesPastMeridian:
                  return 'Minutes Past Meridian';
                case MeridianTriggerMethod.minutesBeforeLimit:
                  return 'Minutes Before Limit';
                case MeridianTriggerMethod.hourAngleThreshold:
                  return 'Hour Angle Threshold';
                case MeridianTriggerMethod.onTrackingLimitHit:
                  return 'On Tracking Limit Hit';
              }
            },
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    applyMeridianFlipEdit(node, triggerMethod: value),
                  );
            },
          ),
        ),
        if (node.triggerMethod == MeridianTriggerMethod.minutesPastMeridian)
          NodePropertyField(
            colors: colors,
            label: 'Minutes past meridian',
            child: NodeNumberInput(
              colors: colors,
              value: node.minutesPastMeridian,
              suffix: 'min',
              min: 0,
              max: 60,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      applyMeridianFlipEdit(node, minutesPastMeridian: value),
                    );
              },
            ),
          ),
        if (node.triggerMethod == MeridianTriggerMethod.minutesBeforeLimit)
          NodePropertyField(
            colors: colors,
            label: 'Minutes before limit',
            child: NodeNumberInput(
              colors: colors,
              value: node.minutesBeforeLimit,
              suffix: 'min',
              min: 1,
              max: 60,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      applyMeridianFlipEdit(node, minutesBeforeLimit: value),
                    );
              },
            ),
          ),
        if (node.triggerMethod == MeridianTriggerMethod.hourAngleThreshold)
          NodePropertyField(
            colors: colors,
            label: 'Hour angle threshold',
            child: NodeNumberInput(
              colors: colors,
              value: node.hourAngleThreshold,
              suffix: 'h',
              min: 0.0,
              max: 6.0,
              decimals: 2,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      applyMeridianFlipEdit(node, hourAngleThreshold: value),
                    );
              },
            ),
          ),
        if (node.triggerMethod == MeridianTriggerMethod.onTrackingLimitHit)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: SkotiqDecorations.tintedBadge(
                colors.info,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusInline8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(LucideIcons.info, size: 14, color: colors.info),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Flip is triggered when the mount reports it has reached '
                      'its tracking / meridian limit — no threshold needed.',
                      style: TextStyle(
                        fontSize: Responsive.fontSize(context, 12),
                        color: colors.info,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        NodeSectionHeader(colors: colors, label: 'Flip sequence'),
        const SizedBox(height: 8),
        NodePropertyField(
          colors: colors,
          label: 'Pause guiding',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.pauseGuiding,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    applyMeridianFlipEdit(node, pauseGuiding: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Auto center after flip',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.autoCenter,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    applyMeridianFlipEdit(node, autoCenter: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Refocus after flip',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.refocusAfter,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    applyMeridianFlipEdit(node, refocusAfter: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Resume guiding',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.resumeGuiding,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    applyMeridianFlipEdit(node, resumeGuiding: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Settle time',
          helpText:
              'How long to wait after the flip for the mount to mechanically '
              'settle before resuming guiding/imaging.',
          child: NodeNumberInput(
            colors: colors,
            value: node.settleTime,
            suffix: 's',
            min: 0,
            max: 120,
            decimals: 0,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    applyMeridianFlipEdit(node, settleTime: value),
                  );
            },
          ),
        ),
        const SizedBox(height: 8),
        NodeSectionHeader(colors: colors, label: 'Error handling'),
        const SizedBox(height: 8),
        NodePropertyField(
          colors: colors,
          label: 'Max retries',
          child: NodeNumberInput(
            colors: colors,
            value: node.maxRetries.toDouble(),
            min: 0,
            max: 10,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    applyMeridianFlipEdit(node, maxRetries: value.toInt()),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Failure action',
          child: NodeDropdown<FlipFailureAction>(
            colors: colors,
            value: node.failureAction,
            items: FlipFailureAction.values,
            labelBuilder: (a) {
              switch (a) {
                case FlipFailureAction.pauseAndAlert:
                  return 'Pause & Alert';
                case FlipFailureAction.abortAndPark:
                  return 'Abort & Park';
              }
            },
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    applyMeridianFlipEdit(node, failureAction: value),
                  );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: SkotiqDecorations.tintedBadge(
            colors.info,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.info, size: 14, color: colors.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Performs pier flip when target crosses meridian. Pauses guiding, flips, then optionally re-centers and refocuses.',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 12),
                    color: colors.info,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PolarAlignmentProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final PolarAlignmentNode node;

  const _PolarAlignmentProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Polar alignment settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Hemisphere',
          child: NodeDropdown<bool>(
            colors: colors,
            value: node.isNorth,
            items: const [true, false],
            labelBuilder: (v) => v ? 'Northern' : 'Southern',
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(isNorth: value),
                  );
            },
          ),
        ),
        Row(
          children: [
            Expanded(
              child: NodePropertyField(
                colors: colors,
                label: 'Exposure duration',
                child: NodeNumberInput(
                  colors: colors,
                  value: node.exposureDuration,
                  suffix: 's',
                  min: 0.5,
                  max: 30,
                  decimals: 1,
                  onChanged: (value) {
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(exposureDuration: value),
                        );
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: NodePropertyField(
                colors: colors,
                label: 'Binning',
                child: NodeNumberInput(
                  colors: colors,
                  value: node.binning.toDouble(),
                  min: 1,
                  max: 4,
                  onChanged: (value) {
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(binning: value.toInt()),
                        );
                  },
                ),
              ),
            ),
          ],
        ),
        NodePropertyField(
          colors: colors,
          label: 'Start altitude',
          child: NodeNumberInput(
            colors: colors,
            value: node.startAltitude,
            suffix: '\u00B0',
            min: 20,
            max: 80,
            decimals: 0,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(startAltitude: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Rotation step',
          child: NodeNumberInput(
            colors: colors,
            value: node.rotationStep,
            suffix: '\u00B0',
            min: 10,
            max: 45,
            decimals: 0,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(rotationStep: value),
                  );
            },
          ),
        ),
        Row(
          children: [
            Expanded(
              child: NodePropertyField(
                colors: colors,
                label: 'Gain',
                child: NodeNumberInput(
                  colors: colors,
                  // An unset gain rides to `PolarAlignConfig.gain = None`, and
                  // `camera_start_exposure` then leaves the camera on whatever
                  // gain it already holds. The field can only show a number, so
                  // the helper line says which of the two "0" means instead of
                  // letting the panel claim a gain the node does not carry.
                  value: (node.gain ?? 0).toDouble(),
                  min: 0,
                  max: 1000,
                  helperText: node.gain == null
                      ? 'Unset — the camera keeps its current gain'
                      : null,
                  onChanged: (value) {
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(gain: value.toInt()),
                        );
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: NodePropertyField(
                colors: colors,
                label: 'Offset',
                child: NodeNumberInput(
                  colors: colors,
                  // Same contract as Gain above: null means "do not set it".
                  value: (node.offset ?? 0).toDouble(),
                  min: 0,
                  max: 1000,
                  helperText: node.offset == null
                      ? 'Unset — the camera keeps its current offset'
                      : null,
                  onChanged: (value) {
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(offset: value.toInt()),
                        );
                  },
                ),
              ),
            ),
          ],
        ),
        NodePropertyField(
          colors: colors,
          label: 'Start from current position',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.startFromCurrent,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(startFromCurrent: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Manual slew mode',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.manualSlew,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(manualSlew: value),
                  );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: SkotiqDecorations.tintedBadge(
            colors.info,
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.compass, size: 14, color: colors.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Three-point polar alignment using plate solving. Calculates polar error and guides adjustments.',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 12),
                    color: colors.info,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
