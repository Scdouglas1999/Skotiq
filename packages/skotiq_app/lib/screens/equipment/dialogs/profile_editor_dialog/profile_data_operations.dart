// ignore_for_file: invalid_use_of_protected_member

part of '../profile_editor_dialog.dart';

/// Normalized, validated form values produced by
/// [_ProfileEditorDataOperations._validateForm] for the profile a save builds.
class _ParsedProfileForm {
  final String name;

  /// The EFFECTIVE focal length (`telescopeFocalLength * reducerFactor`) — the
  /// value the rig images at, and the one the FITS FOCALLEN card, the
  /// plate-solve scale hint and the framing FOV all read.
  ///
  /// `0` means "unspecified" (the model sentinel); any other value is finite
  /// and strictly positive.
  final double focalLength;

  /// The OTA's NATIVE focal length as typed, before the reducer/barlow. Same
  /// `0`-means-unspecified sentinel.
  final double telescopeFocalLength;

  final double aperture;
  final double? focalRatio;

  final int? gain;
  final int? offset;
  final int binning;
  final double? coolingTemp;
  final double? centeringExposure;

  final List<String> filterNames;
  final Map<String, int> filterOffsets;

  const _ParsedProfileForm({
    required this.name,
    required this.focalLength,
    required this.telescopeFocalLength,
    required this.aperture,
    required this.focalRatio,
    required this.gain,
    required this.offset,
    required this.binning,
    required this.coolingTemp,
    required this.centeringExposure,
    required this.filterNames,
    required this.filterOffsets,
  });
}

/// Parse the reducer/barlow multiplier as typed in the Optical Train section.
///
/// Blank means `1.0` ("no reducer") — the same shape the onboarding draft uses.
/// Bounds come from the shared [OpticalTrainLimits] window rather than a local
/// constant so this editor cannot drift to a looser range than the wizard.
ProfileFieldResult<double> _parseReducerFactor(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return const ProfileFieldResult.ok(1.0);
  final parsed = double.tryParse(trimmed);
  if (parsed == null || !parsed.isFinite || parsed <= 0) {
    return const ProfileFieldResult.fail(
      'Reducer / barlow must be a positive number (leave blank for none)',
    );
  }
  if (parsed < OpticalTrainLimits.minReducerFactor ||
      parsed > OpticalTrainLimits.maxReducerFactor) {
    return ProfileFieldResult.fail(
      'Reducer / barlow must be between '
      '${_formatReducer(OpticalTrainLimits.minReducerFactor)} and '
      '${_formatReducer(OpticalTrainLimits.maxReducerFactor)}',
    );
  }
  return ProfileFieldResult.ok(parsed);
}

/// Round an optical quantity to 4 decimal places.
///
/// A focal length in millimetres is never known to better than that, and the
/// raw product carries binary-float noise (`550 * 0.8 == 440.00000000000006`)
/// that would otherwise make an open-and-save cycle rewrite the very row it
/// just read — the same "a no-op save mutates the profile" shape this section
/// exists to prevent.
double _roundOptic(double value) => double.parse(value.toStringAsFixed(4));

/// Effective focal length of the imaging train: the OTA's native focal length
/// times the reducer/barlow. `1.0` is passed through untouched so a rig with no
/// reducer keeps the exact number the user typed.
double _effectiveFocalLengthOf(double focalLengthMm, double reducerFactor) {
  if (reducerFactor == 1.0) return focalLengthMm;
  return _roundOptic(focalLengthMm * reducerFactor);
}

/// Render a reducer factor the way a user would type it: `1`, `0.8`, `2`.
String _formatReducer(double value) => value == value.roundToDouble()
    ? value.round().toString()
    : value.toString();

