// Part of ../node_properties_panel.dart -- migrated from the former
// instruction_node_properties library. Richer
// mount/optics motion editors: Center (custom-coords + solve params),
// Autofocus (settings-defaults display + per-node overrides), Rotator,
// Slew (custom-coords + target-resolution preview), Meridian Flip, and
// Polar Alignment.
part of '../node_properties_panel.dart';

class _CenterProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final CenterNode node;

  const _CenterProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Centering settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Use target coordinates',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.useTargetCoords,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(useTargetCoords: value),
                  );
            },
          ),
        ),
        if (!node.useTargetCoords) ...[
          Row(
            children: [
              Expanded(
                child: NodePropertyField(
                  colors: colors,
                  label: 'Custom RA (hours)',
                  child: NodeNumberInput(
                    colors: colors,
                    value: node.customRa ?? 0,
                    suffix: 'h',
                    min: 0,
                    max: 24,
                    decimals: 4,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(customRa: value),
                          );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NodePropertyField(
                  colors: colors,
                  label: 'Custom Dec (deg)',
                  child: NodeNumberInput(
                    colors: colors,
                    value: node.customDec ?? 0,
                    suffix: '\u00B0',
                    min: -90,
                    max: 90,
                    decimals: 4,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(customDec: value),
                          );
                    },
                  ),
                ),
              ),
            ],
          ),
          _CoordinateReadout(
            colors: colors,
            raHours: node.customRa ?? 0,
            decDeg: node.customDec ?? 0,
          ),
        ],
        if (node.useTargetCoords)
          _TargetResolutionPreview(colors: colors, nodeId: node.id),
        NodePropertyField(
          colors: colors,
          label: 'Accuracy',
          helpText:
              'How close the plate-solve centre must land to the target before '
              'centering is considered done. Smaller = tighter framing but more '
              'solve/slew iterations.',
          child: NodeNumberInput(
            colors: colors,
            value: node.accuracyArcsec,
            suffix: '"',
            min: 0.1,
            max: 60,
            decimals: 1,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(accuracyArcsec: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Max attempts',
          child: NodeNumberInput(
            colors: colors,
            value: node.maxAttempts.toDouble(),
            min: 1,
            max: 20,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(maxAttempts: value.toInt()),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Solve exposure',
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
        NodePropertyField(
          colors: colors,
          label: 'Solve filter',
          child: NodeTextInput(
            colors: colors,
            value: node.filter ?? '',
            hint: 'Current filter',
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    value.isEmpty
                        ? node.copyWith(clearFilter: true)
                        : node.copyWith(filter: value),
                  );
            },
          ),
        ),
      ],
    );
  }
}

