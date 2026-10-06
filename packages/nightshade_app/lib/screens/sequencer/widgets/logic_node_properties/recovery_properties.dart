part of '../logic_node_properties.dart';

class RecoveryProperties extends ConsumerWidget {
  final NightshadeColors colors;
  final RecoveryNode node;

  const RecoveryProperties(
      {super.key, required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recovery Settings',
          style: TextStyle(
            fontSize: Responsive.fontSize(context, 13),
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
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
                // Additional trigger types
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
                  return 'Plate-Solve Drift Limit';
                // Cloud-motion-aware triggers
                case TriggerType.cloudArrivingIn:
                  return 'Cloud Arriving In';
                case TriggerType.cloudOpeningIn:
                  return 'Cloud Opening In';
                case TriggerType.cloudCoverThreshold:
                  return 'Cloud Cover Threshold';
                // Transparency-adaptive sequencing
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
            items: _selectableRecoveryActions(node.recoveryAction),
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
                // Cloud-motion-aware actions
                case RecoveryActionType.pauseAndWaitForClear:
                  return 'Pause & Wait for Clear Sky';
                case RecoveryActionType.slewToGapAndContinue:
                  return 'Slew to Clear Gap & Continue';
                // Transparency-adaptive recovery
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
          label: 'Additional retries',
          helpText: 'Retries after the first attempt. Total executions are '
              '1 + additional retries.',
          child: NodeNumberInput(
            colors: colors,
            value: node.maxRetries.toDouble(),
            min: 0,
            max: 10,
            helperText: 'Total executions: ${node.maxRetries + 1}',
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(maxRetries: value.toInt()),
                  );
            },
          ),
        ),
        if (node.triggerType == TriggerType.hfrDegraded) ...[
          NodePropertyField(
            colors: colors,
            label: 'Absolute HFR Threshold',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerThreshold ?? 0.0,
              suffix: 'px',
              min: 0,
              max: 20,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(triggerThreshold: value),
                    );
              },
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: '% Above Baseline',
            child: NodeNumberInput(
              colors: colors,
              value: node.hfrThresholdPercent,
              suffix: '%',
              min: 0,
              max: 100,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(hfrThresholdPercent: value),
                    );
              },
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Consecutive frames',
            child: NodeNumberInput(
              colors: colors,
              value: node.hfrConsecutiveFrames.toDouble(),
              suffix: '',
              min: 1,
              max: 20,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(hfrConsecutiveFrames: value.toInt()),
                    );
              },
            ),
          ),
        ],
        if (node.triggerType == TriggerType.altitudeLimit)
          NodePropertyField(
            colors: colors,
            label: 'Min altitude',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerThreshold ?? 30,
              suffix: '\u00B0',
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
        // Trigger config editors
        if (node.triggerType == TriggerType.humidityThreshold)
          NodePropertyField(
            colors: colors,
            label: 'Max humidity',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerThreshold ?? 85,
              suffix: '%',
              min: 0,
              max: 100,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(triggerThreshold: value),
                    );
              },
            ),
          ),
        if (node.triggerType == TriggerType.focusDrift) ...[
          NodePropertyField(
            colors: colors,
            label: 'Window Size (frames)',
            child: NodeNumberInput(
              colors: colors,
              value: node.focusDriftWindowSize.toDouble(),
              suffix: 'frames',
              min: 2,
              // Mirror Rust's FOCUS_DRIFT_WINDOW_MAX clamp (100) so the
              // executor doesn't have to surface a clamp-warning event.
              max: 100,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(focusDriftWindowSize: value.toInt()),
                    );
              },
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Min Increasing Count',
            child: NodeNumberInput(
              colors: colors,
              value: node.focusDriftMinIncreasingCount.toDouble(),
              suffix: 'frames',
              min: 2,
              max: 100,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(
                          focusDriftMinIncreasingCount: value.toInt()),
                    );
              },
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Min Total Increase',
            child: NodeNumberInput(
              colors: colors,
              value: node.focusDriftMinTotalIncrease,
              suffix: 'px',
              min: 0.1,
              max: 10.0,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(focusDriftMinTotalIncrease: value),
                    );
              },
            ),
          ),
        ],
        if (node.triggerType == TriggerType.guidingFailed) ...[
          NodePropertyField(
            colors: colors,
            label: 'RMS Threshold',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerThreshold ?? 2.0,
              suffix: '"',
              min: 0.1,
              max: 20.0,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(triggerThreshold: value),
                    );
              },
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Duration',
            child: NodeNumberInput(
              colors: colors,
              value: node.guidingFailedDurationSecs,
              suffix: 'seconds',
              min: 1,
              max: 600,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(guidingFailedDurationSecs: value),
                    );
              },
            ),
          ),
        ],
        if (node.triggerType == TriggerType.temperatureShift)
          NodePropertyField(
            colors: colors,
            label: 'Temperature change',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerThreshold ?? 2.0,
              suffix: '\u00B0C',
              min: 0.1,
              max: 20.0,
              decimals: 1,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(triggerThreshold: value),
                    );
              },
            ),
          ),
        if (node.triggerType == TriggerType.dawnApproaching)
          NodePropertyField(
            colors: colors,
            label: 'Minutes Before Twilight',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerThreshold ?? 30,
              suffix: 'min',
              min: 1,
              max: 240,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(triggerThreshold: value),
                    );
              },
            ),
          ),
        if (node.triggerType == TriggerType.autofocusInterval ||
            node.triggerType == TriggerType.ditherInterval)
          NodePropertyField(
            colors: colors,
            label: 'Every N Frames',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerEveryNFrames.toDouble(),
              suffix: 'frames',
              min: 1,
              max: 9999,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(triggerEveryNFrames: value.toInt()),
                    );
              },
            ),
          ),
        if (node.triggerType == TriggerType.driftLimit)
          NodePropertyField(
            colors: colors,
            label: 'Max drift',
            child: NodeNumberInput(
              colors: colors,
              value: node.triggerThreshold ?? 30,
              suffix: 'px',
              min: 1,
              max: 500,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(triggerThreshold: value),
                    );
              },
            ),
          ),
        // Cloud-motion trigger property editors.
        if (node.triggerType == TriggerType.cloudArrivingIn) ...[
          NodePropertyField(
            colors: colors,
            label: 'Minutes Before Arrival',
            child: NodeNumberInput(
              colors: colors,
              value: node.cloudMinutesBefore,
              suffix: 'min',
              min: 1,
              max: 240,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(cloudMinutesBefore: value),
                    );
              },
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Min Predicted Coverage',
            child: NodeNumberInput(
              colors: colors,
              value: node.cloudCoverageThresholdPercent,
              suffix: '%',
              min: 0,
              max: 100,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(cloudCoverageThresholdPercent: value),
                    );
              },
            ),
          ),
        ],
        if (node.triggerType == TriggerType.cloudOpeningIn) ...[
          NodePropertyField(
            colors: colors,
            label: 'Minutes Before Opening',
            child: NodeNumberInput(
              colors: colors,
              value: node.cloudMinutesBefore,
              suffix: 'min',
              min: 1,
              max: 240,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(cloudMinutesBefore: value),
                    );
              },
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Minimum Opening Duration',
            child: NodeNumberInput(
              colors: colors,
              value: node.cloudOpeningMinDurationSecs,
              suffix: 's',
              min: 1,
              max: 3600,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(cloudOpeningMinDurationSecs: value),
                    );
              },
            ),
          ),
        ],
        if (node.triggerType == TriggerType.cloudCoverThreshold) ...[
          NodePropertyField(
            colors: colors,
            label: 'Max Cloud Cover',
            child: NodeNumberInput(
              colors: colors,
              value: node.cloudCoverMaxPercent,
              suffix: '%',
              min: 0,
              max: 100,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(cloudCoverMaxPercent: value),
                    );
              },
            ),
          ),
          NodePropertyField(
            colors: colors,
            label: 'Above for at least',
            child: NodeNumberInput(
              colors: colors,
              value: node.cloudCoverDurationSecs,
              suffix: 's',
              min: 0,
              max: 3600,
              decimals: 0,
              onChanged: (value) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      node.copyWith(cloudCoverDurationSecs: value),
                    );
              },
            ),
          ),
        ],
      ],
    );
  }
}

List<RecoveryActionType> _selectableRecoveryActions(
  RecoveryActionType current,
) {
  return RecoveryActionType.values;
}
