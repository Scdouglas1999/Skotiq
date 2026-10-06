// Properties widgets for flow-control nodes: target group, loop, delay, wait-time, conditional, parallel, recovery.
part of '../node_properties_panel.dart';

class _LoopProperties extends ConsumerWidget {
  final NightshadeColors colors;
  final LoopNode node;

  const _LoopProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Loop settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Condition type',
          child: NodeDropdown<LoopConditionType>(
            colors: colors,
            value: node.conditionType,
            items: LoopConditionType.values,
            labelBuilder: (t) {
              switch (t) {
                case LoopConditionType.count:
                  return 'Fixed Count';
                case LoopConditionType.untilTime:
                  return 'Until Time';
                case LoopConditionType.untilAltitude:
                  return 'Until Altitude';
                case LoopConditionType.altitudeAbove:
                  return 'Altitude Above';
                case LoopConditionType.integrationTime:
                  return 'Integration Time';
                case LoopConditionType.forever:
                  return 'Forever';
                case LoopConditionType.whileDark:
                  return 'While Dark';
              }
            },
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(conditionType: value),
                  );
            },
          ),
        ),
        if (node.conditionType == LoopConditionType.count)
          NodePropertyField(
            colors: colors,
            label: 'Repeat count',
            child: NodeNumberInput(
              colors: colors,
              value: (node.repeatCount ?? 1).toDouble(),
              min: 1,
              max: 9999,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(repeatCount: value.toInt()),
                    );
              },
            ),
          ),
        if (node.conditionType == LoopConditionType.untilTime)
          NodePropertyField(
            colors: colors,
            label: 'Stop time',
            child: Column(
              children: [
                GestureDetector(
                  onTap: () async {
                    final time = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay.fromDateTime(
                          node.repeatUntil ?? DateTime.now()),
                    );
                    if (time != null) {
                      final now = DateTime.now();
                      var targetDate = DateTime(
                          now.year, now.month, now.day, time.hour, time.minute);
                      if (targetDate.isBefore(now)) {
                        targetDate = targetDate.add(const Duration(days: 1));
                      }
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(repeatUntil: targetDate),
                          );
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: colors.surfaceAlt,
                      borderRadius:
                          BorderRadius.circular(NightshadeTokens.radiusInline8),
                      border: Border.all(color: colors.border),
                    ),
                    child: Row(
                      children: [
                        Icon(LucideIcons.clock,
                            size: 14, color: colors.textMuted),
                        const SizedBox(width: 8),
                        Text(
                          node.repeatUntil != null
                              ? '${node.repeatUntil!.hour.toString().padLeft(2, '0')}:${node.repeatUntil!.minute.toString().padLeft(2, '0')}'
                              : 'Select time...',
                          style: TextStyle(
                            fontSize: NightshadeTypography.fontSize13,
                            color: node.repeatUntil != null
                                ? colors.textPrimary
                                : colors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Quick set buttons for common times
                Row(
                  children: [
                    NodeQuickTimeButton(
                      colors: colors,
                      label: 'Civil dawn',
                      onPressed: () {
                        // Twilight is a property of a place. With no site on
                        // record there is no dawn to set the wait against.
                        final site = ref.read(observerLocationProvider).site;
                        if (site == null) return;
                        final now = DateTime.now();

                        // Calculate for today first
                        var twilight =
                            AstronomyCalculations.calculateTwilightTimes(
                          date: now,
                          latitudeDeg: site.latitude,
                          longitudeDeg: site.longitude,
                        );

                        var target = twilight.civilDawn;

                        // If dawn passed or not available today, try tomorrow
                        if (target == null || target.isBefore(now)) {
                          twilight =
                              AstronomyCalculations.calculateTwilightTimes(
                            date: now.add(const Duration(days: 1)),
                            latitudeDeg: site.latitude,
                            longitudeDeg: site.longitude,
                          );
                          target = twilight.civilDawn;
                        }

                        if (target != null) {
                          ref.read(currentSequenceProvider.notifier).updateNode(
                                node.copyWith(repeatUntil: target),
                              );
                        }
                      },
                    ),
                    const SizedBox(width: 8),
                    NodeQuickTimeButton(
                      colors: colors,
                      label: 'Nautical dawn',
                      onPressed: () {
                        // Twilight is a property of a place. With no site on
                        // record there is no dawn to set the wait against.
                        final site = ref.read(observerLocationProvider).site;
                        if (site == null) return;
                        final now = DateTime.now();

                        // Calculate for today first
                        var twilight =
                            AstronomyCalculations.calculateTwilightTimes(
                          date: now,
                          latitudeDeg: site.latitude,
                          longitudeDeg: site.longitude,
                        );

                        var target = twilight.nauticalDawn;

                        // If dawn passed or not available today, try tomorrow
                        if (target == null || target.isBefore(now)) {
                          twilight =
                              AstronomyCalculations.calculateTwilightTimes(
                            date: now.add(const Duration(days: 1)),
                            latitudeDeg: site.latitude,
                            longitudeDeg: site.longitude,
                          );
                          target = twilight.nauticalDawn;
                        }

                        if (target != null) {
                          ref.read(currentSequenceProvider.notifier).updateNode(
                                node.copyWith(repeatUntil: target),
                              );
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (node.conditionType == LoopConditionType.untilAltitude)
          NodePropertyField(
            colors: colors,
            label: 'Stop below altitude',
            child: NodeNumberInput(
              colors: colors,
              value: node.repeatUntilAltitude ?? 30,
              suffix: '°',
              min: 0,
              max: 90,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(repeatUntilAltitude: value),
                    );
              },
            ),
          ),
        // AltitudeAbove keeps looping WHILE the target is below the
        // threshold, stopping once it climbs above it. Shares the
        // `repeatUntilAltitude` field with UntilAltitude (the Rust
        // serializer maps both modes onto `condition_value`).
        if (node.conditionType == LoopConditionType.altitudeAbove)
          NodePropertyField(
            colors: colors,
            label: 'Stop above altitude',
            child: NodeNumberInput(
              colors: colors,
              value: node.repeatUntilAltitude ?? 30,
              suffix: '°',
              min: 0,
              max: 90,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(repeatUntilAltitude: value),
                    );
              },
            ),
          ),
        // IntegrationTime loops until the accumulated accepted-frame
        // integration reaches the target. Stored in
        // `integrationTimeTarget` (seconds) and serialized to the
        // engine's `condition_value`.
        if (node.conditionType == LoopConditionType.integrationTime)
          NodePropertyField(
            colors: colors,
            label: 'Target integration',
            child: NodeNumberInput(
              colors: colors,
              value: (node.integrationTimeTarget ?? 3600) / 60.0,
              suffix: 'min',
              min: 1,
              max: 1440,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(integrationTimeTarget: value * 60.0),
                    );
              },
            ),
          ),
      ],
    );
  }
}

class _DelayProperties extends ConsumerWidget {
  final NightshadeColors colors;
  final DelayNode node;

  const _DelayProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Delay settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Duration',
          child: NodeNumberInput(
            colors: colors,
            value: node.seconds,
            suffix: 's',
            min: 0.1,
            max: 3600,
            decimals: 1,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(seconds: value),
                  );
            },
          ),
        ),
        if (node.seconds > _kLongDelayWarnSecs)
          _LongValueWarning(
            colors: colors,
            message:
                'This is an unusually long delay — confirm this is intentional.',
          ),
      ],
    );
  }
}

