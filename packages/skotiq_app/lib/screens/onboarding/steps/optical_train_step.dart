import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// Outside the core barrel by design (name collision with
// `cameraPresetsProvider`); imported by source path, as the preset picker does.
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../widgets/help/field_help_label.dart';
import '../../../widgets/hardware/hardware_preset_picker_dialog.dart';

/// True when the optics on record still describe the telescope [draft] names.
///
/// The badge beside the model name is a green tick, which reads as "validated
/// against the library", so it must not survive an edit: applying a preset and
/// then typing a different focal length describes a scope that does not exist.
/// A preset no longer in the catalog (a deleted user override) cannot be
/// checked against, so it is reported as edited rather than confirmed.
///
/// Shared with the wizard's closing step so both name the same rig.
bool draftMatchesTelescopePreset(
  OnboardingDraft draft,
  List<TelescopePreset> presets,
) {
  final presetId = draft.telescopePresetId;
  if (presetId == null) return false;
  for (final preset in presets) {
    if (preset.id != presetId) continue;
    const tolerance = 0.05;
    return (draft.focalLengthMm ?? -1) != -1 &&
        (draft.apertureMm ?? -1) != -1 &&
        (preset.focalLengthMm - draft.focalLengthMm!).abs() < tolerance &&
        (preset.apertureMm - draft.apertureMm!).abs() < tolerance;
  }
  return false;
}

/// How the rig's telescope should be named on a summary: the library model when
/// the optics still match it, that model marked `— edited` when they no longer
/// do, and the bare focal length when no library entry was ever used.
String? telescopeSummaryLabel(
  OnboardingDraft draft,
  List<TelescopePreset> presets,
) {
  final name = draft.telescopeName;
  if (name == null) {
    final focalLength = draft.focalLengthMm;
    return focalLength == null ? null : '${focalLength.toStringAsFixed(0)} mm';
  }
  return draftMatchesTelescopePreset(draft, presets) ? name : '$name — edited';
}

/// Optical train step — pixel size (microns), focal length (mm),
/// aperture (mm), reducer factor. The image scale (arcsec/px) is
/// auto-computed from pixel size + effective focal length.
///
/// Optics can be prefilled in one tap from the built-in telescope library
/// ([HardwarePresetPickerDialog]) or entered manually. Either way the
/// load-bearing fields — focal length, aperture, pixel size — carry inline
/// [FieldHelpLabel] hints so a first-time imager understands where each value
/// comes from without leaving the wizard.
///
/// This is the only step where focal length, aperture and pixel size are all
/// required, because the imaging stack needs them for plate solving, framing
/// and FOV calculations. The computed image scale is shown in real time so the
/// numbers can be sanity-checked before moving on.
class OnboardingOpticalTrainStep extends ConsumerStatefulWidget {
  const OnboardingOpticalTrainStep({super.key});

  @override
  ConsumerState<OnboardingOpticalTrainStep> createState() =>
      _OnboardingOpticalTrainStepState();
}