extension _ProfileEditorDataOperations on _ProfileEditorDialogState {
  /// The focal length the rig actually images at — the typed OTA focal length
  /// scaled by the typed reducer/barlow. Null when either is unusable.
  ///
  /// Every derived optical readout below goes through this rather than the raw
  /// focal-length field, so the preview cannot claim an f-ratio or image scale
  /// the saved profile does not have.
  double? get _effectiveFocalLengthMm {
    final focalLength = double.tryParse(_focalLengthController.text.trim());
    if (focalLength == null || !focalLength.isFinite || focalLength <= 0) {
      return null;
    }
    final reducer = _parseReducerFactor(_reducerController.text);
    if (!reducer.isValid) return null;
    return _effectiveFocalLengthOf(focalLength, reducer.value!);
  }

  // Computed values for optical train.
  //
  // Returns null — so the readout shows `---` rather than a number — whenever
  // the typed pair does not describe a physically possible system. Reporting
  // `f/9999999990000.0` back to the user as if it were a derived fact is what
  // made the unbounded input look accepted in the first place; the same
  // [OpticalTrainLimits] window that gates the save gates the preview.
  double? get _computedFRatio {
    final focalLength = _effectiveFocalLengthMm;
    final aperture = double.tryParse(_apertureController.text);
    if (focalLength == null || aperture == null || aperture <= 0) return null;
    final ratio = focalLength / aperture;
    if (!ratio.isFinite ||
        ratio < OpticalTrainLimits.minFRatio ||
        ratio > OpticalTrainLimits.maxFRatio) {
      return null;
    }
    return ratio;
  }

  double? get _computedScale {
    final focalLength = _effectiveFocalLengthMm;
    if (focalLength == null || focalLength <= 0) return null;
    // The connected camera's pixel pitch, when it is the camera this profile
    // uses: a new profile with no camera chosen has no image scale yet.
    final cameraState = ref.read(cameraStateProvider);
    if (cameraState.connectionState == DeviceConnectionState.connected &&
        cameraState.deviceId != null &&
        cameraState.deviceId == _cameraId) {
      final capabilitiesAsync =
          ref.read(cameraCapabilitiesProvider(cameraState.deviceId!));
      final capabilities = capabilitiesAsync.valueOrNull;
      final pixelSize = capabilities?.pixelSizeX;
      if (pixelSize != null && pixelSize > 0) {
        return FOVCalculator.calculateImageScale(
          pixelSizeMicrons: pixelSize,
          focalLengthMm: focalLength,
        );
      }
    }
    return null;
  }

  double? get _pixelSize {
    final cameraState = ref.read(cameraStateProvider);
    if (cameraState.connectionState == DeviceConnectionState.connected &&
        cameraState.deviceId != null &&
        cameraState.deviceId == _cameraId) {
      final capabilitiesAsync =
          ref.read(cameraCapabilitiesProvider(cameraState.deviceId!));
      final capabilities = capabilitiesAsync.valueOrNull;
      final pixelSize = capabilities?.pixelSizeX;
      if (pixelSize != null && pixelSize > 0) {
        return pixelSize;
      }
    }
    return null;
  }

  void _addFilter() {
    setState(() {
      _filterControllers.add(_FilterControllerPair(
        nameController: TextEditingController(
            text: 'Filter ${_filterControllers.length + 1}'),
        offsetController: TextEditingController(text: '0'),
      ));
    });
  }

  void _removeFilter(int index) {
    setState(() {
      _filterControllers[index].dispose();
      _filterControllers.removeAt(index);
    });
  }

  Future<void> _autoDetectFilters() async {
    final filterWheelState = ref.read(filterWheelStateProvider);
    if (filterWheelState.connectionState != DeviceConnectionState.connected) {
      return;
    }

    final deviceId = filterWheelState.deviceId;
    if (deviceId == null || deviceId.isEmpty) {
      return;
    }

    // Read filter names directly from hardware to avoid profile-overridden state
    // (which may have a different count than the actual wheel)
    List<String> filterNames;
    try {
      final backend = ref.read(deviceBackendProvider);
      final status = await backend.getFilterWheelStatus(deviceId);
      filterNames = status.filterNames;
    } catch (error, stack) {
      ref.read(loggingServiceProvider).warning(
        'ProfileEditorDialog: hardware filter-name query failed for '
        '$deviceId. Falling back to cached provider state. Error=$error',
        source: 'ProfileEditorDialog',
        fields: {'error': error.toString(), 'stack': stack.toString()},
      );
      filterNames = filterWheelState.filterNames;
    }

    if (!mounted) return;
    if (filterNames.isEmpty) {
      context.showInfoSnackBar('The filter wheel reported no filter names.');
      return;
    }
    setState(() {
      for (final pair in _filterControllers) {
        pair.dispose();
      }
      _filterControllers.clear();
      for (final name in filterNames) {
        _filterControllers.add(_FilterControllerPair(
          nameController: TextEditingController(text: name),
          offsetController: TextEditingController(text: '0'),
        ));
      }
    });
  }

