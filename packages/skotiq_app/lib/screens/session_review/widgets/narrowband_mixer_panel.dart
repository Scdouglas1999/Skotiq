import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// A per-filter narrowband master available for palette compositing.
///
/// Lightweight UI reference to a finished single-filter master (Ha / OIII / SII /
/// …). The controller surfaces one of these per per-filter master so the mixer
/// can present a row of R/G/B weight sliders per channel.
///
/// Shared contract type (the controller author owns the canonical definition and
/// exports it); kept minimal so the two definitions are structurally identical.
class NarrowbandChannelRef {
  /// Stable id of the backing master (used by the controller to resolve the
  /// FITS when combining).
  final int masterId;

  /// Filter token (e.g. `Ha`, `OIII`, `SII`) — drives the channel label.
  final String filter;

  /// Display label for the channel row; falls back to [filter] when empty.
  final String label;

  const NarrowbandChannelRef({
    required this.masterId,
    required this.filter,
    this.label = '',
  });

  /// The label to render for this channel.
  String get displayLabel => label.trim().isNotEmpty ? label.trim() : filter;
}

/// A named narrowband mapping preset (SHO, HOO, …) describing, per output RGB
/// channel, the contribution of each input filter.
class _NarrowbandPreset {
  final String name;

  /// Maps a filter token to its [r, g, b] contribution (0..1).
  final Map<String, List<double>> filterToRgb;

  const _NarrowbandPreset(this.name, this.filterToRgb);
}

/// The classic Hubble (SHO) and bicolor (HOO) palettes.
///
/// SHO → R=SII, G=Ha, B=OIII. HOO → R=Ha, G=OIII, B=OIII.
const List<_NarrowbandPreset> _kPresets = [
  _NarrowbandPreset('SHO', {
    'SII': [1, 0, 0],
    'Ha': [0, 1, 0],
    'OIII': [0, 0, 1],
  }),
  _NarrowbandPreset('HOO', {
    'Ha': [1, 0, 0],
    'OIII': [0, 1, 1],
  }),
];

/// Live narrowband palette mixer: pick a preset (SHO / HOO) or hand-tune the
/// per-channel R/G/B weights, see the resulting combine matrix, and Apply to run
/// the native channel combine through the controller.
///
/// The panel is a pure design-system surface: a [SkotiqCard] with preset
/// chips, one slider row per [NarrowbandChannelRef], a rendered weight matrix,
/// and an Apply [SkotiqButton]. It holds the editable weights locally and
/// hands them back via [onApply] as `(paletteOrCustom, weights)` where `weights`
/// is row-major `[channel][r, g, b]` aligned to [channels].
class NarrowbandMixerPanel extends StatefulWidget {
  /// The per-filter masters available to mix, in display order.
  final List<NarrowbandChannelRef> channels;

  /// Invoked on Apply with the active palette name (or `'custom'`) and the
  /// row-major `[channel][r, g, b]` weight matrix.
  final void Function(String paletteOrCustom, List<List<double>> weights)
      onApply;

  /// True while a combine started from this panel is still running.
  ///
  /// Apply is the mixer's only action and a combine takes tens of seconds.
  /// Without an in-flight state the control looks identical before, during and
  /// after a press, which makes a stalled or failed combine indistinguishable
  /// from a dead button.
  final bool busy;

  const NarrowbandMixerPanel({
    super.key,
    required this.channels,
    required this.onApply,
    this.busy = false,
  });

  @override
  State<NarrowbandMixerPanel> createState() => _NarrowbandMixerPanelState();
}

class _NarrowbandMixerPanelState extends State<NarrowbandMixerPanel> {
  /// Editable per-channel weights, row-major `[channel][r, g, b]`.
  late List<List<double>> _weights;

  /// The active preset name, or `'custom'` once a slider is touched.
  String _palette = 'custom';

  @override
  void initState() {
    super.initState();
    _seedForChannels();
  }

  @override
  void didUpdateWidget(covariant NarrowbandMixerPanel old) {
    super.didUpdateWidget(old);
    // Re-seed on the channel SET, not its length. The masters load
    // asynchronously, so the panel is first built with zero channels and the
    // real Ha/OIII/SII arrive in a later rebuild; keying off the length alone
    // reset the mixer to a zero matrix — a palette that renders pure black —
    // exactly when the channels the preset needs finally showed up. Comparing
    // the resolved keys also catches a same-size swap (Ha/OIII → Ha/SII).
    if (!listEquals(
        _channelKeys(old.channels), _channelKeys(widget.channels))) {
      setState(_seedForChannels);
    }
  }