class _AutofocusProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final AutofocusNode node;

  const _AutofocusProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final afSettings = ref.watch(autofocusSettingsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Autofocus settings'),
        const SizedBox(height: 12),
        // Use Settings Defaults toggle
        NodePropertyField(
          colors: colors,
          label: 'Use settings defaults',
          child: Row(
            children: [
              NodeToggleSwitch(
                colors: colors,
                value: node.useSettingsDefaults,
                onChanged: (value) {
                  ref.read(currentSequenceProvider.notifier).updateNode(
                        node.copyWith(useSettingsDefaults: value),
                      );
                },
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.useSettingsDefaults
                      ? 'Using global AF settings'
                      : 'Using node overrides',
                  style: TextStyle(
                    fontSize: Responsive.fontSize(context, 11),
                    color: colors.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (node.useSettingsDefaults)
          // Read-only display of current global AF settings
          _buildDefaultsDisplay(context, afSettings)
        else
          // Editable per-node overrides
          _buildEditableFields(ref),

        const SizedBox(height: 8),
        // Max Duration is always node-specific (not from global settings)
        NodePropertyField(
          colors: colors,
          label: 'Max duration',
          child: NodeNumberInput(
            colors: colors,
            value: node.maxDurationSecs,
            suffix: 's',
            min: 30,
            max: 3600,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(maxDurationSecs: value),
                  );
            },
          ),
        ),
        Text(
          'Autofocus will abort if it exceeds this duration (${(node.maxDurationSecs / 60).toStringAsFixed(0)} min)',
          style: TextStyle(
            fontSize: Responsive.fontSize(context, 11),
            color: colors.textMuted,
          ),
        ),
      ],
    );
  }

  /// Displays the persisted global AF settings as read-only informational rows.
  Widget _buildDefaultsDisplay(
      BuildContext context, AutofocusSettings afSettings) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: colors.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Global settings (edit in Settings > Autofocus)',
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 11),
              fontWeight: FontWeight.w500,
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          _buildInfoRow(context, 'Method', afSettings.method),
          _buildInfoRow(context, 'Curve Fitting', afSettings.curveFitting),
          _buildInfoRow(context, 'Step Size', '${afSettings.stepSize}'),
          _buildInfoRow(
              context, 'Steps Out', '${afSettings.initialOffsetSteps}'),
          _buildInfoRow(context, 'Exposure', '${afSettings.exposureTime}s'),
          _buildInfoRow(
              context, 'Exposures/Point', '${afSettings.exposuresPerPoint}'),
          _buildInfoRow(context, 'Binning',
              '${afSettings.binning}x${afSettings.binning}'),
          _buildInfoRow(
              context, 'R\u00B2 Threshold', '${afSettings.rSquaredThreshold}'),
          _buildInfoRow(
              context, 'Backlash Comp', afSettings.backlashCompMethod),
          if (afSettings.disableGuidingDuringAf)
            _buildInfoRow(context, 'Guiding', 'Disabled during AF'),
        ],
      ),
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 12),
              color: colors.textSecondary,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: Responsive.fontSize(context, 12),
              fontWeight: FontWeight.w500,
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  /// Editable fields for per-node overrides (original behavior).
  Widget _buildEditableFields(WidgetRef ref) {
    return Column(
      children: [
        NodePropertyField(
          colors: colors,
          label: 'Method',
          child: NodeDropdown<AutofocusMethod>(
            colors: colors,
            value: node.method,
            items: AutofocusMethod.values,
            labelBuilder: (m) {
              switch (m) {
                case AutofocusMethod.vCurve:
                  return 'V-Curve';
                case AutofocusMethod.hyperbolic:
                  return 'Hyperbolic';
                case AutofocusMethod.quadratic:
                  return 'Quadratic';
              }
            },
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(method: value),
                  );
            },
          ),
        ),
        Row(
          children: [
            Expanded(
              child: NodePropertyField(
                colors: colors,
                label: 'Step size',
                child: NodeNumberInput(
                  colors: colors,
                  value: node.stepSize.toDouble(),
                  min: 1,
                  max: 1000,
                  onChanged: (value) {
                    final stepSize = value.toInt();
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(stepSize: stepSize),
                        );
                    ref
                        .read(sequencerDefaultsProvider.notifier)
                        .updateAutofocusDefaults(
                          stepSize: stepSize,
                        );
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: NodePropertyField(
                colors: colors,
                label: 'Steps out',
                helpText:
                    'How many focuser steps to move outward from the centre on '
                    'each side when sampling the V-curve. More steps span a '
                    'wider focus range but take longer.',
                child: NodeNumberInput(
                  colors: colors,
                  value: node.stepsOut.toDouble(),
                  min: 3,
                  max: 15,
                  onChanged: (value) {
                    final stepsOut = value.toInt();
                    ref.read(currentSequenceProvider.notifier).updateNode(
                          node.copyWith(stepsOut: stepsOut),
                        );
                    ref
                        .read(sequencerDefaultsProvider.notifier)
                        .updateAutofocusDefaults(
                          stepsOut: stepsOut,
                        );
                  },
                ),
              ),
            ),
          ],
        ),
        NodePropertyField(
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
              ref
                  .read(sequencerDefaultsProvider.notifier)
                  .updateAutofocusDefaults(
                    exposureDuration: value,
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Exposures per point',
          child: NodeNumberInput(
            colors: colors,
            value: node.exposuresPerPoint.toDouble(),
            min: 1,
            max: 10,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(exposuresPerPoint: value.toInt()),
                  );
            },
          ),
        ),
      ],
    );
  }
}

class _RotatorProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final RotatorNode node;

  const _RotatorProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Rotator settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Target angle',
          child: NodeNumberInput(
            colors: colors,
            value: node.targetAngle,
            suffix: '\u00B0',
            min: 0,
            max: 360,
            decimals: 1,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(targetAngle: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Relative movement',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.relative,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(relative: value),
                  );
            },
          ),
        ),
        Text(
          node.relative
              ? 'Rotates relative to current position'
              : 'Moves to absolute position angle',
          style: TextStyle(
            fontSize: Responsive.fontSize(context, 12),
            color: colors.textMuted,
            fontStyle: FontStyle.italic,
          ),
        ),
      ],
    );
  }
}

