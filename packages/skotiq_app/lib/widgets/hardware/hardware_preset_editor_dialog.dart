import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
// The hardware-presets provider is intentionally not re-exported from the
// skotiq_core barrel (its owner avoided a `cameraPresetsProvider` name
// collision by keeping it private to the package). Import the source path
// directly — the same precedent set by the provider's own test suite.
// ignore: implementation_imports
import 'package:skotiq_core/src/providers/hardware_presets_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../help/field_help_label.dart';

/// Whether the editor is creating/editing a telescope or a camera preset.
enum HardwarePresetKind { telescope, camera }

/// Form dialog to create a new hardware preset or edit an existing one.
///
/// Operates in one of two modes ([HardwarePresetKind]). Required numeric fields
/// are validated on save and surface inline `errorText` rather than silently
/// coercing bad input into a preset the operator did not enter.
///
/// Editing a **built-in** preset never mutates the immutable catalog: the
/// service stores an `isBuiltIn: false` override under the built-in's id, so
/// the saved result reads back as a user-owned copy that the merge prefers
/// over the catalog entry (see [HardwarePresetsNotifier.saveTelescopePreset]).
///
/// On success the saved preset is returned via `Navigator.pop`, typed to the
/// concrete model so callers can chain (e.g. the picker re-selecting the
/// freshly-saved row).
class HardwarePresetEditorDialog extends ConsumerStatefulWidget {
  final HardwarePresetKind kind;

  /// The telescope being edited, or null when creating a new telescope.
  /// Only meaningful when [kind] is [HardwarePresetKind.telescope].
  final TelescopePreset? telescope;

  /// The camera being edited, or null when creating a new camera. Only
  /// meaningful when [kind] is [HardwarePresetKind.camera].
  final CameraDefaultsPreset? camera;

  const HardwarePresetEditorDialog._({
    required this.kind,
    this.telescope,
    this.camera,
  });

  /// Opens the editor for a telescope preset. Pass [initial] to edit an
  /// existing preset (including a built-in, which becomes a user override on
  /// save); omit it to create a new one. Resolves to the saved preset, or
  /// null if the user cancelled.
  static Future<TelescopePreset?> editTelescope(
    BuildContext context, {
    TelescopePreset? initial,
  }) {
    return showDialog<TelescopePreset>(
      context: context,
      builder: (_) => HardwarePresetEditorDialog._(
        kind: HardwarePresetKind.telescope,
        telescope: initial,
      ),
    );
  }

  /// Opens the editor for a camera-defaults preset. See [editTelescope].
  static Future<CameraDefaultsPreset?> editCamera(
    BuildContext context, {
    CameraDefaultsPreset? initial,
  }) {
    return showDialog<CameraDefaultsPreset>(
      context: context,
      builder: (_) => HardwarePresetEditorDialog._(
        kind: HardwarePresetKind.camera,
        camera: initial,
      ),
    );
  }

  @override
  ConsumerState<HardwarePresetEditorDialog> createState() =>
      _HardwarePresetEditorDialogState();
}

