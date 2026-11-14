part of '../darkroom_editor.dart';

/// Width of the master's name beside each slider, and of the typed weight
/// after it: the widest name is "OIII" and a weight reads to three decimals.
const double _kMixRoleWidth = 36;
const double _kMixFieldWidth = 68;

/// Height of one weight's row on a phone, where it is worked by a fingertip.
const double _kMixTouchRowHeight = 44;

/// Slider notches per unit of weight. Fine enough to balance a channel, coarse
/// enough that 0 and 1 are positions the thumb lands on rather than hunts for.
const int _kMixNotchesPerUnit = 20;

String _mixChannelName(String channel) => switch (channel) {
      'red' => 'Red',
      'green' => 'Green',
      'blue' => 'Blue',
      _ => channel,
    };

/// The weight of each narrowband master in red, green and blue.
///
/// A palette is a fixed set of these weights, so a step combined as SHO or HOO
/// shows the palette's own. Moving one makes the step a custom mix that stores
/// all of them; weights that come back to a palette's exactly are stored as
/// that palette again, so the recipe never calls SHO a custom mix.
class _DarkroomChannelMixControl extends StatelessWidget {
  final DarkroomStep step;
  final DarkroomParamSpec spec;
  final List<DarkroomChannelMixPreset> presets;

  /// Takes the `palette` and `mix` to store, as one edit.
  final void Function(Map<String, Object?> changes) onChanged;

  const _DarkroomChannelMixControl({
    required this.step,
    required this.spec,
    required this.presets,
    required this.onChanged,
  });

  /// The edit that makes [step] a custom mix, starting from the weights it
  /// renders with: those it stores, its palette's, or else the palette its
  /// masters suggest (SHO with all three lines, HOO with Ha and OIII).
  static Map<String, Object?> customMix(
    DarkroomStep step,
    List<DarkroomChannelMixPreset> presets,
  ) {
    final roles = darkroomMixRolesOf(step);
    final start = DarkroomChannelMix.fromJson(step.params['mix']) ??
        presets
            .where((preset) => preset.palette == step.params['palette'])
            .firstOrNull
            ?.mix ??
        presets
            .where((preset) => roles.toSet().containsAll(preset.mix.roles))
            .firstOrNull
            ?.mix;
    return {
      'palette': 'custom',
      if (start != null && roles.length >= 2) 'mix': start.toJson(roles),
    };
  }

  /// The weights the step renders with, or null when it is a custom mix that
  /// stores none yet.
  DarkroomChannelMix? get _mixInEffect {
    final palette = step.params['palette'];
    if (palette == 'custom') {
      return DarkroomChannelMix.fromJson(step.params['mix']);
    }
    for (final preset in presets) {
      if (preset.palette == palette) return preset.mix;
    }
    return null;
  }

  void _store(DarkroomChannelMix mix, List<String> roles) {
    for (final preset in presets) {
      final sameMasters = preset.mix.roles.length == roles.length &&
          preset.mix.roles.containsAll(roles);
      if (sameMasters && preset.mix.matches(mix, roles)) {
        onChanged({'palette': preset.palette, 'mix': null});
        return;
      }
    }
    onChanged({'palette': 'custom', 'mix': mix.toJson(roles)});
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final roles = darkroomMixRolesOf(step);
    final stored = _mixInEffect;
    final mix = stored ?? DarkroomChannelMix.fromJson(const {})!;
    final startingPoints = [
      for (final preset in presets)
        if (roles.toSet().containsAll(preset.mix.roles)) preset,
    ];
    final channelColors = [
      SkotiqChartColors.forTheme(SkotiqChartColors.seriesRed, colors),
      SkotiqChartColors.forTheme(SkotiqChartColors.seriesGreen, colors),
      SkotiqChartColors.forTheme(SkotiqChartColors.seriesBlue, colors),
    ];

    return Column(
      key: const ValueKey('darkroom_channel_mix'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (stored == null)
          Padding(
            padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
            child: Text(
              'This custom mix stores no weights yet. Start from a palette or '
              'set them below.',
              style: SkotiqTypography.captionSm.copyWith(color: colors.warning),
            ),
          ),
        if (startingPoints.isNotEmpty) ...[
          Wrap(
            spacing: SkotiqTokens.spaceXs,
            runSpacing: SkotiqTokens.spaceXs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                'Start from',
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textSecondary,
                ),
              ),
              for (final preset in startingPoints)
                Tooltip(
                  message: 'Set every weight to ${preset.name}',
                  child: SkotiqChip(
                    key: ValueKey('darkroom_mix_start_${preset.palette}'),
                    label: preset.shortName,
                    selected: stored != null && preset.mix.matches(mix, roles),
                    onTap: () => _store(preset.mix, roles),
                  ),
                ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
        ],
        for (var c = 0; c < kDarkroomMixChannels.length; c++) ...[
          if (c > 0) const SizedBox(height: SkotiqTokens.spaceSm),
          _channel(
            context,
            colors,
            kDarkroomMixChannels[c],
            channelColors[c],
            mix,
            roles,
          ),
        ],
      ],
    );
  }

