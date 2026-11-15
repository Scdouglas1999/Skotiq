import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../utils/snackbar_helper.dart';
import '../../../widgets/hardware/hardware_preset_picker_dialog.dart';
import '../../../widgets/help/field_help_label.dart';
import '../../../widgets/sensitivity_field.dart';
import '../utils/profile_save_errors.dart';
import '../widgets/profile_glyph.dart';
import '../../../utils/count_label.dart';
import '../../../utils/device_format_utils.dart';
import 'package:skotiq_astro/skotiq_astro.dart';

part 'profile_editor_dialog/profile_data_operations.dart';
part 'profile_editor_dialog/shell_and_identity.dart';
part 'profile_editor_dialog/optical_and_devices.dart';
part 'profile_editor_dialog/filters_and_camera_defaults.dart';
part 'profile_editor_dialog/helper_widgets.dart';

/// Widest the Profiles tab's editor column gets: a form never stretches past
/// about 880 px, and its fields are capped well inside that
/// ([profileEditorFieldMaxWidth]).
const double profilePageMaxWidth = 880.0;

/// Stable keys for the profile editor's inline field errors.
///
/// Kept as constants (not an enum) because they double as the map keys the
/// section builders read, and widget tests match on them.
abstract final class ProfileEditorField {
  static const focalLength = 'focalLength';
  static const reducer = 'reducer';
  static const aperture = 'aperture';
  static const gain = 'gain';
  static const offset = 'offset';
  static const coolingTarget = 'coolingTarget';
  static const centeringExposure = 'centeringExposure';
}

enum ProfileEditorMode {
  /// The whole editor, as a dialog (desktop) or a full-screen route (phone).
  full,

  /// The whole editor, embedded as a page beside the profile list — the
  /// Equipment screen's "Profiles" tab. Same sections as [full] and the same
  /// save path, without the dialog chrome or the pop: the selected profile is
  /// edited in place next to the list it was picked from.
  profilePage,
}

/// Single-page profile editor dialog replacing the multi-step wizard.
/// Allows creating new profiles or editing existing ones.
class ProfileEditorDialog extends ConsumerStatefulWidget {
  /// The profile to edit, or null to create a new profile.
  final EquipmentProfileModel? profile;

  final ProfileEditorMode mode;

  const ProfileEditorDialog({
    super.key,
    this.profile,
    this.mode = ProfileEditorMode.full,
  });

  /// Show the profile editor.
  ///
  /// On a phone (`width < 600`) this is a full-screen route — the editor is a
  /// long, multi-section form, so a centered dialog would be cramped. On
  /// tablet/desktop it stays the centered, viewport-capped dialog.
  /// Returns true if a profile was created/updated, false/null if cancelled.
  static Future<bool?> show(BuildContext context,
      {EquipmentProfileModel? profile}) {
    if (Responsive.isPhone(context)) {
      return Navigator.of(context, rootNavigator: true).push<bool>(
        MaterialPageRoute<bool>(
          fullscreenDialog: true,
          builder: (_) => ProfileEditorDialog(profile: profile),
        ),
      );
    }
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => ProfileEditorDialog(profile: profile),
    );
  }

  @override
  ConsumerState<ProfileEditorDialog> createState() =>
      _ProfileEditorDialogState();
}