  static List<String> _channelKeys(List<NarrowbandChannelRef> channels) =>
      [for (final c in channels) '${c.masterId}:${c.filter}'];

  /// Seed [_weights]/[_palette] from the best palette the available channels
  /// can actually produce. Never leaves an all-zero matrix behind: a mixer that
  /// opens on weights of 0.00 can only combine to black, and three clicks to
  /// escape that is three clicks nobody wants at 2am.
  void _seedForChannels() {
    for (final preset in _kPresets) {
      if (_presetApplies(preset)) {
        _applyPreset(preset, notify: false);
        return;
      }
    }
    // No named palette is satisfied (a lone Ha master, or an NII/Hb-only set).
    // Fall back to a luminance mapping — every channel into all three outputs —
    // which at least renders the data. It is a hand-made mapping, so it is
    // honestly labelled 'custom' rather than borrowing a palette name.
    _weights = List.generate(widget.channels.length, (_) => <double>[1, 1, 1]);
    _palette = 'custom';
  }

  /// Canonicalise a raw filter label to the preset key it maps to, mirroring the
  /// controller's fuzzy narrowband hints so real names ('Ha 7nm', 'O3', 'Sii')
  /// resolve to 'Ha' / 'OIII' / 'SII'. Returns null for non-narrowband labels.
  static String? _canon(String f) {
    final n = f.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    if (n.startsWith('halpha') || n.startsWith('ha')) return 'Ha';
    if (n.startsWith('oiii') || n.startsWith('o3')) return 'OIII';
    if (n.startsWith('sii') || n.startsWith('s2')) return 'SII';
    return null;
  }

  /// True only when EVERY filter the preset maps is present in [channels].
  ///
  /// A partial match is not the palette: SHO built from Ha+OIII alone leaves
  /// the red channel at zero, so offering (and auto-adopting) it for a bicolor
  /// set produced a red-less "Hubble palette". Requiring full coverage is what
  /// makes Ha+OIII resolve to HOO instead.
  bool _presetApplies(_NarrowbandPreset preset) {
    final available = <String>{
      for (final c in widget.channels)
        if (_canon(c.filter) case final key?) key,
    };
    return preset.filterToRgb.keys.every(available.contains);
  }

