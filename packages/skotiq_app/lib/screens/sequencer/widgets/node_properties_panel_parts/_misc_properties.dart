// Properties widgets for nodes that don't fit the capture/motion/flow buckets: notification, script, simple-instruction info card, dome, unknown-node fallback, the four cover/calibrator nodes plus their shared scaffold & timeout field, and the instruction-set info widget.
part of '../node_properties_panel.dart';

class _ScriptProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final ScriptNode node;

  const _ScriptProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: 'Script settings'),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Script path',
          child: NodeTextInput(
            colors: colors,
            value: node.scriptPath,
            hint: 'Path to script file',
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(scriptPath: value),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Arguments',
          child: NodeTextInput(
            colors: colors,
            value: _joinScriptArgs(node.arguments),
            hint: 'Space-separated; quote values with spaces',
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(arguments: _tokenizeScriptArgs(value)),
                  );
            },
          ),
        ),
        NodePropertyField(
          colors: colors,
          label: 'Timeout',
          child: NodeNumberInput(
            colors: colors,
            value: (node.timeoutSecs ?? 300).toDouble(),
            suffix: 's',
            min: 1,
            max: 3600,
            onChanged: (value) {
              ref.read(currentSequenceProvider.notifier).updateNode(
                    node.copyWith(timeoutSecs: value.toInt()),
                  );
            },
          ),
        ),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colors.warning.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.alertTriangle, size: 14, color: colors.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Scripts run with sequence context variables available as environment variables',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.warning,
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

class _SimpleInstructionInfo extends StatelessWidget {
  final SkotiqColors colors;
  final SequenceNode node;

  const _SimpleInstructionInfo({required this.colors, required this.node});