  void _populateFromConnected() {
    final cameraState = ref.read(cameraStateProvider);
    final mountState = ref.read(mountStateProvider);
    final focuserState = ref.read(focuserStateProvider);
    final filterWheelState = ref.read(filterWheelStateProvider);
    final guiderState = ref.read(guiderStateProvider);
    final rotatorState = ref.read(rotatorStateProvider);
    final domeState = ref.read(domeStateProvider);
    final weatherState = ref.read(weatherStateProvider);
    final safetyMonitorState = ref.read(safetyMonitorStateProvider);
    final switchState = ref.read(switchStateProvider);
    final coverCalibratorState = ref.read(coverCalibratorStateProvider);

    setState(() {
      if (_cameraId == null &&
          cameraState.connectionState == DeviceConnectionState.connected) {
        _cameraId = cameraState.deviceId;
        if (_cameraNameController.text.isEmpty) {
          _cameraNameController.text =
              cameraState.deviceName ?? cameraState.deviceId ?? '';
        }
      }

      if (_mountId == null &&
          mountState.connectionState == DeviceConnectionState.connected) {
        _mountId = mountState.deviceId;
        if (_mountNameController.text.isEmpty) {
          _mountNameController.text =
              mountState.deviceName ?? mountState.deviceId ?? '';
        }
      }

      if (_focuserId == null &&
          focuserState.connectionState == DeviceConnectionState.connected) {
        _focuserId = focuserState.deviceId;
        if (_focuserNameController.text.isEmpty) {
          _focuserNameController.text =
              focuserState.deviceName ?? focuserState.deviceId ?? '';
        }
      }

      if (_filterWheelId == null &&
          filterWheelState.connectionState == DeviceConnectionState.connected) {
        _filterWheelId = filterWheelState.deviceId;
        if (_filterWheelNameController.text.isEmpty) {
          _filterWheelNameController.text =
              filterWheelState.deviceName ?? filterWheelState.deviceId ?? '';
        }
        if (_filterControllers.isEmpty &&
            filterWheelState.filterNames.isNotEmpty) {
          _autoDetectFilters();
        }
      }

      if (_guiderId == null &&
          guiderState.connectionState == DeviceConnectionState.connected) {
        _guiderId = guiderState.deviceId;
        if (_guiderNameController.text.isEmpty) {
          _guiderNameController.text =
              guiderState.deviceName ?? guiderState.deviceId ?? '';
        }
      }

      if (_rotatorId == null &&
          rotatorState.connectionState == DeviceConnectionState.connected) {
        _rotatorId = rotatorState.deviceId;
        if (_rotatorNameController.text.isEmpty) {
          _rotatorNameController.text =
              rotatorState.deviceName ?? rotatorState.deviceId ?? '';
        }
      }

      if (_domeId == null &&
          domeState.connectionState == DeviceConnectionState.connected) {
        _domeId = domeState.deviceId;
      }

      if (_weatherId == null &&
          weatherState.connectionState == DeviceConnectionState.connected) {
        _weatherId = weatherState.deviceId;
      }

      if (_safetyMonitorId == null &&
          safetyMonitorState.connectionState ==
              DeviceConnectionState.connected) {
        _safetyMonitorId = safetyMonitorState.deviceId;
        if (_safetyMonitorNameController.text.isEmpty) {
          _safetyMonitorNameController.text = safetyMonitorState.deviceName ??
              safetyMonitorState.deviceId ??
              '';
        }
      }

      if (_switchId == null &&
          switchState.connectionState == DeviceConnectionState.connected) {
        _switchId = switchState.deviceId;
        if (_switchNameController.text.isEmpty) {
          _switchNameController.text =
              switchState.deviceName ?? switchState.deviceId ?? '';
        }
      }

      if (_coverCalibratorId == null &&
          coverCalibratorState.connectionState ==
              DeviceConnectionState.connected) {
        _coverCalibratorId = coverCalibratorState.deviceId;
      }
    });
  }

