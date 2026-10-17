part of '../stacking_panel.dart';

// OSC / color stacking controls
//
// The OSC dropdown vocabulary (Bayer / demosaic values + labels) and the
// labelled dropdown widget are shared with the Stack-and-Share dialog via
// `osc_stacking_controls.dart` so the two surfaces never drift.

/// The 'Color (OSC)' section of the live-stacking panel.
///
/// Toggling the switch flips [LiveStackingConfig.sensorMode] between `mono` and
/// a colour mode; when ON it reveals the Bayer-pattern and demosaic-quality
/// dropdowns. Defaults are camera-aware: when a colour camera is connected, the
/// switch defaults ON, the colour mode resolves to `auto` (honour the frame's
/// declared geometry), and the Bayer dropdown's Auto entry is labelled with the
/// camera's detected pattern.
class _OscStackingSection extends StatelessWidget {
  final LiveStackingConfig config;
  final SkotiqColors colors;
  final CameraCapabilities? cameraCapabilities;
  final ValueChanged<LiveStackingConfig> onConfigChanged;

  const _OscStackingSection({
    required this.config,
    required this.colors,
    required this.cameraCapabilities,
    required this.onConfigChanged,
  });

  /// Whether OSC/colour stacking is enabled (any non-mono sensor mode).
  bool get _enabled => config.sensorMode.toLowerCase() != 'mono';

  /// The camera's detected Bayer pattern (upper-cased) when it reports one,
  /// else null.
  String? get _detectedPattern {
    final caps = cameraCapabilities;
    if (caps == null || !caps.isColor) return null;
    final raw = caps.bayerPattern?.trim().toUpperCase();
    if (raw == null || raw.isEmpty) return null;
    return oscBayerPatternValues.contains(raw) ? raw : null;
  }

  void _setEnabled(bool value) {
    if (!value) {
      onConfigChanged(config.copyWith(sensorMode: 'mono'));
      return;
    }
    // Turning colour ON: prefer `auto` so a frame that declares its own Bayer
    // geometry (or a colour camera that reports one) is honoured without
    // pinning a pattern the user did not choose. With no camera-derived hint we
    // still use `auto` — the engine debayers only when the frame actually
    // carries CFA geometry, never guessing.
    onConfigChanged(config.copyWith(sensorMode: 'auto'));
  }

  void _setBayerPattern(String? value) {
    if (value == null) return;
    onConfigChanged(
      value == oscBayerAutoValue
          ? config.copyWith(clearBayerPattern: true)
          : config.copyWith(bayerPattern: value),
    );
  }

  void _setDemosaicQuality(String? value) {
    if (value == null) return;
    onConfigChanged(config.copyWith(demosaicQuality: value));
  }

  @override
  Widget build(BuildContext context) {
    // The current Bayer selection: an explicit override pins the dropdown, else
    // the Auto sentinel (which still resolves the detected pattern at runtime).
    final bayerValue = config.bayerPattern?.toUpperCase() ?? oscBayerAutoValue;
    final demosaicValue = config.demosaicQuality.toLowerCase();

    return SkotiqPanel(
      head: const PanelHead(label: 'Color (OSC)'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkotiqSwitchRow(
            label: 'OSC / color',
            subtitle: 'Demosaic Bayer frames to RGB',
            value: _enabled,
            onChanged: _setEnabled,
          ),
          if (_enabled) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            OscDropdownField(
              label: 'Bayer pattern',
              value: bayerValue,
              items: oscBayerPatternValues,
              itemLabels: oscBayerPatternValues
                  .map((v) => oscBayerPatternLabel(v, _detectedPattern))
                  .toList(growable: false),
              onChanged: _setBayerPattern,
            ),
            const SizedBox(height: SkotiqTokens.spaceMd),
            OscDropdownField(
              label: 'Demosaic quality',
              value: demosaicValue,
              items: oscDemosaicQualityValues,
              itemLabels: oscDemosaicQualityValues
                  .map((v) => oscDemosaicQualityLabels[v] ?? v)
                  .toList(growable: false),
              onChanged: _setDemosaicQuality,
            ),
          ],
        ],
      ),
    );
  }
}
