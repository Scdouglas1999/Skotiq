part of '../equipment_profiles_screen.dart';

class _ProfileDetails extends ConsumerStatefulWidget {
  final EquipmentProfileModel profile;
  final bool isActive;
  final bool isEditing;
  final VoidCallback onEdit;
  final Future<void> Function(EquipmentProfileModel) onSave;
  final VoidCallback onCancel;
  final VoidCallback onSetActive;
  final VoidCallback onSetDefault;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback onExport;
  final Future<bool> Function(int, SkotiqBackend) onRefresh;
  final bool isMobile;
  final VoidCallback? onBack;

  const _ProfileDetails({
    required this.profile,
    required this.isActive,
    required this.isEditing,
    required this.onEdit,
    required this.onSave,
    required this.onCancel,
    required this.onSetActive,
    required this.onSetDefault,
    required this.onDuplicate,
    required this.onDelete,
    required this.onExport,
    required this.onRefresh,
    this.isMobile = false,
    this.onBack,
  });

  @override
  ConsumerState<_ProfileDetails> createState() => _ProfileDetailsState();
}

class _ProfileDetailsState extends ConsumerState<_ProfileDetails> {
  late TextEditingController _nameController;
  late TextEditingController _descController;
  late TextEditingController _focalLengthController;
  late TextEditingController _apertureController;
  late TextEditingController _gainController;
  late TextEditingController _offsetController;
  late TextEditingController _coolingController;
  late int _binX;
  late int _binY;
  late List<TextEditingController> _filterControllers;
  late List<TextEditingController> _filterOffsetControllers;

  // Device IDs for editing
  late String? _cameraId;
  late String? _mountId;
  late String? _focuserId;
  late String? _filterWheelId;
  late String? _guiderId;
  late String? _rotatorId;
  late String? _domeId;
  late String? _weatherId;
  bool _isSyncingFilters = false;

  // In-flight guard for the Save button: prevents a double-tap from issuing two
  // updateProfile calls, and drives the button's disabled/loading state.
  bool _isSaving = false;
  int _operationGeneration = 0;

  /// Per-field rejection messages from the last Save attempt, keyed by the
  /// field labels below. The summary snackbar sits at the bottom of the window
  /// underneath the persistent status bar, so a rejected save had to be read
  /// through the accessibility tree to be found at all — the message has to be
  /// on the field the user is looking at.
  final Map<String, String> _fieldErrors = <String, String>{};

  static const String _focalLengthField = 'Focal Length';
  static const String _apertureField = 'Aperture';
  static const String _gainField = 'Default Gain';
  static const String _offsetField = 'Default Offset';
  static const String _coolingField = 'Cooling Temp';

  @override
  void initState() {
    super.initState();
    _initControllers();
  }