  /// Rejects a name another profile already carries (case- and
  /// whitespace-insensitive).
  ///
  /// The name is the only thing the sidebar rows, the screen header, the status
  /// bar and the delete confirmation quote, so two rigs both called "My First
  /// Rig" leave the operator guessing which one a destructive action is about
  /// to hit. This is the same gate that already catches an empty name.
  String? _duplicateNameError(String name) {
    final editingId = widget.profile?.id;
    final target = name.toLowerCase();
    final clashes = ref.read(sortedProfilesProvider).any(
          (p) => p.id != editingId && p.name.trim().toLowerCase() == target,
        );
    return clashes ? 'Another profile is already called "$name"' : null;
  }

  /// Validate and normalize the entire form through the shared
  /// [ProfileValidator] contract. On failure it shows the inline errors and a
  /// summary snackbar, leaves the editor open, and returns null.
  _ParsedProfileForm? _validateForm() {
    final nameResult = ProfileValidator.parseName(_nameController.text);
    final nameError = nameResult.isValid
        ? _duplicateNameError(nameResult.value!)
        : nameResult.error;
    final focalResult =
        ProfileValidator.parseFocalLength(_focalLengthController.text);
    final reducerResult = _parseReducerFactor(_reducerController.text);
    final apertureResult =
        ProfileValidator.parseAperture(_apertureController.text);
    final gainResult = ProfileValidator.parseOptionalWholeNonNegative(
        _gainController.text,
        label: 'Gain');
    final offsetResult = ProfileValidator.parseOptionalWholeNonNegative(
        _offsetController.text,
        label: 'Offset');
    final coolingResult =
        ProfileValidator.parseCoolingTarget(_coolingTargetController.text);
    final centeringResult = ProfileValidator.parseCenteringExposure(
        _centeringExposureController.text);
    final binningResult = ProfileValidator.parseBinning(_binning);
    final filterResult = ProfileValidator.parseFilterRows([
      for (final pair in _filterControllers)
        ProfileFilterRowInput(
          name: pair.nameController.text,
          offset: pair.offsetController.text,
        ),
    ]);

    // What the rig images at, which is what every downstream consumer means by
    // "focal length". The reducer is folded in BEFORE the plausibility check so
    // a barlow that pushes the train past the f-ratio ceiling is caught here
    // rather than persisted.
    final effectiveFocalLength =
        focalResult.isValid && reducerResult.isValid && focalResult.value! > 0
            ? _effectiveFocalLengthOf(focalResult.value!, reducerResult.value!)
            : 0.0;

    // Individually in-range optics can still describe an impossible system
    // (600 mm at 0.1 mm aperture is f/6000), so cross-check the pair through
    // the same shared contract once both fields parsed.
    final trainError =
        focalResult.isValid && reducerResult.isValid && apertureResult.isValid
            ? ProfileValidator.validateOpticalTrain(
                focalLengthMm: effectiveFocalLength,
                apertureMm: apertureResult.value!,
              )
            : null;

    // Errors that map onto a specific input get inline treatment on that input.
    final inlineErrors = <String, String>{
      if (!focalResult.isValid)
        ProfileEditorField.focalLength: focalResult.error!,
      if (!reducerResult.isValid)
        ProfileEditorField.reducer: reducerResult.error!,
      if (!apertureResult.isValid)
        ProfileEditorField.aperture: apertureResult.error!,
      if (!gainResult.isValid) ProfileEditorField.gain: gainResult.error!,
      if (!offsetResult.isValid) ProfileEditorField.offset: offsetResult.error!,
      if (!coolingResult.isValid)
        ProfileEditorField.coolingTarget: coolingResult.error!,
      if (!centeringResult.isValid)
        ProfileEditorField.centeringExposure: centeringResult.error!,
    };

    // Errors with no single owning input (the focal-length/aperture cross-check,
    // the binning dropdown, per-filter rows) go in the in-dialog banner.
    final unattachedErrors = <String>[
      if (trainError != null) trainError,
      if (!binningResult.isValid) binningResult.error!,
      if (!filterResult.isValid) ...filterResult.errors,
    ];

    if (nameError != null ||
        inlineErrors.isNotEmpty ||
        unattachedErrors.isNotEmpty) {
      setState(() {
        _nameError = nameError;
        _fieldErrors
          ..clear()
          ..addAll(inlineErrors);
        _formErrors = List<String>.unmodifiable(unattachedErrors);
        // Open every section that carries an error so the inline message is
        // actually on screen — an error inside a collapsed section leaves no
        // visible marker at all.
        if (nameError != null) _expandedSections['identity'] = true;
        if (inlineErrors.containsKey(ProfileEditorField.focalLength) ||
            inlineErrors.containsKey(ProfileEditorField.reducer) ||
            inlineErrors.containsKey(ProfileEditorField.aperture) ||
            trainError != null) {
          _expandedSections['optical'] = true;
        }
        if (inlineErrors.containsKey(ProfileEditorField.gain) ||
            inlineErrors.containsKey(ProfileEditorField.offset) ||
            inlineErrors.containsKey(ProfileEditorField.coolingTarget) ||
            inlineErrors.containsKey(ProfileEditorField.centeringExposure) ||
            !binningResult.isValid) {
          _expandedSections['camera'] = true;
        }
        if (!filterResult.isValid) _expandedSections['filters'] = true;
      });
      // The banner inside the dialog is now the primary surface. The toast is
      // kept only as a secondary cue for a user whose focus is elsewhere.
      context.showErrorSnackBar(
        'Profile not saved — see the highlighted fields.',
      );
      return null;
    }

    setState(() {
      _nameError = null;
      _fieldErrors.clear();
      _formErrors = const <String>[];
    });

    final aperture = apertureResult.value!;
    return _ParsedProfileForm(
      name: nameResult.value!,
      focalLength: effectiveFocalLength,
      telescopeFocalLength: focalResult.value!,
      aperture: aperture,
      // The stored ratio must describe the same train as the stored focal
      // length, so it is derived from the EFFECTIVE value. Left null when the
      // ratio is undefined rather than persisted as a meaningless `0.0`, which
      // the wire validator rejects outright.
      focalRatio: aperture > 0 && effectiveFocalLength > 0
          ? effectiveFocalLength / aperture
          : null,
      gain: gainResult.value,
      offset: offsetResult.value,
      binning: binningResult.value!,
      coolingTemp: coolingResult.value,
      centeringExposure: centeringResult.value,
      filterNames: filterResult.config!.names,
      filterOffsets: filterResult.config!.offsets,
    );
  }