class _ProfileEditorDialogState extends ConsumerState<ProfileEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  bool _isSaving = false;

  // Inline validation error for the Profile Name field. Set by [_validateForm]
  // when the trimmed name is blank or too long, cleared as soon as the user
  // edits the field.
  String? _nameError;

  /// Per-field inline validation errors, keyed by the constants in
  /// [ProfileEditorField]. Every field's error renders inline: a snackbar sits
  /// OUTSIDE and BELOW the dialog, dimmed by the modal barrier to ~2.00:1
  /// contrast against the 4.5:1 WCAG AA wants for body text, so it is not a
  /// readable way to report which field is wrong.
  final Map<String, String?> _fieldErrors = <String, String?>{};

  /// Errors that belong to no single field (optical-train cross-check, per-filter
  /// row problems). Rendered as a persistent banner INSIDE the dialog so the
  /// feedback cannot be dismissed by a timeout or dimmed by the scrim.
  List<String> _formErrors = const <String>[];

  /// Clears the inline error for [field] as soon as the user edits it, matching
  /// the name field's existing behaviour.
  void clearFieldError(String field) {
    if (_fieldErrors[field] == null) return;
    setState(() => _fieldErrors.remove(field));
  }

  final Map<String, bool> _expandedSections = {
    'identity': true,
    'optical': true,
    'devices': true,
    'filters': true,
    'camera': true,
  };

  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  String _selectedIcon = '';
  Color? _selectedColor;
  bool _isDefault = false;

  /// Whether the user flipped the Default profile switch in this editor.
  /// Until they do, the switch follows the stored profile and Save leaves the
  /// startup choice as it is, wherever else it was changed.
  bool _isDefaultTouched = false;

  /// [_formSignature] as loaded or last saved; Save is enabled only when the
  /// form differs from it.
  String _savedSignature = '';

  // Section 2: Optical Train
  //
  // `_focalLengthController` holds the OTA's NATIVE focal length and
  // `_reducerController` the reducer/barlow multiplier; the profile's
  // `focalLength` column is their product (see [_effectiveFocalLengthMm]).
  final _telescopeNameController = TextEditingController();
  final _focalLengthController = TextEditingController();
  final _reducerController = TextEditingController();
  final _apertureController = TextEditingController();

  final _cameraNameController = TextEditingController();
  final _mountNameController = TextEditingController();
  final _focuserNameController = TextEditingController();
  final _filterWheelNameController = TextEditingController();
  final _guiderNameController = TextEditingController();
  final _guideCameraNameController = TextEditingController();
  final _guideFocalLengthController = TextEditingController();
  final _rotatorNameController = TextEditingController();
  // Dome/weather/cover-calibrator have no persisted friendly-name column, so
  // their rows show only the device id (no name controller).
  final _safetyMonitorNameController = TextEditingController();
  final _switchNameController = TextEditingController();

  String? _cameraId;
  String? _mountId;
  String? _focuserId;
  String? _filterWheelId;
  String? _guiderId;
  String? _guideCameraId;
  String? _rotatorId;
  String? _domeId;
  String? _weatherId;
  String? _safetyMonitorId;
  String? _switchId;
  String? _coverCalibratorId;

  final List<_FilterControllerPair> _filterControllers = [];

  final _gainController = TextEditingController();
  final _offsetController = TextEditingController();
  int _binning = 1;
  final _coolingTargetController = TextEditingController();
  bool _coolOnConnect = false;
  final _centeringExposureController = TextEditingController();

  // Auto-detect state for the camera's SDK-reported gain/offset.
  // `null` means "not queried yet". An empty struct (all-None) means
  // "SDK reported nothing" and is displayed as such.
  CameraRecommendedSettings? _recommendedSettings;
  bool _isQueryingRecommendation = false;

  /// The icon choices: none (the default aperture), then every glyph.
  static final List<String> _availableIcons = ['', ...profileGlyphs.keys];

  static const List<Color> _accentColors = [
    EquipmentProfileColors.defaultProfile, // Cyan-blue (default)
    EquipmentProfileColors.sky, // Sky
    EquipmentProfileColors.pink, // Pink
    SciencePlotColors.clipHigh, // Red
    EquipmentProfileColors.orange, // Orange
    EquipmentProfileColors.yellow, // Yellow
    SciencePlotColors.highConfidence, // Green
    EquipmentProfileColors.cyan, // Cyan
    EquipmentProfileColors.blue, // Blue
  ];

  @override
  void initState() {
    super.initState();
    _initializeFromProfile();
    _savedSignature = _formSignature();
  }

  @override
  void didUpdateWidget(covariant ProfileEditorDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    final stored = widget.profile?.isDefault;
    if (!_isDefaultTouched && stored != null && stored != _isDefault) {
      _isDefault = stored;
    }
  }

  /// Every value the form saves except the Default switch, which is compared
  /// on its own against the stored profile.
  String _formSignature() => <Object?>[
        _nameController.text,
        _descriptionController.text,
        _selectedIcon,
        _selectedColor?.toARGB32(),
        _telescopeNameController.text,
        _focalLengthController.text,
        _reducerController.text,
        _apertureController.text,
        _cameraId,
        _cameraNameController.text,
        _mountId,
        _mountNameController.text,
        _focuserId,
        _focuserNameController.text,
        _filterWheelId,
        _filterWheelNameController.text,
        _guiderId,
        _guiderNameController.text,
        _guideCameraId,
        _guideCameraNameController.text,
        _guideFocalLengthController.text,
        _rotatorId,
        _rotatorNameController.text,
        _domeId,
        _weatherId,
        _safetyMonitorId,
        _safetyMonitorNameController.text,
        _switchId,
        _switchNameController.text,
        _coverCalibratorId,
        for (final pair in _filterControllers) ...<String>[
          pair.nameController.text,
          pair.offsetController.text,
        ],
        _gainController.text,
        _offsetController.text,
        _binning,
        _coolingTargetController.text,
        _coolOnConnect,
        _centeringExposureController.text,
      ].join('\u0000');

  /// Whether Save has anything to write. A new profile always does.
  bool get _hasUnsavedChanges =>
      widget.profile == null ||
      (_isDefaultTouched && _isDefault != widget.profile!.isDefault) ||
      _formSignature() != _savedSignature;

  /// The text fields whose edits change [_hasUnsavedChanges].
  Listenable get _formListenable => Listenable.merge(<Listenable>[
        _nameController,
        _descriptionController,
        _telescopeNameController,
        _focalLengthController,
        _reducerController,
        _apertureController,
        _cameraNameController,
        _mountNameController,
        _focuserNameController,
        _filterWheelNameController,
        _guiderNameController,
        _guideCameraNameController,
        _guideFocalLengthController,
        _rotatorNameController,
        _safetyMonitorNameController,
        _switchNameController,
        for (final pair in _filterControllers) ...<Listenable>[
          pair.nameController,
          pair.offsetController,
        ],
        _gainController,
        _offsetController,
        _coolingTargetController,
        _centeringExposureController,
      ]);

  /// The default flag a save writes: the user's choice when they made one,
  /// otherwise what is stored.
  bool _defaultToSave(bool stored) => _isDefaultTouched ? _isDefault : stored;

  void _initializeFromProfile() {
    final profile = widget.profile;
    if (profile != null) {
      _nameController.text = profile.name;
      _descriptionController.text = profile.description ?? '';
      // A word this build does not offer (an emoji from an older build)
      // reads as no icon, which is what the list shows for it.
      final icon = profile.profileIcon;
      _selectedIcon = profileGlyphs.containsKey(icon) ? icon! : '';
      _selectedColor =
          profile.profileColor != null ? Color(profile.profileColor!) : null;
      _isDefault = profile.isDefault;

      // Section 2: Optical Train
      //
      // The profile carries the optical train as a PAIR: `telescopeFocalLength`
      // is the OTA's native focal length and `focalLength` is what the rig
      // actually images at (post reducer/barlow) — it is `focalLength` that
      // reaches the FITS FOCALLEN card, the plate-solve scale hint, the framing
      // FOV and the guider px->arcsec conversion. The two must stay distinct:
      // writing one number into both collapses a reducer'd profile back to its
      // native focal length on any save. The row has no reducer column, so the
      // reducer is reconstructed from the ratio the pair already encodes and
      // the pair round-trips.
      _telescopeNameController.text = profile.telescopeName ?? '';
      final nativeFocalLength = profile.telescopeFocalLength != null &&
              profile.telescopeFocalLength! > 0
          ? profile.telescopeFocalLength!
          : (profile.focalLength > 0 ? profile.focalLength : null);
      if (nativeFocalLength != null) {
        _focalLengthController.text = nativeFocalLength.toString();
      }
      _reducerController.text = _formatReducer(
        nativeFocalLength != null && profile.focalLength > 0
            ? _roundOptic(profile.focalLength / nativeFocalLength)
            : 1.0,
      );
      if (profile.telescopeAperture != null && profile.telescopeAperture! > 0) {
        _apertureController.text = profile.telescopeAperture!.toString();
      } else if (profile.aperture > 0) {
        _apertureController.text = profile.aperture.toString();
      }

      _cameraId = profile.cameraId;
      _cameraNameController.text = profile.cameraName ?? '';
      _mountId = profile.mountId;
      _mountNameController.text = profile.mountName ?? '';
      _focuserId = profile.focuserId;
      _focuserNameController.text = profile.focuserName ?? '';
      _filterWheelId = profile.filterWheelId;
      _filterWheelNameController.text = profile.filterWheelName ?? '';
      _guiderId = profile.guiderId;
      _guiderNameController.text = profile.guiderName ?? '';
      _guideCameraId = profile.guideCameraId;
      _guideCameraNameController.text = profile.guideCameraName ?? '';
      final guideFocal = profile.guideFocalLength;
      _guideFocalLengthController.text = guideFocal != null && guideFocal > 0
          ? (guideFocal == guideFocal.roundToDouble()
              ? guideFocal.round().toString()
              : guideFocal.toString())
          : '';
      _rotatorId = profile.rotatorId;
      _rotatorNameController.text = profile.rotatorName ?? '';
      _domeId = profile.domeId;
      _weatherId = profile.weatherId;
      _safetyMonitorId = profile.safetyMonitorId;
      _safetyMonitorNameController.text = profile.safetyMonitorName ?? '';
      _switchId = profile.switchId;
      _switchNameController.text = profile.switchName ?? '';
      _coverCalibratorId = profile.coverCalibratorId;

      for (int i = 0; i < profile.filterNames.length; i++) {
        final offset = profile.filterFocusOffsets[profile.filterNames[i]] ?? 0;
        _filterControllers.add(_FilterControllerPair(
          nameController: TextEditingController(text: profile.filterNames[i]),
          offsetController: TextEditingController(text: offset.toString()),
        ));
      }

      if (profile.defaultGain != null) {
        _gainController.text = profile.defaultGain!.toString();
      }
      if (profile.defaultOffset != null) {
        _offsetController.text = profile.defaultOffset!.toString();
      }
      _binning = profile.defaultBinX;
      if (profile.defaultCoolingTemp != null) {
        _coolingTargetController.text = profile.defaultCoolingTemp!.toString();
      }
      _coolOnConnect = profile.coolOnConnect;
      if (profile.defaultCenteringExposure != null) {
        _centeringExposureController.text =
            profile.defaultCenteringExposure!.toString();
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _telescopeNameController.dispose();
    _focalLengthController.dispose();
    _reducerController.dispose();
    _apertureController.dispose();
    _cameraNameController.dispose();
    _mountNameController.dispose();
    _focuserNameController.dispose();
    _filterWheelNameController.dispose();
    _guiderNameController.dispose();
    _guideCameraNameController.dispose();
    _guideFocalLengthController.dispose();
    _rotatorNameController.dispose();
    _safetyMonitorNameController.dispose();
    _switchNameController.dispose();
    _gainController.dispose();
    _offsetController.dispose();
    _coolingTargetController.dispose();
    _centeringExposureController.dispose();
    for (final pair in _filterControllers) {
      pair.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final theme = Theme.of(context);
    final isEditing = widget.profile != null;
    final isPhone = Responsive.isPhone(context);

    // The form itself — the same body whether it is shown as a dialog or as a
    // full-screen route.
    final body = Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildValidationBanner(colors),
          _buildIdentitySection(colors, theme),
          const SizedBox(height: SkotiqTokens.space2xl),
          _buildOpticalTrainSection(colors, theme),
          const SizedBox(height: SkotiqTokens.space2xl),
          _buildDevicesSection(colors, theme),
          if (_filterWheelId != null) ...[
            const SizedBox(height: SkotiqTokens.space2xl),
            _buildFiltersSection(colors, theme),
          ],
          const SizedBox(height: SkotiqTokens.space2xl),
          _buildCameraDefaultsSection(colors, theme),
        ],
      ),
    );

    // Embedded as the Equipment screen's Profiles tab: every section on the
    // page's own background beside the profile list, with no dialog chrome and
    // no pop (see [_closeAfterSave]). Save sits in the pane's head above the
    // form, where it stays in view while the form scrolls; there is nothing to
    // cancel back to when the pane simply shows the selected row.
    if (widget.mode == ProfileEditorMode.profilePage) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPageHead(colors),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                SkotiqTokens.space2xl,
                SkotiqTokens.spaceLg,
                SkotiqTokens.space2xl,
                SkotiqTokens.spaceXl,
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: profilePageMaxWidth),
                  child: body,
                ),
              ),
            ),
          ),
        ],
      );
    }

    final title = isEditing ? 'Edit profile' : 'New profile';

    // Phone: the editor is presented as a full-screen route (see [show]). The
    // dialog's own chrome — title, scrolling body, right-aligned footer — is
    // reused without the card frame, so the two presentations cannot drift.
    if (isPhone) {
      return Scaffold(
        backgroundColor: colors.background,
        body: SafeArea(
          child: SkotiqDialogSurface(
            title: title,
            closeEnabled: !_isSaving,
            onClose: () => Navigator.of(context).pop(false),
            actions: _footerActions(),
            child: body,
          ),
        ),
      );
    }

    // Tablet/desktop: the standard dialog anatomy (05 §13) at the form width.
    return SkotiqDialog(
      title: title,
      width: SkotiqDialog.widthForm,
      closeEnabled: !_isSaving,
      onClose: () => Navigator.of(context).pop(false),
      actions: _footerActions(),
      child: body,
    );
  }
}