  @override
  void didUpdateWidget(_ProfileDetails oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id ||
        (oldWidget.isEditing && !widget.isEditing)) {
      if (oldWidget.profile.id != widget.profile.id) {
        _operationGeneration++;
        _isSaving = false;
        _isSyncingFilters = false;
      }
      _fieldErrors.clear();
      _disposeControllers();
      _initControllers();
    }
  }

  /// Editor text for an optic (focal length / aperture).
  ///
  /// `0` is the model's documented "unspecified" sentinel (see
  /// [ProfileValidator.parseFocalLength]), and the very same validator rejects
  /// a typed `0` as "must be a positive number". Rendering the sentinel as a
  /// literal `0` therefore pre-loaded the editor with a value its own Save
  /// refused: a profile created without optics could not be edited at all
  /// until the user guessed that both fields had to be cleared. Blank in,
  /// blank out.
  static String _opticText(double value) =>
      value > 0 ? value.toStringAsFixed(0) : '';

  void _initControllers() {
    _nameController = TextEditingController(text: widget.profile.name);
    _descController =
        TextEditingController(text: widget.profile.description ?? '');
    _focalLengthController =
        TextEditingController(text: _opticText(widget.profile.focalLength));
    _apertureController =
        TextEditingController(text: _opticText(widget.profile.aperture));
    _gainController = TextEditingController(
        text: widget.profile.defaultGain?.toString() ?? '');
    _offsetController = TextEditingController(
        text: widget.profile.defaultOffset?.toString() ?? '');
    _coolingController = TextEditingController(
        text: widget.profile.defaultCoolingTemp?.toString() ?? '');
    _binX = widget.profile.defaultBinX;
    _binY = widget.profile.defaultBinY;
    _filterControllers = widget.profile.filterNames.isEmpty
        ? [TextEditingController()]
        : widget.profile.filterNames
            .map((f) => TextEditingController(text: f))
            .toList();

    // Focus offset controllers run parallel to _filterControllers so a rename
    // keeps its offset (offsets are indexed, not keyed by filter name).
    _filterOffsetControllers = widget.profile.filterNames.isEmpty
        ? [TextEditingController(text: '0')]
        : widget.profile.filterNames.map((f) {
            final offset = widget.profile.filterFocusOffsets[f] ?? 0;
            return TextEditingController(text: offset.toString());
          }).toList();

    // Initialize device IDs
    _cameraId = widget.profile.cameraId;
    _mountId = widget.profile.mountId;
    _focuserId = widget.profile.focuserId;
    _filterWheelId = widget.profile.filterWheelId;
    _guiderId = widget.profile.guiderId;
    _rotatorId = widget.profile.rotatorId;
    _domeId = widget.profile.domeId;
    _weatherId = widget.profile.weatherId;
  }

  void _disposeControllers() {
    _nameController.dispose();
    _descController.dispose();
    _focalLengthController.dispose();
    _apertureController.dispose();
    _gainController.dispose();
    _offsetController.dispose();
    _coolingController.dispose();
    for (final c in _filterControllers) {
      c.dispose();
    }
    for (final c in _filterOffsetControllers) {
      c.dispose();
    }
  }

  @override
  void dispose() {
    _operationGeneration++;
    _disposeControllers();
    super.dispose();
  }

  bool _isCurrentOperation(
    int generation,
    int? profileId,
    SkotiqBackend authority,
  ) =>
      mounted &&
      generation == _operationGeneration &&
      widget.profile.id == profileId &&
      identical(ref.read(backendProvider), authority);

  /// Validate + normalize every edited field through the shared
  /// [ProfileValidator] contract and return the updated model, or null (after
  /// surfacing a summary error and leaving the editor in edit mode) when any
  /// field is invalid. Called BEFORE any provider/DB write.
  EquipmentProfileModel? _validateAndBuild() {
    final nameResult = ProfileValidator.parseName(_nameController.text);
    final focalResult =
        ProfileValidator.parseFocalLength(_focalLengthController.text);
    final apertureResult =
        ProfileValidator.parseAperture(_apertureController.text);
    final gainResult = ProfileValidator.parseOptionalWholeNonNegative(
        _gainController.text,
        label: 'Gain');
    final offsetResult = ProfileValidator.parseOptionalWholeNonNegative(
        _offsetController.text,
        label: 'Offset');
    final coolingResult =
        ProfileValidator.parseCoolingTarget(_coolingController.text);
    final binXResult = ProfileValidator.parseBinning(_binX, label: 'Binning X');
    final binYResult = ProfileValidator.parseBinning(_binY, label: 'Binning Y');

    // Filter names and offsets share an index with the parallel controller
    // lists; zip them into rows for the shared validator.
    final filterResult = ProfileValidator.parseFilterRows([
      for (var i = 0; i < _filterControllers.length; i++)
        ProfileFilterRowInput(
          name: _filterControllers[i].text,
          offset: i < _filterOffsetControllers.length
              ? _filterOffsetControllers[i].text
              : '',
        ),
    ]);

    // Individually in-range optics can still describe an impossible system, so
    // cross-check the pair through the same shared contract once both parsed.
    final trainError = focalResult.isValid && apertureResult.isValid
        ? ProfileValidator.validateOpticalTrain(
            focalLengthMm: focalResult.value!,
            apertureMm: apertureResult.value!,
          )
        : null;

    final errors = <String>[
      if (!nameResult.isValid) nameResult.error!,
      if (!focalResult.isValid) focalResult.error!,
      if (!apertureResult.isValid) apertureResult.error!,
      if (trainError != null) trainError,
      if (!gainResult.isValid) gainResult.error!,
      if (!offsetResult.isValid) offsetResult.error!,
      if (!coolingResult.isValid) coolingResult.error!,
      if (!binXResult.isValid) binXResult.error!,
      if (!binYResult.isValid) binYResult.error!,
      if (!filterResult.isValid) ...filterResult.errors,
    ];

    if (errors.isNotEmpty) {
      // Pin each message to its own field as well as summarising it, so the
      // reason a Save was refused is visible where the user is typing.
      setState(() {
        _fieldErrors
          ..clear()
          ..addAll({
            if (!focalResult.isValid) _focalLengthField: focalResult.error!,
            if (!apertureResult.isValid) _apertureField: apertureResult.error!,
            if (!gainResult.isValid) _gainField: gainResult.error!,
            if (!offsetResult.isValid) _offsetField: offsetResult.error!,
            if (!coolingResult.isValid) _coolingField: coolingResult.error!,
          });
      });
      context.showErrorSnackBar(errors.join('\n'));
      return null;
    }

    if (_fieldErrors.isNotEmpty) {
      setState(_fieldErrors.clear);
    }

    final focalLength = focalResult.value!;
    final aperture = apertureResult.value!;
    final description = _descController.text.trim();

    return widget.profile.copyWith(
      name: nameResult.value!,
      description: description.isEmpty ? null : description,
      focalLength: focalLength,
      aperture: aperture,
      focalRatio: aperture > 0 ? focalLength / aperture : null,
      defaultGain: gainResult.value,
      defaultOffset: offsetResult.value,
      defaultCoolingTemp: coolingResult.value,
      defaultBinX: binXResult.value,
      defaultBinY: binYResult.value,
      filterNames: filterResult.config!.names,
      filterFocusOffsets: filterResult.config!.offsets,
      cameraId: _cameraId,
      mountId: _mountId,
      focuserId: _focuserId,
      filterWheelId: _filterWheelId,
      guiderId: _guiderId,
      rotatorId: _rotatorId,
      domeId: _domeId,
      weatherId: _weatherId,
    );
  }

  /// Validate, then persist through the parent's [onSave]. Guards against
  /// duplicate in-flight submissions, keeps the editor open + retryable on
  /// failure, and only reports success after the save actually completes.
  Future<void> _handleSave() async {
    if (_isSaving) return; // in-flight guard: ignore duplicate taps
    final updated = _validateAndBuild();
    if (updated == null) return; // invalid — stay in edit mode, errors shown

    final profileId = widget.profile.id;
    final authority = ref.read(backendProvider);
    final generation = ++_operationGeneration;
    setState(() => _isSaving = true);
    try {
      await widget.onSave(updated);
      if (mounted && _isCurrentOperation(generation, profileId, authority)) {
        context.showSuccessSnackBar('Profile saved successfully');
      }
    } catch (e) {
      if (mounted && _isCurrentOperation(generation, profileId, authority)) {
        context.showErrorSnackBar('Failed to save profile: $e');
      }
    } finally {
      if (_isCurrentOperation(generation, profileId, authority)) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _syncFiltersFromHardware() async {
    if (_isSyncingFilters) return;

    final profileId = widget.profile.id;
    if (profileId == null) {
      context.showErrorSnackBar('Save this profile before syncing filters');
      return;
    }
    final authority = ref.read(backendProvider);
    final generation = ++_operationGeneration;
    setState(() => _isSyncingFilters = true);

    try {
      final profileService = ref.read(profileServiceProvider);
      final synced = await profileService.syncFiltersToProfile(profileId);

      if (!_isCurrentOperation(generation, profileId, authority)) return;

      if (synced) {
        final refreshed = await widget.onRefresh(profileId, authority);
        if (mounted &&
            refreshed &&
            _isCurrentOperation(generation, profileId, authority)) {
          context.showSuccessSnackBar('Filters synced from hardware');
        }
      } else {
        if (mounted && _isCurrentOperation(generation, profileId, authority)) {
          context.showWarningSnackBar('No filter wheel connected');
        }
      }
    } catch (e) {
      if (mounted && _isCurrentOperation(generation, profileId, authority)) {
        context.showErrorSnackBar('Failed to sync filters: $e');
      }
    } finally {
      if (_isCurrentOperation(generation, profileId, authority)) {
        setState(() => _isSyncingFilters = false);
      }
    }
  }

  void _copyFromConnectedDevices() {
    // Read current device states
    final cameraState = ref.read(cameraStateProvider);
    final mountState = ref.read(mountStateProvider);
    final focuserState = ref.read(focuserStateProvider);
    final filterWheelState = ref.read(filterWheelStateProvider);
    final guiderState = ref.read(guiderStateProvider);
    final rotatorState = ref.read(rotatorStateProvider);
    final domeState = ref.read(domeStateProvider);
    final weatherState = ref.read(weatherStateProvider);

    int copiedCount = 0;

    setState(() {
      // Copy camera ID if connected
      if (cameraState.connectionState == DeviceConnectionState.connected &&
          cameraState.deviceId != null) {
        _cameraId = cameraState.deviceId;
        copiedCount++;
      }

      // Copy mount ID if connected
      if (mountState.connectionState == DeviceConnectionState.connected &&
          mountState.deviceId != null) {
        _mountId = mountState.deviceId;
        copiedCount++;
      }

      // Copy focuser ID if connected (uses deviceName as ID)
      if (focuserState.connectionState == DeviceConnectionState.connected &&
          focuserState.deviceName != null) {
        _focuserId = focuserState.deviceName;
        copiedCount++;
      }

      // Copy filter wheel ID if connected (uses deviceName as ID)
      if (filterWheelState.connectionState == DeviceConnectionState.connected &&
          filterWheelState.deviceName != null) {
        _filterWheelId = filterWheelState.deviceName;
        copiedCount++;
      }

      // Copy guider ID if connected (uses deviceName as ID)
      if (guiderState.connectionState == DeviceConnectionState.connected &&
          guiderState.deviceName != null) {
        _guiderId = guiderState.deviceName;
        copiedCount++;
      }

      // Copy rotator ID if connected
      if (rotatorState.connectionState == DeviceConnectionState.connected &&
          rotatorState.deviceId != null) {
        _rotatorId = rotatorState.deviceId;
        copiedCount++;
      }

      // Copy dome ID if connected
      if (domeState.connectionState == DeviceConnectionState.connected &&
          domeState.deviceId != null) {
        _domeId = domeState.deviceId;
        copiedCount++;
      }

      // Copy weather ID if connected
      if (weatherState.connectionState == DeviceConnectionState.connected &&
          weatherState.deviceId != null) {
        _weatherId = weatherState.deviceId;
        copiedCount++;
      }
    });

    if (copiedCount > 0) {
      context.showSuccessSnackBar(
          'Copied $copiedCount device${copiedCount == 1 ? '' : 's'} '
          'from connected equipment');
    } else {
      context.showWarningSnackBar('No devices currently connected');
    }
  }

  void _update(VoidCallback callback) => setState(callback);

  @override
  Widget build(BuildContext context) => _buildDetails(context);
}