  void _applyPreset(_NarrowbandPreset preset, {bool notify = true}) {
    final next = List.generate(widget.channels.length, (i) {
      final key = _canon(widget.channels[i].filter);
      final mapped = key == null ? null : preset.filterToRgb[key];
      return mapped != null ? List<double>.from(mapped) : <double>[0, 0, 0];
    });
    void apply() {
      _weights = next;
      _palette = preset.name;
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  void _setWeight(int channel, int rgb, double value) {
    setState(() {
      _weights[channel][rgb] = value;
      _palette = 'custom';
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);

    if (widget.channels.isEmpty) {
      return const SkotiqPanel(
        child: EmptyState(
          icon: SkotiqIcons.palette,
          title: 'No narrowband masters',
          body: 'Integrate per-filter masters (Ha / OIII / SII) to mix a '
              'narrowband palette.',
        ),
      );
    }

    return SkotiqPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _header(colors),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _presetChips(colors),
          const SizedBox(height: SkotiqTokens.spaceLg),
          for (var i = 0; i < widget.channels.length; i++) ...[
            _channelRow(colors, i),
            if (i < widget.channels.length - 1)
              const SizedBox(height: SkotiqTokens.spaceMd),
          ],
          const SizedBox(height: SkotiqTokens.spaceLg),
          _matrixPreview(colors),
          const SizedBox(height: SkotiqTokens.spaceLg),
          Align(
            alignment: Alignment.centerRight,
            child: SkotiqButton(
              label: widget.busy ? 'Combining…' : 'Apply palette',
              icon: SkotiqIcons.check,
              isLoading: widget.busy,
              onPressed: widget.busy
                  ? null
                  : () => widget.onApply(
                        _palette,
                        _weights.map((row) => List<double>.from(row)).toList(),
                      ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(SkotiqColors colors) {
    return Row(
      children: [
        Icon(SkotiqIcons.palette,
            size: SkotiqTokens.iconSm, color: colors.primary),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text(
          'Narrowband palette',
          style: SkotiqTypography.sectionTitle
              .copyWith(color: colors.textPrimary),
        ),
        const Spacer(),
        Text(
          _palette == 'custom' ? 'Custom mix' : '$_palette preset',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }

  Widget _presetChips(SkotiqColors colors) {
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      children: [
        for (final preset in _kPresets)
          _PresetChip(
            label: preset.name,
            selected: _palette == preset.name,
            enabled: _presetApplies(preset),
            onTap: () => _applyPreset(preset),
          ),
      ],
    );
  }

  Widget _channelRow(SkotiqColors colors, int index) {
    final channel = widget.channels[index];
    const rgbLabels = ['R', 'G', 'B'];
    final rgbColors = [colors.error, colors.success, colors.info];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(SkotiqIcons.filter,
                size: SkotiqTokens.iconXs, color: colors.textSecondary),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Text(
              channel.displayLabel,
              style: SkotiqTypography.labelStrong
                  .copyWith(color: colors.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        for (var rgb = 0; rgb < 3; rgb++)
          _WeightSlider(
            channelLabel: rgbLabels[rgb],
            channelColor: rgbColors[rgb],
            value: _weights[index][rgb],
            onChanged: (v) => _setWeight(index, rgb, v),
          ),
      ],
    );
  }

  Widget _matrixPreview(SkotiqColors colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Combine matrix',
            style: SkotiqTypography.captionSm
                .copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          for (var i = 0; i < widget.channels.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: SkotiqTokens.spaceXs),
              child: Text(
                '${widget.channels[i].displayLabel}  -> '
                'R ${_fmt(_weights[i][0])}  '
                'G ${_fmt(_weights[i][1])}  '
                'B ${_fmt(_weights[i][2])}',
                style: SkotiqTypography.monoSm
                    .copyWith(color: colors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }

  static String _fmt(double v) => v.toStringAsFixed(2);
}

/// A selectable preset chip (SHO / HOO). Disabled when no available channel
/// matches the preset's filter map.
class _PresetChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _PresetChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final accent = colors.primary;
    final fg = !enabled
        ? colors.textMuted.withValues(alpha: SkotiqTokens.opacityDisabled)
        : selected
            ? colors.onPrimary
            : colors.textSecondary;
    final bg = selected ? accent : colors.well;
    return Opacity(
      opacity: enabled ? 1 : SkotiqTokens.opacityMuted,
      child: Semantics(
          button: true,
          enabled: enabled,
          selected: selected,
          child: GestureDetector(
            onTap: enabled ? onTap : null,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceMd,
                vertical: SkotiqTokens.spaceSm,
              ),
              decoration: BoxDecoration(
                color: bg,
                borderRadius:
                    BorderRadius.circular(SkotiqTokens.radiusFull),
                border: Border.all(
                  color:
                      selected ? accent : colors.border.withValues(alpha: 0.75),
                ),
              ),
              child: Text(
                label,
                style: SkotiqTypography.buttonSm.copyWith(color: fg),
              ),
            ),
          )),
    );
  }
}

/// A single labelled 0..1 weight slider for one R/G/B contribution.
class _WeightSlider extends StatelessWidget {
  final String channelLabel;
  final Color channelColor;
  final double value;
  final ValueChanged<double> onChanged;

  const _WeightSlider({
    required this.channelLabel,
    required this.channelColor,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Row(
      children: [
        SizedBox(
          width: SkotiqTokens.space2xl,
          child: Text(
            channelLabel,
            style:
                SkotiqTypography.labelStrong.copyWith(color: channelColor),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderThemeData(
              activeTrackColor: channelColor,
              inactiveTrackColor: colors.border.withValues(alpha: 0.5),
              thumbColor: channelColor,
              overlayColor: channelColor.withValues(alpha: 0.15),
              trackHeight: 3,
            ),
            child: Slider(
              value: value.clamp(0.0, 1.0),
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: SkotiqTokens.space4xl,
          child: Text(
            value.toStringAsFixed(2),
            textAlign: TextAlign.right,
            style: SkotiqTypography.monoSm
                .copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}