  /// The profile this editor saves: the validated form over the fields the
  /// form does not show, which keep the edited profile's values.
  EquipmentProfileModel _buildModel(_ParsedProfileForm parsed) {
    return EquipmentProfileModel(
      id: widget.profile?.id,
      name: parsed.name,
      description: _descriptionController.text.trimOrNull,
      profileIcon: _selectedIcon.isEmpty ? null : _selectedIcon,
      profileColor: _selectedColor?.toARGB32(),
      isDefault: _defaultToSave(widget.profile?.isDefault ?? _isDefault),
      isActive: widget.profile?.isActive ?? false,
      telescopeName: _telescopeNameController.text.trimOrNull,
      // The telescope columns carry the OTA's NATIVE optics and `focalLength`
      // the effective (post reducer/barlow) train — writing the same number to
      // both is what silently erased the reducer. Keep the long-standing "null
      // when unspecified (0)" shape for the telescope columns.
      telescopeFocalLength:
          parsed.telescopeFocalLength > 0 ? parsed.telescopeFocalLength : null,
      telescopeAperture: parsed.aperture > 0 ? parsed.aperture : null,
      focalLength: parsed.focalLength,
      aperture: parsed.aperture,
      focalRatio: parsed.focalRatio,
      cameraId: _cameraId,
      cameraName: _cameraNameController.text.trimOrNull,
      mountId: _mountId,
      mountName: _mountNameController.text.trimOrNull,
      focuserId: _focuserId,
      focuserName: _focuserNameController.text.trimOrNull,
      filterWheelId: _filterWheelId,
      filterWheelName: _filterWheelNameController.text.trimOrNull,
      guiderId: _guiderId,
      guiderName: _guiderNameController.text.trimOrNull,
      guideCameraId: _guideCameraToSave,
      guideCameraName: _guideCameraToSave == null
          ? null
          : _guideCameraNameController.text.trimOrNull,
      guideFocalLength: _guideFocalLengthToSave,
      rotatorId: _rotatorId,
      rotatorName: _rotatorNameController.text.trimOrNull,
      domeId: _domeId,
      weatherId: _weatherId,
      safetyMonitorId: _safetyMonitorId,
      safetyMonitorName: _safetyMonitorNameController.text.trimOrNull,
      switchId: _switchId,
      switchName: _switchNameController.text.trimOrNull,
      coverCalibratorId: _coverCalibratorId,
      filterNames: parsed.filterNames,
      filterFocusOffsets: parsed.filterOffsets,
      meridianFlipOverrides: widget.profile?.meridianFlipOverrides,
      defaultGain: parsed.gain,
      defaultOffset: parsed.offset,
      defaultBinX: parsed.binning,
      defaultBinY: parsed.binning,
      defaultCoolingTemp: parsed.coolingTemp,
      coolOnConnect: _coolOnConnect,
      defaultCenteringExposure: parsed.centeringExposure,
      sortOrder: widget.profile?.sortOrder ?? 0,
      createdAt: widget.profile?.createdAt,
      updatedAt: widget.profile?.updatedAt,
    );
  }