  @override
  Widget build(BuildContext context) {
    final String description;
    final IconData icon;

    if (node is ParkNode) {
      description =
          'Parks the mount at its home position. The mount will not track after parking.';
      icon = LucideIcons.parkingCircle;
    } else if (node is UnparkNode) {
      description =
          'Unparks the mount and enables tracking. Required before slewing or imaging.';
      icon = LucideIcons.unlock;
    } else {
      description = 'This instruction has no additional settings.';
      icon = LucideIcons.settings;
    }

    return SkotiqCard(
      padding: const EdgeInsets.all(16),
      borderRadius: SkotiqTokens.radiusLg,
      child: Column(
        children: [
          Icon(icon, size: 32, color: colors.primary),
          const SizedBox(height: 12),
          Text(
            description,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              color: colors.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _DomeProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final SequenceNode node;

  const _DomeProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String title;
    final String description;
    final IconData icon;
    final bool shutterOnly;

    if (node is OpenDomeNode) {
      title = 'Open Dome Settings';
      description =
          'Opens the dome shutter to allow imaging. If not using shutter-only mode, will also rotate dome to tracking position.';
      icon = LucideIcons.doorOpen;
      shutterOnly = (node as OpenDomeNode).shutterOnly;
    } else if (node is CloseDomeNode) {
      title = 'Close Dome Settings';
      description =
          'Closes the dome shutter to protect equipment. Typically used at end of session or when weather becomes unsafe.';
      icon = LucideIcons.doorClosed;
      shutterOnly = (node as CloseDomeNode).shutterOnly;
    } else {
      title = 'Park Dome Settings';
      description =
          'Parks the dome at its home position. The dome will stop tracking the telescope.';
      icon = LucideIcons.parkingCircle;
      shutterOnly = (node as ParkDomeNode).shutterOnly;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: title),
        const SizedBox(height: 12),
        NodePropertyField(
          colors: colors,
          label: 'Shutter only',
          child: NodeToggleSwitch(
            colors: colors,
            value: shutterOnly,
            onChanged: (value) {
              if (node is OpenDomeNode) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      (node as OpenDomeNode).copyWith(shutterOnly: value),
                    );
              } else if (node is CloseDomeNode) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      (node as CloseDomeNode).copyWith(shutterOnly: value),
                    );
              } else if (node is ParkDomeNode) {
                ref.read(currentSequenceProvider.notifier).updateNode(
                      (node as ParkDomeNode).copyWith(shutterOnly: value),
                    );
              }
            },
          ),
        ),
        Text(
          shutterOnly
              ? 'Only operates the shutter, dome will not rotate'
              : 'Will operate both shutter and dome rotation',
          style: TextStyle(
            fontSize: SkotiqTypography.fontSize11,
            color: colors.textMuted,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 16),
        SkotiqCard(
          padding: const EdgeInsets.all(16),
          borderRadius: SkotiqTokens.radiusLg,
          child: Column(
            children: [
              Icon(icon, size: 32, color: colors.primary),
              const SizedBox(height: 12),
              Text(
                description,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textSecondary,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _OpenCoverProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final OpenCoverNode node;

  const _OpenCoverProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CoverCalibratorScaffold(
      colors: colors,
      title: 'Open Cover Settings',
      icon: LucideIcons.doorOpen,
      description:
          'Opens the motorized dust cover or flat panel lid. Requires a cover calibrator device.',
      children: [
        _CoverCalibratorTimeoutField(
          colors: colors,
          timeoutSecs: node.timeoutSecs,
          min: 5,
          max: 300,
          onChanged: (value) {
            ref
                .read(currentSequenceProvider.notifier)
                .updateNode(node.copyWith(timeoutSecs: value));
          },
        ),
      ],
    );
  }
}

class _CloseCoverProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final CloseCoverNode node;

  const _CloseCoverProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CoverCalibratorScaffold(
      colors: colors,
      title: 'Close Cover Settings',
      icon: LucideIcons.doorClosed,
      description:
          'Closes the motorized dust cover or flat panel lid. Use to protect optics or transition out of flats.',
      children: [
        _CoverCalibratorTimeoutField(
          colors: colors,
          timeoutSecs: node.timeoutSecs,
          min: 5,
          max: 300,
          onChanged: (value) {
            ref
                .read(currentSequenceProvider.notifier)
                .updateNode(node.copyWith(timeoutSecs: value));
          },
        ),
      ],
    );
  }
}

class _CalibratorOnProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final CalibratorOnNode node;

  const _CalibratorOnProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CoverCalibratorScaffold(
      colors: colors,
      title: 'Calibrator On Settings',
      icon: LucideIcons.lightbulb,
      description:
          'Turns on the flat panel light at the specified brightness. Use with flat frame sequences.',
      children: [
        NodePropertyField(
          colors: colors,
          label: 'Brightness',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: node.brightness.toDouble().clamp(0.0, 255.0),
                      min: 0,
                      max: 255,
                      divisions: 255,
                      onChanged: (value) {
                        ref.read(currentSequenceProvider.notifier).updateNode(
                            node.copyWith(brightness: value.round()));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '${node.brightness}',
                      textAlign: TextAlign.right,
                      style: SkotiqTypography.labelStrong
                          .copyWith(color: colors.textPrimary),
                    ),
                  ),
                ],
              ),
              Text(
                '0 = off, 255 = maximum brightness',
                style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textMuted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _CoverCalibratorTimeoutField(
          colors: colors,
          timeoutSecs: node.timeoutSecs,
          min: 5,
          max: 120,
          onChanged: (value) {
            ref
                .read(currentSequenceProvider.notifier)
                .updateNode(node.copyWith(timeoutSecs: value));
          },
        ),
      ],
    );
  }
}

class _CalibratorOffProperties extends ConsumerWidget {
  final SkotiqColors colors;
  final CalibratorOffNode node;

  const _CalibratorOffProperties({required this.colors, required this.node});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _CoverCalibratorScaffold(
      colors: colors,
      title: 'Calibrator Off Settings',
      icon: LucideIcons.lightbulbOff,
      description:
          'Turns off the flat panel light. Use after flat frame capture is complete.',
      children: [
        _CoverCalibratorTimeoutField(
          colors: colors,
          timeoutSecs: node.timeoutSecs,
          min: 5,
          max: 120,
          onChanged: (value) {
            ref
                .read(currentSequenceProvider.notifier)
                .updateNode(node.copyWith(timeoutSecs: value));
          },
        ),
      ],
    );
  }
}

