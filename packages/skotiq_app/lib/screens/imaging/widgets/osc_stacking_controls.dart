// Shared OSC / colour-stacking control vocabulary and widgets.
//
// Both OSC surfaces — the live-stacking panel
// (`screens/imaging/widgets/stacking_panel.dart`) and the Stack-and-Share
// launcher dialog (`screens/stack_result/stack_and_share_dialog.dart`) — present
// the *same* controls over the same native vocabulary, so the option lists, the
// label map, and the dropdown widget live here in one place rather than being
// copy-pasted into each screen (which would drift the moment someone adds a
// debayer algorithm or relabels an option).
//
// The string values map verbatim to the native parsers:
//   * Bayer patterns → `BayerPattern::from_str` (`stacking_api.rs`);
//   * demosaic qualities → `parse_demosaic_quality` (`stacking_api.rs`).
// Keep this file the single Dart-side mirror of that vocabulary.

import 'package:flutter/widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Sentinel dropdown value meaning "no Bayer override" — let the engine resolve
/// the pattern from the connected camera's reported CFA or the reference frame's
/// FITS `BAYERPAT` geometry. Maps to a `null` Bayer pattern in the resolved
/// stacking config.
const String oscBayerAutoValue = 'auto';

/// Bayer-pattern dropdown values, in display order. [oscBayerAutoValue] maps to
/// a null override; the rest map verbatim to the native `BayerPattern::from_str`
/// vocabulary.
const List<String> oscBayerPatternValues = <String>[
  oscBayerAutoValue,
  'RGGB',
  'BGGR',
  'GRBG',
  'GBRG',
];

/// Demosaic-quality dropdown values, mapped verbatim to the native
/// `DebayerAlgorithm` selector / `parse_demosaic_quality`.
const List<String> oscDemosaicQualityValues = <String>[
  'bilinear',
  'vng',
  'superpixel',
];

/// Human-readable labels for [oscDemosaicQualityValues].
const Map<String, String> oscDemosaicQualityLabels = <String, String>{
  'bilinear': 'Bilinear',
  'vng': 'VNG',
  'superpixel': 'SuperPixel',
};

/// Build the Bayer-pattern dropdown label for [value], naming the detected
/// pattern on the [oscBayerAutoValue] entry when a colour camera reports one.
///
/// Used by both OSC surfaces so the "Auto (detected: …)" affordance reads
/// identically in the live panel and the Stack-and-Share dialog.
String oscBayerPatternLabel(String value, String? detectedPattern) {
  if (value == oscBayerAutoValue) {
    return detectedPattern != null
        ? 'Auto (detected: $detectedPattern)'
        : 'Auto';
  }
  return value;
}

/// A labelled dropdown row used inside the OSC controls on both surfaces: a
/// design-system label above a [SkotiqDropdown].
///
/// Pass [enabled] `false` (e.g. while a run is in flight) to disable the
/// dropdown without changing its displayed value.
class OscDropdownField extends StatelessWidget {
  /// Field label rendered above the dropdown.
  final String label;

  /// Currently-selected value (must be present in [items]).
  final String value;

  /// Selectable values, in display order.
  final List<String> items;

  /// Human-readable labels parallel to [items].
  final List<String> itemLabels;

  /// Whether the dropdown accepts input. When `false`, [onChanged] is not wired.
  final bool enabled;

  /// Selection callback. Ignored when [enabled] is `false`.
  final ValueChanged<String?> onChanged;

  const OscDropdownField({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.itemLabels,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: SkotiqTypography.labelSm.copyWith(
            color: colors.textSecondary,
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        SkotiqDropdown(
          isExpanded: true,
          value: value,
          items: items,
          itemLabels: itemLabels,
          onChanged: enabled ? onChanged : null,
        ),
      ],
    );
  }
}