class _SlewProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final SlewNode node;

  const _SlewProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Slew settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Use target coordinates',
          child: NodeToggleSwitch(
            colors: colors,
            value: node.useTargetCoords,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(useTargetCoords: value),
                  );
            },
          ),
        ),
        if (!node.useTargetCoords) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: NodePropertyField(
                  colors: colors,
                  label: 'RA (hours)',
                  child: NodeNumberInput(
                    colors: colors,
                    value: node.customRa ?? 0,
                    suffix: 'h',
                    min: 0,
                    max: 24,
                    decimals: 4,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(customRa: value),
                          );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: NodePropertyField(
                  colors: colors,
                  label: 'Dec (degrees)',
                  child: NodeNumberInput(
                    colors: colors,
                    value: node.customDec ?? 0,
                    suffix: '\u00B0',
                    min: -90,
                    max: 90,
                    decimals: 4,
                    onChanged: (value) {
                      ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(customDec: value),
                          );
                    },
                  ),
                ),
              ),
            ],
          ),
          _CoordinateReadout(
            colors: colors,
            raHours: node.customRa ?? 0,
            decDeg: node.customDec ?? 0,
          ),
        ],
        if (node.useTargetCoords)
          _TargetResolutionPreview(colors: colors, nodeId: node.id),
      ],
    );
  }
}

/// Live HMS/DMS readout shown beneath a decimal RA/Dec entry pair so the user
/// can sanity-check that "5.5754h" really is the Orion-nebula RA they meant.
class _CoordinateReadout extends StatelessWidget {
  final SkotiqColors colors;
  final double raHours;
  final double decDeg;

  const _CoordinateReadout({
    required this.colors,
    required this.raHours,
    required this.decDeg,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        '${formatRaHoursAsHms(raHours)}   ${formatDecDegAsDms(decDeg)}',
        style: TextStyle(
          fontSize: Responsive.fontSize(context, 11),
          color: colors.textMuted,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// Mount-target resolution preview shared by the Slew and Center editors.
///
/// When "Use Target Coordinates" is on, the node inherits RA/Dec from its
/// parent (or the first) [TargetHeaderNode]. This card shows which target will
/// be used (green) or warns when none can be found (amber) so the user isn't
/// left guessing whether the slew/center has anything to aim at.
///
/// Finding a target group is not the same as having somewhere to point: a
/// freshly-added target sits at the 0h/+0° placeholder
/// ([targetCoordinatesUnset]), and confirming that in green is the app
/// asserting a pointing the user never chose. Unset coordinates get the amber
/// warning treatment too.
class _TargetResolutionPreview extends ConsumerWidget {
  final SkotiqColors colors;
  final String nodeId;

  const _TargetResolutionPreview({required this.colors, required this.nodeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sequence = ref.watch(currentSequenceProvider);
    TargetHeaderNode? targetGroup;

    if (sequence != null) {
      targetGroup = sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .where((n) => n.childIds.contains(nodeId))
          .firstOrNull;
      // If no direct parent owns this node, fall back to the first target
      // group in the sequence.
      targetGroup ??= sequence.targetHeaders.isNotEmpty
          ? sequence.targetHeaders.first
          : null;
    }

    final coordinatesUnset =
        targetGroup != null && targetCoordinatesUnset(targetGroup);
    final resolved = targetGroup != null && !coordinatesUnset;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: SkotiqDecorations.tintedBadge(
          resolved ? colors.success : colors.warning,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        ),
        child: Row(
          children: [
            Icon(
              resolved ? LucideIcons.checkCircle : LucideIcons.alertCircle,
              size: 14,
              color: resolved ? colors.success : colors.warning,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                targetGroup == null
                    ? 'No target group found in sequence'
                    : coordinatesUnset
                        ? 'Target "${targetGroup.targetName}" has no '
                            'coordinates set — this node has nowhere to point.\n'
                            'Look up or enter RA/Dec in the target editor.'
                        : 'Will use target: ${targetGroup.targetName}\n'
                            '${formatRaHoursAsHms(targetGroup.raHours)}   '
                            '${formatDecDegAsDms(targetGroup.decDegrees)}',
                style: TextStyle(
                  fontSize: Responsive.fontSize(context, 12),
                  color: resolved ? colors.success : colors.warning,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Format decimal RA hours as `HHh MMm SS.Ss`.
String formatRaHoursAsHms(double hours) => CoordinateFormat.ra(
      hours,
      seconds: SecondsPrecision.oneDecimalPadded,
      wrapHours: true,
    );

/// Format decimal declination degrees as `\u00B1DD\u00B0 MM' SS"`.
String formatDecDegAsDms(double degrees) =>
    CoordinateFormat.dec(degrees, seconds: SecondsPrecision.integerRounded);