class _CoverCalibratorScaffold extends StatelessWidget {
  final SkotiqColors colors;
  final String title;
  final IconData icon;
  final String description;
  final List<Widget> children;

  const _CoverCalibratorScaffold({
    required this.colors,
    required this.title,
    required this.icon,
    required this.description,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NodeSectionHeader(colors: colors, label: title),
        const SizedBox(height: 12),
        ...children,
        const SizedBox(height: 16),
        SkotiqCard(
          padding: const EdgeInsets.all(16),
          borderRadius: SkotiqTokens.radiusLg,
          child: Column(
            children: [
              Icon(icon, size: 32, color: colors.primary),
              const SizedBox(height: 12),
              Text(
                description,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textSecondary,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CoverCalibratorTimeoutField extends StatelessWidget {
  final SkotiqColors colors;
  final int timeoutSecs;
  final double min;
  final double max;
  final ValueChanged<int> onChanged;

  const _CoverCalibratorTimeoutField({
    required this.colors,
    required this.timeoutSecs,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return NodePropertyField(
      colors: colors,
      label: 'Timeout (seconds)',
      child: NodeNumberInput(
        colors: colors,
        value: timeoutSecs.toDouble(),
        min: min,
        max: max,
        suffix: 's',
        onChanged: (value) => onChanged(value.round()),
      ),
    );
  }
}

class _InstructionSetInfo extends StatelessWidget {
  final SkotiqColors colors;
  final InstructionSetNode node;

  const _InstructionSetInfo({required this.colors, required this.node});

  @override
  Widget build(BuildContext context) {
    return SkotiqCard(
      padding: const EdgeInsets.all(16),
      borderRadius: SkotiqTokens.radiusLg,
      child: Column(
        children: [
          Icon(LucideIcons.listTree, size: 32, color: colors.accent),
          const SizedBox(height: 12),
          Text(
            'Container for sequential instructions. All children execute in order from top to bottom.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize12,
              color: colors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${node.childIds.length} children',
            style: TextStyle(
              fontSize: SkotiqTypography.fontSize11,
              color: colors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Split a command-line argument string into tokens, honouring single and
/// double quotes (and backslash escapes) so paths/values containing spaces
/// survive as one argument: `--out "my dir" -v` → `[--out, my dir, -v]`.
List<String> _tokenizeScriptArgs(String input) {
  final tokens = <String>[];
  final buffer = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var hasToken = false;

  for (var i = 0; i < input.length; i++) {
    final ch = input[i];
    if (ch == '\\' && !inSingle && i + 1 < input.length) {
      // Backslash escapes the next char outside single quotes.
      buffer.write(input[i + 1]);
      hasToken = true;
      i++;
      continue;
    }
    if (ch == "'" && !inDouble) {
      inSingle = !inSingle;
      hasToken = true;
      continue;
    }
    if (ch == '"' && !inSingle) {
      inDouble = !inDouble;
      hasToken = true;
      continue;
    }
    if ((ch == ' ' || ch == '\t') && !inSingle && !inDouble) {
      if (hasToken) {
        tokens.add(buffer.toString());
        buffer.clear();
        hasToken = false;
      }
      continue;
    }
    buffer.write(ch);
    hasToken = true;
  }
  if (hasToken) tokens.add(buffer.toString());
  return tokens;
}

/// Re-join argument tokens for display, quoting any token that contains
/// whitespace or quote characters so the round-trip is faithful.
String _joinScriptArgs(List<String> args) {
  return args.map((arg) {
    if (arg.isEmpty) return '""';
    final needsQuote =
        arg.contains(' ') || arg.contains('\t') || arg.contains('"');
    if (!needsQuote) return arg;
    final escaped = arg.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
    return '"$escaped"';
  }).join(' ');
}
