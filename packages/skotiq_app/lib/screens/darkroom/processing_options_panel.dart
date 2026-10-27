import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class ProcessingOptionsPanel extends StatelessWidget {
  const ProcessingOptionsPanel(
      {super.key,
      required this.value,
      required this.onChanged,
      this.enabled = true,
      this.width,
      this.height,
      this.frames});
  final DarkroomProcessingOptions value;
  final ValueChanged<DarkroomProcessingOptions> onChanged;
  final bool enabled;
  final int? width;
  final int? height;
  final int? frames;

  @override
  Widget build(BuildContext context) {
    final scale = value.outputScale;
    final style = SkotiqTypography.bodySm
        .copyWith(color: context.skotiqColors.textSecondary);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Processing', style: SkotiqTypography.bodyStrong),
      const SizedBox(height: 8),
      Text('Normalization', style: style),
      SkotiqDropdown(
          key: const ValueKey('processing_normalization'),
          value: value.normalization,
          items: const ['global', 'local'],
          itemLabels: const ['Global', 'Local'],
          isExpanded: true,
          onChanged: enabled
              ? (v) {
                  if (v != null) onChanged(value.copyWith(normalization: v));
                }
              : null),
      Text(
          value.normalization == 'local'
              ? 'Matches changing background gradients to the reference. It does not remove gradients already in the reference.'
              : 'Matches overall brightness and background to the reference.',
          style: style),
      const SizedBox(height: 8),
      Text('Output sampling', style: style),
      SkotiqDropdown(
          key: const ValueKey('processing_drizzle'),
          value: '${value.drizzleScale}',
          items: const ['0', '1', '2', '3', '4'],
          itemLabels: const [
            'Conventional',
            '1× drizzle',
            '2× drizzle',
            '3× drizzle',
            '4× drizzle'
          ],
          isExpanded: true,
          onChanged: enabled
              ? (v) {
                  if (v != null) {
                    onChanged(value.copyWith(drizzleScale: int.parse(v)));
                  }
                }
              : null),
      if (value.drizzleScale > 0) ...[
        Text('Drop size: ${value.pixfrac.toStringAsFixed(2)}', style: style),
        Slider(
            value: value.pixfrac,
            min: .5,
            max: 1,
            divisions: 10,
            onChanged:
                enabled ? (v) => onChanged(value.copyWith(pixfrac: v)) : null),
        Text(
            '${scale * scale}× as many output pixels. Higher scales need well-dithered data; they do not guarantee more detail. '
            'Smaller drops can leave coverage holes, which may prevent a uniform crop.',
            style: style),
        if (width != null && height != null)
          Text(
              '${width! * scale} × ${height! * scale} pixels before cropping.'
              '${frames == null ? '' : ' About ${(width! * height! * scale * scale * frames! * 8 / (1 << 30)).toStringAsFixed(1)} GB of working files for $frames monochrome frames, plus masters.'}',
              style: style),
      ],
    ]);
  }
}

/// Defaults for new manual and night-end builds. Existing jobs keep their plan.
class ProcessingDefaultsPanel extends ConsumerStatefulWidget {
  const ProcessingDefaultsPanel({super.key});
  @override
  ConsumerState<ProcessingDefaultsPanel> createState() =>
      _ProcessingDefaultsPanelState();
}

class _ProcessingDefaultsPanelState
    extends ConsumerState<ProcessingDefaultsPanel> {
  String? _error;
  bool _saving = false;
  @override
  Widget build(BuildContext context) {
    final settings = ref.watch(darkroomProcessingOptionsProvider);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 12),
      const Text('Defaults for new builds'),
      if (_error != null || settings.hasError)
        Text(_error ?? '${settings.error}'),
      ProcessingOptionsPanel(
          value: settings.valueOrNull ?? const DarkroomProcessingOptions(),
          enabled: settings.hasValue && !_saving,
          onChanged: (value) async {
            setState(() {
              _saving = true;
              _error = null;
            });
            try {
              await ref.read(settingsDaoProvider).setSetting(
                  DarkroomProcessingOptions.settingsKey,
                  jsonEncode(value.toJson()));
              ref.invalidate(darkroomProcessingOptionsProvider);
            } catch (e) {
              if (mounted) {
                setState(
                    () => _error = 'Could not save processing options: $e');
              }
            } finally {
              if (mounted) setState(() => _saving = false);
            }
          }),
    ]);
  }
}