class _OnboardingOpticalTrainStepState
    extends ConsumerState<OnboardingOpticalTrainStep> {
  late final TextEditingController _focalLengthController;
  late final TextEditingController _apertureController;
  late final TextEditingController _pixelSizeController;
  late final TextEditingController _reducerController;

  String? _focalLengthError;
  String? _apertureError;
  String? _pixelSizeError;
  String? _reducerError;

  @override
  void initState() {
    super.initState();
    final draft = ref.read(onboardingDraftProvider);
    _focalLengthController = TextEditingController(
      text: draft.focalLengthMm?.toStringAsFixed(1) ?? '',
    );
    _apertureController = TextEditingController(
      text: draft.apertureMm?.toStringAsFixed(1) ?? '',
    );
    _pixelSizeController = TextEditingController(
      text: draft.pixelSizeMicrons?.toStringAsFixed(2) ?? '',
    );
    _reducerController = TextEditingController(
      text: draft.reducerFactor.toStringAsFixed(2),
    );
  }

  @override
  void dispose() {
    _focalLengthController.dispose();
    _apertureController.dispose();
    _pixelSizeController.dispose();
    _reducerController.dispose();
    super.dispose();
  }

  void _commit(_OpticalField editedField) {
    final fl = double.tryParse(_focalLengthController.text.trim());
    final ap = double.tryParse(_apertureController.text.trim());
    final px = double.tryParse(_pixelSizeController.text.trim());
    final rd = double.tryParse(_reducerController.text.trim());

    setState(() {
      switch (editedField) {
        case _OpticalField.focalLength:
          _focalLengthError = _boundError(
            fl,
            min: OpticalTrainLimits.minFocalLengthMm,
            max: OpticalTrainLimits.maxFocalLengthMm,
            unit: 'mm',
            missing: 'Enter a positive focal length in mm.',
          );
        case _OpticalField.aperture:
          _apertureError = _boundError(
            ap,
            min: OpticalTrainLimits.minApertureMm,
            max: OpticalTrainLimits.maxApertureMm,
            unit: 'mm',
            missing: 'Enter a positive aperture in mm.',
          );
        case _OpticalField.pixelSize:
          _pixelSizeError = _boundError(
            px,
            min: OpticalTrainLimits.minPixelSizeMicrons,
            max: OpticalTrainLimits.maxPixelSizeMicrons,
            unit: 'microns',
            missing: 'Enter a positive pixel size in microns.',
          );
        case _OpticalField.reducer:
          _reducerError = _boundError(
            rd,
            min: OpticalTrainLimits.minReducerFactor,
            max: OpticalTrainLimits.maxReducerFactor,
            unit: '',
            missing: 'Reducer must be > 0 (use 1.0 for no reducer).',
          );
      }
    });

    ref.read(onboardingDraftProvider.notifier).setOpticalTrain(
          focalLengthMm: fl,
          apertureMm: ap,
          pixelSizeMicrons: px,
          reducerFactor: rd,
        );
  }

  /// Inline error for one field, or null when the value is plausible.
  ///
  /// The numbers come from the shared [OpticalTrainLimits] constants — the same
  /// ones that block Next — so the red field message and the wizard's blocking
  /// message can never disagree about where the boundary is. Field-level errors
  /// matter here because the step-level message names one problem at a time:
  /// this points at the field to fix.
  static String? _boundError(
    double? value, {
    required double min,
    required double max,
    required String unit,
    required String missing,
  }) {
    if (value == null || value <= 0) return missing;
    if (value < min || value > max) {
      final suffix = unit.isEmpty ? '.' : ' $unit.';
      return 'Must be between ${_trim(min)} and ${_trim(max)}$suffix';
    }
    return null;
  }

  /// True when [value] is present and inside its bounds, false when it is
  /// present but implausible, null when it has not been entered yet. The three
  /// states are distinct because a missing input and a rejected input need
  /// different words in the computed panel.
  static bool? _plausible(double? value, double min, double max) {
    if (value == null || value <= 0) return null;
    return value >= min && value <= max;
  }

  /// Drop a trailing `.0` so a bound reads as `50000`, not `50000.0`.
  static String _trim(double value) => value == value.roundToDouble()
      ? value.toStringAsFixed(0)
      : value.toString();

  /// Open the telescope library and, on selection, apply the preset to the
  /// draft and reflect the new optics in the focal-length / aperture fields.
  /// The reducer and pixel size are intentionally left untouched — a reducer
  /// is a separate accessory and the pixel size comes from the camera, not the
  /// OTA.
  Future<void> _pickFromLibrary() async {
    final preset = await HardwarePresetPickerDialog.showTelescope(context);
    if (preset == null || !mounted) return;

    await ref
        .read(onboardingDraftProvider.notifier)
        .applyTelescopePreset(preset);
    if (!mounted) return;

    _focalLengthController.text = preset.focalLengthMm.toStringAsFixed(1);
    _apertureController.text = preset.apertureMm.toStringAsFixed(1);
    // The preset owns only these two fields. Clear their stale errors without
    // validating untouched camera/reducer inputs as a side effect of choosing
    // a telescope.
    setState(() {
      _focalLengthError = null;
      _apertureError = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final draft = ref.watch(onboardingDraftProvider);
    final colors = SkotiqColors.of(context);

    final imageScale = draft.imageScaleArcsecPerPixel;
    final effectiveFocal = draft.effectiveFocalLengthMm;
    final fRatio = (draft.apertureMm != null &&
            draft.apertureMm! > 0 &&
            effectiveFocal != null)
        ? effectiveFocal / draft.apertureMm!
        : null;

    // A derived number is only presented as a computed fact when every input it
    // depends on is inside the shared plausibility bounds. Printing it
    // unconditionally is what rendered "f/9999999990000.00" from a focal length
    // of 999999999 mm and an aperture of 0.0001 mm — the panel dressed an
    // impossible optical system up as arithmetic the user could trust.
    final focalOk = _plausible(
      draft.focalLengthMm,
      OpticalTrainLimits.minFocalLengthMm,
      OpticalTrainLimits.maxFocalLengthMm,
    );
    final apertureOk = _plausible(
      draft.apertureMm,
      OpticalTrainLimits.minApertureMm,
      OpticalTrainLimits.maxApertureMm,
    );
    final pixelOk = _plausible(
      draft.pixelSizeMicrons,
      OpticalTrainLimits.minPixelSizeMicrons,
      OpticalTrainLimits.maxPixelSizeMicrons,
    );
    final reducerOk = _plausible(
      draft.reducerFactor,
      OpticalTrainLimits.minReducerFactor,
      OpticalTrainLimits.maxReducerFactor,
    );
    final fRatioOk = fRatio == null
        ? null
        : fRatio >= OpticalTrainLimits.minFRatio &&
            fRatio <= OpticalTrainLimits.maxFRatio;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            icon: LucideIcons.ruler,
            title: 'Tell us about your optics',
          ),
          Text(
            'Image scale and field of view are computed from these numbers, '
            'so accurate values matter.',
            style: SkotiqTypography.bodySm.copyWith(
              color: colors.textSecondary,
            ),
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          // One-tap prefill from the built-in telescope catalog. Manual entry
          // below remains fully available regardless of whether a preset was
          // chosen.
          Row(
            children: [
              // Flexible so a narrow phone column bounds the button and its
              // label ellipsizes; unbounded it took its full intrinsic width and
              // overflowed the row.
              Flexible(
                child: SkotiqButton(
                  // lucide_icons 0.257.0 ships no `telescope` glyph; `aperture`
                  // is this codebase's established optics/telescope icon
                  // (equipment_profiles_screen, framing optical config panel).
                  icon: SkotiqIcons.aperture,
                  label: 'Choose from telescope library',
                  variant: ButtonVariant.secondary,
                  size: ButtonSize.small,
                  onPressed: _pickFromLibrary,
                ),
              ),
              if (draft.telescopeName != null) ...[
                const SizedBox(width: SkotiqTokens.spaceMd),
                Flexible(
                  child: Builder(
                    builder: (context) {
                      final matchesLibrary = _matchesTelescopePreset(draft);
                      return Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            matchesLibrary
                                ? LucideIcons.checkCircle2
                                : SkotiqIcons.edit,
                            size: SkotiqTokens.iconSm,
                            color: matchesLibrary
                                ? colors.success
                                : colors.textSecondary,
                          ),
                          const SizedBox(width: SkotiqTokens.spaceSm),
                          Flexible(
                            child: Text(
                              matchesLibrary
                                  ? draft.telescopeName!
                                  : '${draft.telescopeName!} — edited',
                              style: SkotiqTypography.bodyStrong.copyWith(
                                color: matchesLibrary
                                    ? colors.textPrimary
                                    : colors.textSecondary,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
          _NumericField(
            controller: _focalLengthController,
            label: 'Telescope focal length',
            help:
                "Focal length is the telescope's focal length in mm — found in its specs or on the OTA label.",
            hint: 'e.g. 500, 1000, 2000',
            suffix: 'mm',
            errorText: _focalLengthError,
            onChanged: () => _commit(_OpticalField.focalLength),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _NumericField(
            controller: _apertureController,
            label: 'Aperture',
            help:
                'Aperture is the diameter of the telescope in mm — it sets the focal ratio (focal length ÷ aperture) and how much light you gather.',
            hint: 'e.g. 80, 102, 200',
            suffix: 'mm',
            errorText: _apertureError,
            onChanged: () => _commit(_OpticalField.aperture),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _NumericField(
            controller: _reducerController,
            label: 'Reducer / Barlow factor',
            help:
                'Multiplier applied to focal length: 1.0 = no reducer, 0.79 = a 0.79× reducer, 2.0 = a 2× Barlow.',
            hint: '1.0 = no reducer, 0.79 = 0.79x reducer, 2.0 = 2x Barlow',
            suffix: 'x',
            errorText: _reducerError,
            onChanged: () => _commit(_OpticalField.reducer),
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _NumericField(
            controller: _pixelSizeController,
            label: 'Camera pixel size',
            help:
                "Pixel size in microns — from your camera's datasheet; sets your image scale.",
            // Not "not in the camera library": the next step's library supplies
            // this very number, and the two screens contradicting each other
            // about whether it can be looked up is what sent users to a
            // datasheet they did not need.
            hint: "e.g. 3.76 — or load it with your camera on the next step",
            suffix: 'µm',
            errorText: _pixelSizeError,
            onChanged: () => _commit(_OpticalField.pixelSize),
          ),
          // Say where a prefilled number came from. It is the camera library's
          // figure for the sensor the driver named, not a measurement of the
          // user's camera, and it drives image scale, plate-solve field of
          // view and the FITS header — so it has to be attributable and
          // overridable, not silently correct-looking.
          ...?_pixelSizeProvenance(colors, draft),
          const SizedBox(height: SkotiqTokens.spaceXl),
          // Live preview of derived values. A value whose inputs are missing
          // or implausible renders as "—", never as a number the optics do not
          // support; the field that is out of bounds says so itself.
          Container(
            width: double.infinity,
            decoration: SkotiqDecorations.well(colors),
            padding: SkotiqTokens.paddingMd,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Computed'.toUpperCase(),
                  style: SkotiqTypography.eyebrow.copyWith(
                    color: colors.textMuted,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                ReadoutRow(
                  children: [
                    Readout(
                      value: _derived(
                        effectiveFocal?.toStringAsFixed(1),
                        [focalOk, reducerOk],
                      ),
                      unit: 'mm',
                      label: 'Effective focal length',
                    ),
                    Readout(
                      value: _derived(
                        fRatio == null
                            ? null
                            : 'f/${fRatio.toStringAsFixed(2)}',
                        [focalOk, apertureOk, reducerOk, fRatioOk],
                      ),
                      label: 'Focal ratio',
                    ),
                    Readout(
                      value: _derived(
                        imageScale?.toStringAsFixed(2),
                        [focalOk, reducerOk, pixelOk],
                      ),
                      unit: '"/px',
                      label: 'Image scale',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The value to show for a derived quantity, or null for "—".
  ///
  /// [inputs] are the per-input plausibility flags the quantity depends on
  /// (see [_plausible]): null = not entered yet, false = entered but out of
  /// bounds. Any false input withholds the number, so the panel never presents
  /// an implausible result as a computed value — the offending field carries
  /// the reason.
  String? _derived(String? value, List<bool?> inputs) =>
      inputs.contains(false) ? null : value;

  /// True when the optics on screen still describe the telescope the badge
  /// names.
  bool _matchesTelescopePreset(OnboardingDraft draft) =>
      draftMatchesTelescopePreset(
        draft,
        ref.read(hardwarePresetsServiceProvider).allTelescopes(),
      );

  /// One attribution line under the pixel-size field when the value on screen
  /// is the camera library's figure for the camera picked at the camera step.
  ///
  /// Returns null when nothing was prefilled, or when the user has since typed
  /// a different number — the note must never outlive the value it describes.
  List<Widget>? _pixelSizeProvenance(
    SkotiqColors colors,
    OnboardingDraft draft,
  ) {
    final pixelSize = draft.pixelSizeMicrons;
    if (pixelSize == null) return null;
    final preset = ref
        .read(hardwarePresetsServiceProvider)
        .matchCameraByName(draft.cameraName);
    if (preset == null) return null;
    if ((preset.pixelSizeMicrons - pixelSize).abs() > 0.001) return null;
    return [
      const SizedBox(height: SkotiqTokens.spaceXs),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            SkotiqIcons.info,
            size: SkotiqTokens.iconXs,
            color: colors.textMuted,
          ),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: Text(
              'Filled in from ${preset.displayName} in the camera library '
              '(${preset.sensorName}). Edit it if your camera differs.',
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    ];
  }
}

enum _OpticalField { focalLength, aperture, reducer, pixelSize }

/// A labelled numeric input with an inline [FieldHelpLabel].
///
/// The label sits above rather than in a [FormRow] because it carries the
/// help affordance; the field itself is the design system's
/// [SkotiqTextField] in its mono numeric mode.
class _NumericField extends StatelessWidget {
  const _NumericField({
    required this.controller,
    required this.label,
    required this.help,
    required this.hint,
    required this.suffix,
    required this.onChanged,
    this.errorText,
  });

  final TextEditingController controller;
  final String label;
  final String help;
  final String hint;
  final String suffix;
  final String? errorText;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldHelpLabel(label: label, help: help),
        const SizedBox(height: SkotiqTokens.spaceXs),
        SkotiqTextField(
          controller: controller,
          hint: hint,
          suffix: suffix,
          errorText: errorText,
          mono: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          onChanged: (_) => onChanged(),
        ),
      ],
    );
  }
}