class _WaitTimeProperties extends ConsumerWidget {
  final NightshadeColors colors;
  final WaitTimeNode node;

  const _WaitTimeProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Wait settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Wait for',
          child: NodeDropdown<String>(
            colors: colors,
            value: node.waitForTwilight != null ? 'twilight' : 'time',
            items: const ['time', 'twilight'],
            labelBuilder: (v) => v == 'time' ? 'Specific Time' : 'Twilight',
            onChanged: (value) {
              if (value == 'twilight') {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(
                          waitForTwilight: TwilightType.astronomical,
                          waitUntil: null),
                    );
              } else {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(clearWaitForTwilight: true),
                    );
              }
            },
          ),
        ),
        if (node.waitForTwilight != null) ...[
          NodePropertyField(
            colors: colors,
            label: 'Twilight type',
            child: NodeDropdown<TwilightType>(
              colors: colors,
              value: node.waitForTwilight!,
              items: TwilightType.values,
              labelBuilder: (t) {
                switch (t) {
                  case TwilightType.civil:
                    return 'Civil (-6°)';
                  case TwilightType.nautical:
                    return 'Nautical (-12°)';
                  case TwilightType.astronomical:
                    return 'Astronomical (-18°)';
                }
              },
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(waitForTwilight: value),
                    );
              },
            ),
          ),
        ],
        if (node.waitForTwilight == null) ...[
          NodePropertyField(
            colors: colors,
            label: 'Wait until',
            child: GestureDetector(
              onTap: () async {
                final time = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay.now(),
                );
                if (time != null) {
                  final now = DateTime.now();
                  var targetDate = DateTime(
                      now.year, now.month, now.day, time.hour, time.minute);
                  if (targetDate.isBefore(now)) {
                    targetDate = targetDate.add(const Duration(days: 1));
                  }
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        node.copyWith(waitUntil: targetDate),
                      );
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: colors.surfaceAlt,
                  borderRadius:
                      BorderRadius.circular(NightshadeTokens.radiusInline8),
                  border: Border.all(color: colors.border),
                ),
                child: Row(
                  children: [
                    Icon(LucideIcons.clock, size: 14, color: colors.textMuted),
                    const SizedBox(width: 8),
                    Text(
                      node.waitUntil != null
                          ? '${node.waitUntil!.hour.toString().padLeft(2, '0')}:${node.waitUntil!.minute.toString().padLeft(2, '0')}'
                          : 'Select time...',
                      style: TextStyle(
                        fontSize: NightshadeTypography.fontSize13,
                        color: node.waitUntil != null
                            ? colors.textPrimary
                            : colors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

class _ConditionalProperties extends ConsumerWidget {
  final NightshadeColors colors;
  final ConditionalNode node;

  const _ConditionalProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Condition settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Condition type',
          child: NodeDropdown<ConditionalType>(
            colors: colors,
            value: node.conditionType,
            items: ConditionalType.values,
            labelBuilder: (t) {
              switch (t) {
                case ConditionalType.always:
                  return 'Always Execute';
                case ConditionalType.altitudeAbove:
                  return 'Altitude Above';
                case ConditionalType.timeAfter:
                  return 'Time After';
                case ConditionalType.guidingRmsBelow:
                  return 'Guiding RMS Below';
                case ConditionalType.hfrBelow:
                  return 'HFR Below';
                case ConditionalType.weatherSafe:
                  return 'Weather is Safe';
                case ConditionalType.moonSeparationAbove:
                  return 'Moon Separation Above';
                case ConditionalType.safetyMonitorSafe:
                  return 'Safety Monitor Safe';
              }
            },
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(conditionType: value),
                  );
            },
          ),
        ),
        if (node.conditionType == ConditionalType.altitudeAbove ||
            node.conditionType == ConditionalType.moonSeparationAbove)
          NodePropertyField(
            colors: colors,
            label: 'Threshold (degrees)',
            child: NodeNumberInput(
              colors: colors,
              value: node.thresholdValue ?? 30,
              suffix: '°',
              min: 0,
              max: 90,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(thresholdValue: value),
                    );
              },
            ),
          ),
        if (node.conditionType == ConditionalType.guidingRmsBelow)
          NodePropertyField(
            colors: colors,
            label: 'Max RMS (arcsec)',
            child: NodeNumberInput(
              colors: colors,
              value: node.thresholdValue ?? 1.5,
              suffix: '"',
              min: 0.1,
              max: 10,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(thresholdValue: value),
                    );
              },
            ),
          ),
        if (node.conditionType == ConditionalType.hfrBelow)
          NodePropertyField(
            colors: colors,
            label: 'Max HFR (pixels)',
            child: NodeNumberInput(
              colors: colors,
              value: node.thresholdValue ?? 3.0,
              suffix: 'px',
              min: 0.5,
              max: 20,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(thresholdValue: value),
                    );
              },
            ),
          ),
        // Audit C2 — multi-safety-monitor targeting. When more than one
        // safety monitor is configured the user can pin this conditional
        // to a specific monitor; the default (null) consults the
        // aggregated / profile-default safety state.
        if (node.conditionType == ConditionalType.safetyMonitorSafe)
          _SafetyMonitorPicker(colors: colors, node: node),
      ],
    );
  }
}