class _HardwarePresetEditorDialogState
    extends ConsumerState<HardwarePresetEditorDialog> {
  // Shared identity fields.
  late final TextEditingController _brand;
  late final TextEditingController _model;

  // Telescope fields.
  late final TextEditingController _focalLength;
  late final TextEditingController _aperture;
  late OpticalDesign _design;

  // Camera fields.
  late final TextEditingController _pixelSize;
  late final TextEditingController _sensorWidth;
  late final TextEditingController _sensorHeight;
  late final TextEditingController _sensorName;
  late bool _isColor;
  late final TextEditingController _gain;
  late final TextEditingController _offset;
  late final TextEditingController _binX;
  late final TextEditingController _binY;
  late bool _coolingEnabled;
  late final TextEditingController _coolingTemp;

  /// Field-keyed validation errors populated on a failed save attempt and
  /// cleared as the user edits. A non-empty map blocks persistence.
  final Map<String, String> _errors = {};

  /// True while the async save is in flight, to disable the Save button and
  /// show its spinner.
  bool _saving = false;

  bool get _isTelescope => widget.kind == HardwarePresetKind.telescope;

  bool get _isEditingBuiltIn =>
      (widget.telescope?.isBuiltIn ?? false) ||
      (widget.camera?.isBuiltIn ?? false);

  @override
  void initState() {
    super.initState();
    final tel = widget.telescope;
    final cam = widget.camera;

    _brand = TextEditingController(text: tel?.brand ?? cam?.brand ?? '');
    _model = TextEditingController(text: tel?.model ?? cam?.model ?? '');

    _focalLength = TextEditingController(
      text: tel == null ? '' : _trimNumber(tel.focalLengthMm),
    );
    _aperture = TextEditingController(
      text: tel == null ? '' : _trimNumber(tel.apertureMm),
    );
    _design = tel?.design ?? OpticalDesign.refractor;

    _pixelSize = TextEditingController(
      text: cam == null ? '' : _trimNumber(cam.pixelSizeMicrons),
    );
    _sensorWidth =
        TextEditingController(text: cam == null ? '' : '${cam.sensorWidthPx}');
    _sensorHeight =
        TextEditingController(text: cam == null ? '' : '${cam.sensorHeightPx}');
    _sensorName = TextEditingController(text: cam?.sensorName ?? '');
    _isColor = cam?.isColor ?? true;
    _gain = TextEditingController(
      text: cam == null ? '' : '${cam.recommendedGain}',
    );
    _offset = TextEditingController(
      text: cam == null ? '' : '${cam.recommendedOffset}',
    );
    _binX = TextEditingController(
        text: cam == null ? '1' : '${cam.recommendedBinX}');
    _binY = TextEditingController(
        text: cam == null ? '1' : '${cam.recommendedBinY}');
    _coolingEnabled = cam?.recommendedCoolingTempC != null;
    _coolingTemp = TextEditingController(
      text: cam?.recommendedCoolingTempC == null
          ? ''
          : _trimNumber(cam!.recommendedCoolingTempC!),
    );
  }

  @override
  void dispose() {
    _brand.dispose();
    _model.dispose();
    _focalLength.dispose();
    _aperture.dispose();
    _pixelSize.dispose();
    _sensorWidth.dispose();
    _sensorHeight.dispose();
    _sensorName.dispose();
    _gain.dispose();
    _offset.dispose();
    _binX.dispose();
    _binY.dispose();
    _coolingTemp.dispose();
    super.dispose();
  }

  /// Formats a double for an editable field without a trailing `.0` so the
  /// user sees `550`, not `550.0`, while fractional values keep their digits.
  static String _trimNumber(double value) {
    if (value == value.roundToDouble()) return value.round().toString();
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final title = _isTelescope
        ? (widget.telescope == null ? 'New telescope' : 'Edit telescope')
        : (widget.camera == null ? 'New camera' : 'Edit camera');

    return SkotiqDialog(
      title: title,
      icon: _isTelescope ? LucideIcons.orbit : LucideIcons.camera,
      width: 560,
      closeEnabled: !_saving,
      actions: [
        SkotiqButton(
          label: 'Cancel',
          variant: ButtonVariant.ghost,
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        SkotiqButton(
          label: widget.telescope == null && widget.camera == null
              ? 'Add'
              : 'Save',
          icon: LucideIcons.save,
          isLoading: _saving,
          onPressed: _saving ? null : _save,
        ),
      ],
      child: _isTelescope ? _buildTelescopeForm() : _buildCameraForm(),
    );
  }

  // Telescope form.

  Widget _buildTelescopeForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isEditingBuiltIn) _builtInOverrideNotice(),
        _identityFields(),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _numericField(
                fieldKey: 'focalLength',
                label: 'Focal length (mm)',
                help: 'The optical focal length of the imaging train, in '
                    'millimetres. Combined with pixel size this sets your '
                    'image scale (arcsec/pixel).',
                controller: _focalLength,
                hint: 'e.g. 550',
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: _numericField(
                fieldKey: 'aperture',
                label: 'Aperture (mm)',
                help: 'The clear aperture (primary lens/mirror diameter), in '
                    'millimetres. Focal ratio (f/) is derived from focal '
                    'length ÷ aperture.',
                controller: _aperture,
                hint: 'e.g. 100',
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        const FieldHelpLabel(
          label: 'Optical design',
          help: 'The telescope family. Refractors are flat-field after a '
              'flattener; SCTs and RCs need back-focus discipline.',
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        SkotiqDropdown(
          isExpanded: true,
          value: _design.name,
          items: OpticalDesign.values.map((d) => d.name).toList(),
          itemLabels: OpticalDesign.values.map((d) => d.label).toList(),
          onChanged: (value) {
            if (value == null) return;
            setState(() => _design = OpticalDesign.fromJson(value));
          },
        ),
      ],
    );
  }

  // Camera form.

  Widget _buildCameraForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_isEditingBuiltIn) _builtInOverrideNotice(),
        _identityFields(),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _numericField(
                fieldKey: 'pixelSize',
                label: 'Pixel size (µm)',
                help: 'The physical sensor pixel pitch in microns. Drives '
                    'image scale and sampling.',
                controller: _pixelSize,
                hint: 'e.g. 3.76',
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: _textField(
                fieldKey: 'sensorName',
                label: 'Sensor',
                help: 'Manufacturer sensor part number, e.g. Sony IMX571. Used '
                    'to auto-match a connected camera to this preset.',
                controller: _sensorName,
                hint: 'e.g. Sony IMX571',
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _numericField(
                fieldKey: 'sensorWidth',
                label: 'Sensor width (px)',
                help: 'Horizontal sensor resolution in pixels.',
                controller: _sensorWidth,
                hint: 'e.g. 6248',
                integer: true,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: _numericField(
                fieldKey: 'sensorHeight',
                label: 'Sensor height (px)',
                help: 'Vertical sensor resolution in pixels.',
                controller: _sensorHeight,
                hint: 'e.g. 4176',
                integer: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        SkotiqSwitchRow(
          label: 'Color sensor',
          subtitle: 'One-shot-color (Bayer) rather than monochrome.',
          value: _isColor,
          onChanged: (value) => setState(() => _isColor = value),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _numericField(
                fieldKey: 'gain',
                label: 'Gain',
                helpTitle: 'Recommended gain',
                helpBody: 'The driver gain value used as a starting point for '
                    'this camera. Higher gain lowers read noise but reduces '
                    'full-well capacity.',
                controller: _gain,
                hint: 'e.g. 100',
                integer: true,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: _numericField(
                fieldKey: 'offset',
                label: 'Offset',
                helpTitle: 'Recommended offset',
                helpBody: 'A pedestal added to every pixel so the histogram '
                    'left edge clears zero, preventing black clipping.',
                controller: _offset,
                hint: 'e.g. 50',
                integer: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _numericField(
                fieldKey: 'binX',
                label: 'Bin X',
                help: 'Default horizontal binning factor (1 = native '
                    'resolution).',
                controller: _binX,
                hint: '1',
                integer: true,
              ),
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: _numericField(
                fieldKey: 'binY',
                label: 'Bin Y',
                help: 'Default vertical binning factor (1 = native '
                    'resolution).',
                controller: _binY,
                hint: '1',
                integer: true,
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        SkotiqSwitchRow(
          label: 'Regulated cooling',
          subtitle: 'Has a set-point thermoelectric cooler (TEC).',
          value: _coolingEnabled,
          onChanged: (value) => setState(() {
            _coolingEnabled = value;
            if (!value) _errors.remove('coolingTemp');
          }),
        ),
        if (_coolingEnabled) ...[
          const SizedBox(height: SkotiqTokens.spaceMd),
          _numericField(
            fieldKey: 'coolingTemp',
            label: 'Cooling set-point (°C)',
            help: 'The target sensor temperature, in degrees Celsius. Negative '
                'values are typical (e.g. -10).',
            controller: _coolingTemp,
            hint: 'e.g. -10',
          ),
        ],
      ],
    );
  }

  // Shared field builders.

  Widget _identityFields() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _textField(
            fieldKey: 'brand',
            label: 'Brand',
            help: 'Manufacturer or brand, e.g. ZWO, Sky-Watcher.',
            controller: _brand,
            hint: _isTelescope ? 'e.g. Sky-Watcher' : 'e.g. ZWO',
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: _textField(
            fieldKey: 'model',
            label: 'Model',
            help: 'Product model name, e.g. Esprit 100ED, ASI2600MM Pro.',
            controller: _model,
            hint: _isTelescope ? 'e.g. Esprit 100ED' : 'e.g. ASI2600MM Pro',
          ),
        ),
      ],
    );
  }

  Widget _builtInOverrideNotice() {
    return const Padding(
      padding: EdgeInsets.only(bottom: SkotiqTokens.spaceLg),
      child: SkotiqInlineBanner(
        message: 'This is a built-in preset. Saving creates your own editable '
            'copy; the original stays available.',
        severity: SkotiqAlertSeverity.info,
      ),
    );
  }

  Widget _textField({
    required String fieldKey,
    required String label,
    required TextEditingController controller,
    String? help,
    String? helpTitle,
    String? helpBody,
    String? hint,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldHelpLabel(
          label: label,
          help: help,
          helpTitle: helpTitle,
          helpBody: helpBody,
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        SkotiqTextField(
          controller: controller,
          hint: hint,
          errorText: _errors[fieldKey],
          onChanged: (_) => _clearError(fieldKey),
        ),
      ],
    );
  }

  Widget _numericField({
    required String fieldKey,
    required String label,
    required TextEditingController controller,
    String? help,
    String? helpTitle,
    String? helpBody,
    String? hint,
    bool integer = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FieldHelpLabel(
          label: label,
          help: help,
          helpTitle: helpTitle,
          helpBody: helpBody,
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        SkotiqTextField(
          controller: controller,
          hint: hint,
          errorText: _errors[fieldKey],
          keyboardType: TextInputType.numberWithOptions(
            decimal: !integer,
            // Allow leading minus for the cooling set-point.
            signed: fieldKey == 'coolingTemp',
          ),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
              integer ? RegExp(r'[0-9-]') : RegExp(r'[0-9.\-]'),
            ),
          ],
          onChanged: (_) => _clearError(fieldKey),
        ),
      ],
    );
  }

  void _clearError(String fieldKey) {
    if (_errors.containsKey(fieldKey)) {
      setState(() => _errors.remove(fieldKey));
    }
  }

  // Validation + persistence.

  Future<void> _save() async {
    final errors = <String, String>{};

    String requireText(TextEditingController c, String key, String label) {
      final value = c.text.trim();
      if (value.isEmpty) errors[key] = '$label is required';
      return value;
    }

    double requirePositiveDouble(
      TextEditingController c,
      String key,
      String label,
    ) {
      final raw = c.text.trim();
      final parsed = double.tryParse(raw);
      if (parsed == null || !parsed.isFinite) {
        errors[key] = 'Enter a valid number';
        return 0;
      }
      if (parsed <= 0) {
        errors[key] = '$label must be greater than zero';
        return 0;
      }
      return parsed;
    }

    int requirePositiveInt(
      TextEditingController c,
      String key,
      String label,
    ) {
      final raw = c.text.trim();
      final parsed = int.tryParse(raw);
      if (parsed == null) {
        errors[key] = 'Enter a whole number';
        return 0;
      }
      if (parsed <= 0) {
        errors[key] = '$label must be at least 1';
        return 0;
      }
      return parsed;
    }

    int requireNonNegativeInt(
      TextEditingController c,
      String key,
      String label,
    ) {
      final raw = c.text.trim();
      final parsed = int.tryParse(raw);
      if (parsed == null) {
        errors[key] = 'Enter a whole number';
        return 0;
      }
      if (parsed < 0) {
        errors[key] = '$label cannot be negative';
        return 0;
      }
      return parsed;
    }

    final brand = requireText(_brand, 'brand', 'Brand');
    final model = requireText(_model, 'model', 'Model');

    if (_isTelescope) {
      final focalLength =
          requirePositiveDouble(_focalLength, 'focalLength', 'Focal length');
      final aperture = requirePositiveDouble(_aperture, 'aperture', 'Aperture');

      // A saved preset prefills the equipment profile editor and drives the
      // planetarium FOV overlay, so it needs the same physical plausibility
      // bounds a profile has. `> 0` alone accepted 999999999 mm at 0.0001 mm,
      // i.e. f/9999999990000. Bounds and wording both come from the shared
      // ProfileValidator/OpticalTrainLimits contract so this surface cannot
      // drift from the profile editors.
      if (errors.isEmpty) {
        final focalBound = ProfileValidator.parseFocalLength(_focalLength.text);
        if (!focalBound.isValid) errors['focalLength'] = focalBound.error!;
        final apertureBound = ProfileValidator.parseAperture(_aperture.text);
        if (!apertureBound.isValid) errors['aperture'] = apertureBound.error!;
        if (errors.isEmpty) {
          // Individually in-range values can still describe an impossible
          // system; the ratio belongs to the pair, so report it on focal length.
          final trainError = ProfileValidator.validateOpticalTrain(
            focalLengthMm: focalLength,
            apertureMm: aperture,
          );
          if (trainError != null) errors['focalLength'] = trainError;
        }
      }

      if (errors.isNotEmpty) {
        setState(() => _errors
          ..clear()
          ..addAll(errors));
        return;
      }

      final existing = widget.telescope;
      final preset = TelescopePreset(
        // Editing a built-in keeps its (stable) id so the override replaces it
        // in the merge; the notifier forces isBuiltIn:false. A brand-new
        // preset gets a fresh opaque id.
        id: existing != null ? existing.id : newHardwarePresetId(),
        brand: brand,
        model: model,
        focalLengthMm: focalLength,
        apertureMm: aperture,
        design: _design,
        nativeFocalRatio: existing?.nativeFocalRatio,
        isBuiltIn: false,
      );

      await _persist(() async {
        await ref
            .read(hardwarePresetsServiceProvider.notifier)
            .saveTelescopePreset(preset);
        return preset;
      });
      return;
    }

    // Camera mode.
    final pixelSize =
        requirePositiveDouble(_pixelSize, 'pixelSize', 'Pixel size');
    final sensorWidth =
        requirePositiveInt(_sensorWidth, 'sensorWidth', 'Sensor width');
    final sensorHeight =
        requirePositiveInt(_sensorHeight, 'sensorHeight', 'Sensor height');
    final sensorName = requireText(_sensorName, 'sensorName', 'Sensor');
    final gain = requireNonNegativeInt(_gain, 'gain', 'Gain');
    final offset = requireNonNegativeInt(_offset, 'offset', 'Offset');
    final binX = requirePositiveInt(_binX, 'binX', 'Bin X');
    final binY = requirePositiveInt(_binY, 'binY', 'Bin Y');

    // Pixel size feeds the arcsec/px image scale wherever this preset is
    // applied, so it carries the same shared bound as a profile's pixel size.
    if (!errors.containsKey('pixelSize')) {
      final pixelError = ProfileValidator.validateOpticalTrain(
        focalLengthMm: 0,
        apertureMm: 0,
        pixelSizeMicrons: pixelSize,
      );
      if (pixelError != null) errors['pixelSize'] = pixelError;
    }

    double? coolingTemp;
    if (_coolingEnabled) {
      final raw = _coolingTemp.text.trim();
      final parsed = double.tryParse(raw);
      if (parsed == null || !parsed.isFinite) {
        errors['coolingTemp'] = 'Enter a valid temperature';
      } else {
        coolingTemp = parsed;
      }
    }

    if (errors.isNotEmpty) {
      setState(() => _errors
        ..clear()
        ..addAll(errors));
      return;
    }

    final existing = widget.camera;
    final preset = CameraDefaultsPreset(
      id: existing != null ? existing.id : newHardwarePresetId(),
      brand: brand,
      model: model,
      // Preserve any auto-match aliases the built-in/edited preset carried so
      // name-matching keeps working after an edit.
      aliases: existing?.aliases ?? const [],
      pixelSizeMicrons: pixelSize,
      sensorWidthPx: sensorWidth,
      sensorHeightPx: sensorHeight,
      sensorName: sensorName,
      isColor: _isColor,
      recommendedGain: gain,
      recommendedOffset: offset,
      broadbandGain: existing?.broadbandGain,
      broadbandOffset: existing?.broadbandOffset,
      narrowbandGain: existing?.narrowbandGain,
      narrowbandOffset: existing?.narrowbandOffset,
      recommendedBinX: binX,
      recommendedBinY: binY,
      recommendedCoolingTempC: coolingTemp,
      isBuiltIn: false,
    );

    await _persist(() async {
      await ref
          .read(hardwarePresetsServiceProvider.notifier)
          .saveCameraPreset(preset);
      return preset;
    });
  }

  /// Runs [action] (the save), guarding the in-flight flag and surfacing any
  /// persistence failure as an [ErrorDialog] rather than swallowing it. On
  /// success the saved preset is returned through [Navigator.pop].
  Future<void> _persist<T>(Future<T> Function() action) async {
    setState(() {
      _errors.clear();
      _saving = true;
    });
    try {
      final saved = await action();
      if (!mounted) return;
      Navigator.of(context).pop(saved);
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() => _saving = false);
      // Fire-and-forget: the error dialog is informational; we do not block the
      // editor on its dismissal.
      unawaited(
        ErrorDialog.show(
          context,
          title: 'Could not save preset',
          message: 'The hardware preset could not be saved.',
          technicalDetails: '$error\n$stackTrace',
        ),
      );
    }
  }
}