  Widget _channel(
    BuildContext context,
    SkotiqColors colors,
    String channel,
    Color channelColor,
    DarkroomChannelMix mix,
    List<String> roles,
  ) {
    final name = _mixChannelName(channel);
    final total = mix.total(channel, roles);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: SkotiqTokens.spaceSm,
              height: SkotiqTokens.spaceSm,
              decoration: BoxDecoration(
                color: channelColor,
                borderRadius: SkotiqTokens.borderRadiusSm,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Expanded(
              child: Text(
                name,
                style: SkotiqTypography.labelSm.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            Tooltip(
              message: 'The weights of $name added up. They are applied as '
                  'they are, not rescaled: above 1 the stars and nebula in '
                  'this channel are stronger than in any one master. The sky '
                  'level stays where it was.',
              child: Text(
                'total ${_darkroomNumberReading(total)}',
                key: ValueKey('darkroom_mix_total_$channel'),
                style: SkotiqTypography.monoXs.copyWith(
                  color: total == 0 ? colors.warning : colors.textMuted,
                ),
              ),
            ),
          ],
        ),
        for (final role in roles)
          ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: Responsive.isPhone(context) ? _kMixTouchRowHeight : 0,
            ),
            child: _weight(colors, channel, role, mix, roles),
          ),
      ],
    );
  }

  Widget _weight(
    SkotiqColors colors,
    String channel,
    String role,
    DarkroomChannelMix mix,
    List<String> roles,
  ) {
    final value = mix.weight(channel, role);
    final what =
        '${darkroomRoleName(role)} in ${_mixChannelName(channel).toLowerCase()}';
    final min = spec.min;
    final max = spec.max;
    void write(double weight) =>
        _store(mix.withWeight(channel, role, weight), roles);
    return Row(
      children: [
        SizedBox(
          width: _kMixRoleWidth,
          child: Text(
            darkroomRoleName(role),
            style: SkotiqTypography.captionSm.copyWith(
              color: value == 0 ? colors.textMuted : colors.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: min == null || max == null || max <= min
              ? const SizedBox.shrink()
              : MergeSemantics(
                  child: Semantics(
                    label: '$what — ${_darkroomNumberReading(value)}',
                    value: _darkroomNumberReading(value),
                    child: SkotiqSlider(
                      key: ValueKey('darkroom_mix_${channel}_$role'),
                      value: value.clamp(min, max),
                      min: min,
                      max: max,
                      divisions: ((max - min) * _kMixNotchesPerUnit).round(),
                      // The slider reports positions as binary fractions of
                      // its range; dividing a whole notch count keeps 0.3
                      // from being stored as 0.30000000000000004.
                      onChanged: (raw) => write(
                        (raw * _kMixNotchesPerUnit).round() /
                            _kMixNotchesPerUnit,
                      ),
                    ),
                  ),
                ),
        ),
        const SizedBox(width: SkotiqTokens.spaceXs),
        SizedBox(
          width: _kMixFieldWidth,
          child: _DarkroomNumberField(
            label: null,
            semanticName: 'Weight of $what',
            value: value,
            // An emptied box is a weight half typed, not a weight of zero.
            onChanged: (typed) {
              if (typed != null) write(typed);
            },
          ),
        ),
      ],
    );
  }
}

/// Scrolls [child] to the top of the scroll view around it once, after its
/// first layout.
class _DarkroomRevealOnce extends StatefulWidget {
  final VoidCallback onRevealed;
  final Widget child;

  const _DarkroomRevealOnce({required this.onRevealed, required this.child});

  @override
  State<_DarkroomRevealOnce> createState() => _DarkroomRevealOnceState();
}

class _DarkroomRevealOnceState extends State<_DarkroomRevealOnce> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onRevealed();
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