/// Audit C2 — safety-monitor selector for a SafetyMonitorSafe conditional.
///
/// Lists every discovered safety monitor by display name plus an
/// "Aggregated (all monitors)" option that maps to `safetyMonitorId == null`.
/// Selecting the aggregated option must CLEAR the id, but
/// [ConditionalNode.copyWith] uses plain `?? this.safetyMonitorId`
/// keep-or-replace semantics, so we rebuild a fresh node to null it out.
class _SafetyMonitorPicker extends ConsumerWidget {
  final NightshadeColors colors;
  final ConditionalNode node;

  const _SafetyMonitorPicker({required this.colors, required this.node});

  static const String _aggregatedSentinel = '__aggregated__';

  void _setMonitor(WidgetRef ref, String? monitorId) {
    final notifier = ref.read(currentSequenceProvider.notifier);
    if (monitorId == null) {
      // Rebuild to clear — copyWith can't null the field.
      notifier.updateNode(
        ConditionalNode(
          id: node.id,
          name: node.name,
          isEnabled: node.isEnabled,
          childIds: node.childIds,
          parentId: node.parentId,
          orderIndex: node.orderIndex,
          comment: node.comment,
          conditionType: node.conditionType,
          thresholdValue: node.thresholdValue,
          thresholdTime: node.thresholdTime,
        ),
      );
    } else {
      notifier.updateNode(node.copyWith(safetyMonitorId: monitorId));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final monitors = ref.watch(unifiedSafetyMonitorsProvider);

    // Build the option list: aggregated sentinel first, then one entry per
    // discovered monitor keyed by its active device id.
    final options = <({String key, String label})>[
      (key: _aggregatedSentinel, label: 'Aggregated (all monitors)'),
      for (final m in monitors) (key: m.activeDeviceId, label: m.displayName),
    ];

    // If the node references a monitor that's no longer discovered (e.g. it
    // was unplugged or the sequence was built on another rig), keep it
    // visible so the user sees what is configured rather than silently
    // snapping to aggregated.
    final currentId = node.safetyMonitorId;
    if (currentId != null && !options.any((o) => o.key == currentId)) {
      options.add((key: currentId, label: '$currentId (not connected)'));
    }

    final selectedKey = currentId ?? _aggregatedSentinel;

    return NodePropertyField(
      colors: colors,
      label: 'Safety monitor',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: colors.surfaceAlt,
          borderRadius: BorderRadius.circular(NightshadeTokens.radiusInline8),
          border: Border.all(color: colors.border),
        ),
        child: DropdownButtonHideUnderline(
          child: AccessibleDropdown<String>(
            value: selectedKey,
            isExpanded: true,
            icon: Icon(
              LucideIcons.chevronDown,
              size: 16,
              color: colors.textMuted,
            ),
            dropdownColor: colors.surface,
            style: TextStyle(
                fontSize: NightshadeTypography.fontSize13,
                color: colors.textPrimary),
            items: options
                .map((o) => DropdownMenuItem(
                      value: o.key,
                      child: Text(o.label),
                    ))
                .toList(),
            onChanged: (newKey) {
              if (newKey == null) return;
              _setMonitor(
                ref,
                newKey == _aggregatedSentinel ? null : newKey,
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ParallelProperties extends ConsumerWidget {
  final NightshadeColors colors;
  final ParallelNode node;

  const _ParallelProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Parallel execution'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Required successes',
          child: NodeNumberInput(
            colors: colors,
            value: (node.requiredSuccesses ?? 1).toDouble(),
            min: 1,
            max: 10,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(requiredSuccesses: value.toInt()),
                  );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.info.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(NightshadeTokens.radiusInline8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.info, size: 14, color: colors.info),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'All child nodes will execute simultaneously. Node succeeds when required number of children complete.',
                  style: TextStyle(
                    fontSize: NightshadeTypography.fontSize11,
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

class _RecoveryProperties extends ConsumerWidget {
  final NightshadeColors colors;
  final RecoveryNode node;

  const _RecoveryProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Recovery settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Trigger type',
          child: NodeDropdown<TriggerType?>(
            colors: colors,
            value: node.triggerType,
            items: const [null, ...TriggerType.values],
            labelBuilder: (t) {
              if (t == null) return 'Any Error';
              switch (t) {
                case TriggerType.hfrDegraded:
                  return 'HFR Degraded';
                case TriggerType.meridianFlip:
                  return 'Meridian Flip Needed';
                case TriggerType.guidingFailed:
                  return 'Guiding Failed';
                case TriggerType.altitudeLimit:
                  return 'Altitude Limit';
                case TriggerType.weatherUnsafe:
                  return 'Weather Unsafe';
                case TriggerType.temperatureShift:
                  return 'Temperature Shift';
                case TriggerType.filterChange:
                  return 'Filter Change';
                case TriggerType.dawnApproaching:
                  return 'Dawn Approaching';
                case TriggerType.humidityThreshold:
                  return 'Humidity Threshold';
                case TriggerType.focusDrift:
                  return 'Focus Drift';
                case TriggerType.mountTrackingLost:
                  return 'Mount Tracking Lost';
                case TriggerType.domeShutterNotOpen:
                  return 'Dome Shutter Not Open';
                case TriggerType.guideStarLost:
                  return 'Guide Star Lost';
                case TriggerType.autofocusInterval:
                  return 'Autofocus Interval';
                case TriggerType.ditherInterval:
                  return 'Dither Interval';
                case TriggerType.driftLimit:
                  return 'Drift Limit';
                case TriggerType.cloudArrivingIn:
                  return 'Cloud Arriving In';
                case TriggerType.cloudOpeningIn:
                  return 'Cloud Opening In';
                case TriggerType.cloudCoverThreshold:
                  return 'Cloud Cover Threshold';
                case TriggerType.transparencyDropped:
                  return 'Transparency Dropped';
              }
            },
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.withTriggerType(value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Recovery action',
          child: NodeDropdown<RecoveryActionType>(
            colors: colors,
            value: node.recoveryAction,
            items: RecoveryActionType.values,
            labelBuilder: (a) {
              switch (a) {
                case RecoveryActionType.continueExecution:
                  return 'Continue';
                case RecoveryActionType.pause:
                  return 'Pause Sequence';
                case RecoveryActionType.autofocus:
                  return 'Run Autofocus';
                case RecoveryActionType.nextTarget:
                  return 'Skip to Next Target';
                case RecoveryActionType.retry:
                  return 'Retry Operation';
                case RecoveryActionType.parkAndAbort:
                  return 'Park & Abort';
                case RecoveryActionType.customBranch:
                  return 'Custom Branch';
                case RecoveryActionType.pauseAndWaitForClear:
                  return 'Pause and Wait for Clear';
                case RecoveryActionType.slewToGapAndContinue:
                  return 'Slew to Gap and Continue';
                case RecoveryActionType.switchTargetOrFilter:
                  return 'Switch Target or Filter';
                case RecoveryActionType.notify:
                  return 'Notify me and keep imaging';
              }
            },
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(recoveryAction: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Max retries',
          child: NodeNumberInput(
            colors: colors,
            value: node.maxRetries.toDouble(),
            min: 1,
            max: 10,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(maxRetries: value.toInt()),
                  );
            },
          ),
        ),
        if (node.triggerType == TriggerType.hfrDegraded)
          NodePropertyField(
            colors: colors,
            label: 'HFR threshold',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerThreshold ?? 4.0,
              suffix: 'px',
              min: 1,
              max: 20,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(triggerThreshold: value),
                    );
              },
            ),
          ),
        if (node.triggerType == TriggerType.altitudeLimit)
          NodePropertyField(
            colors: colors,
            label: 'Min altitude',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerThreshold ?? 30,
              suffix: '°',
              min: 0,
              max: 90,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(triggerThreshold: value),
                    );
              },
            ),
          ),
      ],
    );
  }
}