  Future<void> _save() async {
    // In-flight guard: a fast double-tap can call _save again before the
    // disabled/isLoading rebuild lands, which would issue a duplicate
    // create/update. Bail if a save is already running.
    if (_isSaving) return;

    // Validate + normalize every field through the shared contract BEFORE any
    // provider/DB/network call. On failure the editor stays open with inline +
    // summary errors and no save is attempted.
    final parsed = _validateForm();
    if (parsed == null) return;

    setState(() => _isSaving = true);
    try {
      await ref
          .read(equipmentProfilesProvider.notifier)
          .saveProfile(_buildModel(parsed));
      if (!mounted) return;
      final action = widget.profile != null ? 'updated' : 'created';
      context.showSuccessSnackBar('Profile "${parsed.name}" $action');
      _closeAfterSave();
    } catch (e, st) {
      ref.read(loggingServiceProvider).error(
        'ProfileEditorDialog save failed: $e',
        source: 'ProfileEditorDialog',
        fields: {'error': e.toString(), 'stack': st.toString()},
      );
      if (mounted) {
        context.showErrorSnackBar(profileSaveErrorMessage(e));
        setState(() => _isSaving = false);
      }
    }
  }
}

extension _ProfileEditorSaveClose on _ProfileEditorDialogState {
  /// Dismisses the editor after a successful save.
  ///
  /// In [ProfileEditorMode.opticalTrainPage] the editor IS the Equipment
  /// screen's tab body, so popping would take the whole `/equipment` route off
  /// the stack. There the save simply lands and the page stays put.
  void _closeAfterSave() {
    if (widget.mode != ProfileEditorMode.full) {
      setState(() {
        _isSaving = false;
        _savedSignature = _formSignature();
        _isDefaultTouched = false;
      });
      return;
    }
    Navigator.of(context).pop(true);
  }
}
