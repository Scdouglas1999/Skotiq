// Defect-map build button, apply toggle and clear button.
part of '../calibration_section.dart';

class DefectMapBuildButton extends ConsumerStatefulWidget {
  final SkotiqColors colors;
  final bool enabled;
  final String? disabledReason;
  final String? cameraId;
  final double? temperatureC;
  final bool isRemoteMode;

  const DefectMapBuildButton({
    super.key,
    required this.colors,
    required this.enabled,
    required this.disabledReason,
    required this.cameraId,
    required this.temperatureC,
    required this.isRemoteMode,
  });

  @override
  ConsumerState<DefectMapBuildButton> createState() =>
      _DefectMapBuildButtonState();
}

class _DefectMapBuildButtonState extends ConsumerState<DefectMapBuildButton> {
  bool _picking = false;

  /// The pick-and-build in progress. A host change, or the card moving to
  /// another camera or temperature, drops it.
  late final _operations = ref.backendScopes(alive: () => mounted);

  @override
  void didUpdateWidget(covariant DefectMapBuildButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.cameraId != widget.cameraId ||
        oldWidget.temperatureC != widget.temperatureC ||
        oldWidget.isRemoteMode != widget.isRemoteMode) {
      _operations.cancelAll();
      _picking = false;
    }
  }

  Future<void> _pickAndBuild() async {
    final cameraId = widget.cameraId;
    final temperatureC = widget.temperatureC;
    if (cameraId == null || temperatureC == null) {
      // Defense in depth: the button is disabled when these are missing,
      // but guard anyway so the bridge call never sees nulls.
      return;
    }

    final operation = _operations.beginLatest();
    setState(() => _picking = true);
    try {
      if (widget.isRemoteMode) {
        await _pickHostDirectoryAndBuild(
          operation,
          cameraId,
          temperatureC,
        );
      } else {
        await _pickLocalFilesAndBuild(
          operation,
          cameraId,
          temperatureC,
        );
      }
    } catch (error) {
      if (!mounted || !_isCurrent(operation, cameraId)) return;
      context.showErrorSnackBar('Could not select dark frames: ${userFacingError(error)}');
    } finally {
      if (operation.isCurrent) setState(() => _picking = false);
    }
  }

  /// Local path: pick the dark FITS/XISF files with the OS file picker and
  /// build from their absolute paths.
  Future<void> _pickLocalFilesAndBuild(
    AsyncScope<SkotiqBackend> operation,
    String cameraId,
    double temperatureC,
  ) async {
    final paths = await ref.read(defectMapLocalDarkPickerProvider)();
    if (paths.isEmpty || !_isCurrent(operation, cameraId)) return;

    if (paths.length < DefectMapService.minRequiredDarkFrames) {
      if (!mounted) return;
      context.showWarningSnackBar(
        'Defect detection requires at least '
        '${DefectMapService.minRequiredDarkFrames} dark frames; '
        'you selected ${paths.length}.',
      );
      return;
    }

    final notifier = ref.read(defectMapNotifierProvider.notifier);
    await notifier.build(
      cameraId: cameraId,
      darkFramePaths: paths,
      sensorTemperatureCelsius: temperatureC,
    );
    if (_isCurrent(operation, cameraId)) _reportResult();
  }

  /// Remote path: the host owns the dark frames, so the operator picks a host
  /// directory. The host enumerates the FITS/XISF darks under it and builds
  /// the map there — no frame data crosses the wire.
  Future<void> _pickHostDirectoryAndBuild(
    AsyncScope<SkotiqBackend> operation,
    String cameraId,
    double temperatureC,
  ) async {
    final directory = await ref.read(defectMapHostDarkPickerProvider)(context);
    if (directory == null || !_isCurrent(operation, cameraId)) {
      return;
    }

    final notifier = ref.read(defectMapNotifierProvider.notifier);
    await notifier.build(
      cameraId: cameraId,
      darkFramePaths: const [],
      darkFramesDirectory: directory,
      sensorTemperatureCelsius: temperatureC,
    );
    if (_isCurrent(operation, cameraId)) _reportResult();
  }

  void _reportResult() {
    if (!mounted) return;
    final state = ref.read(defectMapNotifierProvider);
    if (state.errorMessage != null) {
      context.showErrorSnackBar(state.errorMessage!);
    } else if (state.statusMessage != null) {
      context.showSuccessSnackBar(state.statusMessage!);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SkotiqBackend>(backendProvider, (previous, next) {
      if (_picking && previous != null && !identical(previous, next)) {
        _operations.cancelAll();
        setState(() => _picking = false);
      }
    });
    final uiState = ref.watch(defectMapNotifierProvider);
    final isBuilding = uiState.isBuilding;
    final buttonEnabled =
        widget.enabled && !_picking && !isBuilding && !uiState.isClearing;

    final button = SmallButton(
      label: _picking
          ? 'Selecting dark frames...'
          : isBuilding
              ? 'Building defect map...'
              // "…from current darks" needs 230px and the side panel's
              // card is 216, so the button read "Build defect map from cur…".
              // The trailing ellipsis is the real story anyway: this opens a
              // picker for the darks before it builds anything.
              : 'Build defect map...',
      icon: _picking || isBuilding ? SkotiqIcons.loading : LucideIcons.cog,
      colors: widget.colors,
      isEnabled: buttonEnabled,
      onTap: buttonEnabled ? _pickAndBuild : null,
    );

    return _MaybeTooltip(
      message: widget.enabled ? null : widget.disabledReason,
      child: button,
    );
  }

  bool _isCurrent(AsyncScope<SkotiqBackend> operation, String cameraId) =>
      operation.isCurrent && widget.cameraId == cameraId;
}

class _ApplyToggle extends ConsumerWidget {
  final SkotiqColors colors;
  final bool enabled;
  final String? disabledReason;
  final String? cameraId;
  final int sensorWidth;
  final int sensorHeight;
  final double? temperatureC;

  const _ApplyToggle({
    required this.colors,
    required this.enabled,
    required this.disabledReason,
    required this.cameraId,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.temperatureC,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The toggle reflects the persisted status when we have one; otherwise
    // it defaults to off and the user can flip it once a map is built.
    bool currentValue = false;
    var toggleEnabled = false;
    String? mapDisabledReason;
    if (enabled) {
      final statusAsync = ref.watch(defectMapStatusProvider(
        DefectMapQuery(
          cameraId: cameraId!,
          width: sensorWidth,
          height: sensorHeight,
          sensorTemperatureCelsius: temperatureC!,
        ),
      ));
      final status = statusAsync.valueOrNull;
      currentValue = status?.applyDuringCapture ?? false;
      toggleEnabled = status?.storedOnDisk == true;
      if (statusAsync.isLoading) {
        mapDisabledReason = 'Loading defect map status...';
      } else if (statusAsync.hasError) {
        mapDisabledReason = 'Could not verify the current defect map.';
      } else if (!toggleEnabled) {
        mapDisabledReason =
            'Build a defect map for this camera and temperature first.';
      }
    }

    final row = Row(
      children: [
        Expanded(
          child: Text(
            'Apply during capture',
            style: SkotiqTypography.caption.copyWith(color: colors.textPrimary),
          ),
        ),
        SkotiqSwitch(
          value: currentValue,
          enabled: toggleEnabled,
          onChanged: toggleEnabled
              ? (value) async {
                  final notifier = ref.read(defectMapNotifierProvider.notifier);
                  await notifier.setApplyDuringCapture(
                    cameraId: cameraId!,
                    apply: value,
                    width: sensorWidth,
                    height: sensorHeight,
                    sensorTemperatureCelsius: temperatureC!,
                  );
                  if (!context.mounted) return;
                  final state = ref.read(defectMapNotifierProvider);
                  if (state.errorMessage != null) {
                    context.showErrorSnackBar(state.errorMessage!);
                  }
                }
              : null,
        ),
      ],
    );

    return _MaybeTooltip(
      message:
          toggleEnabled ? null : (enabled ? mapDisabledReason : disabledReason),
      child: row,
    );
  }
}

class _ClearButton extends ConsumerWidget {
  final SkotiqColors colors;
  final bool enabled;
  final String? disabledReason;
  final String? cameraId;
  final int sensorWidth;
  final int sensorHeight;
  final double? temperatureC;

  const _ClearButton({
    required this.colors,
    required this.enabled,
    required this.disabledReason,
    required this.cameraId,
    required this.sensorWidth,
    required this.sensorHeight,
    required this.temperatureC,
  });

  Future<void> _confirmAndClear(BuildContext context, WidgetRef ref) async {
    final bucket = DefectMapTemperatureBucket.fromCelsius(temperatureC!).label;
    final shouldClear = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Clear defect map?'),
          content: Text(
            'This deletes the stored defect map for $cameraId at '
            '${sensorWidth}x$sensorHeight at $bucket. You can rebuild it '
            'from darks at any time.',
          ),
          actions: [
            SkotiqButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              label: 'Cancel',
              variant: ButtonVariant.ghost,
              size: ButtonSize.small,
            ),
            SkotiqButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              label: 'Clear',
              variant: ButtonVariant.destructive,
              size: ButtonSize.small,
            ),
          ],
        );
      },
    );

    if (shouldClear != true) return;

    final notifier = ref.read(defectMapNotifierProvider.notifier);
    await notifier.clear(
      cameraId: cameraId!,
      width: sensorWidth,
      height: sensorHeight,
      sensorTemperatureCelsius: temperatureC!,
    );

    if (!context.mounted) return;
    final state = ref.read(defectMapNotifierProvider);
    if (state.errorMessage != null) {
      context.showErrorSnackBar(state.errorMessage!);
    } else if (state.statusMessage != null) {
      context.showSuccessSnackBar(state.statusMessage!);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final uiState = ref.watch(defectMapNotifierProvider);
    final buttonEnabled = enabled && !uiState.isClearing && !uiState.isBuilding;

    final button = SmallButton(
      label: uiState.isClearing
          ? 'Clearing...'
          : 'Clear defect map for this camera at this temperature',
      icon: uiState.isClearing ? SkotiqIcons.loading : SkotiqIcons.delete,
      isOutline: true,
      colors: colors,
      isEnabled: buttonEnabled,
      onTap: buttonEnabled ? () => _confirmAndClear(context, ref) : null,
    );

    return _MaybeTooltip(
      message: enabled ? null : disabledReason,
      child: button,
    );
  }
}

class _MaybeTooltip extends StatelessWidget {
  final String? message;
  final Widget child;

  const _MaybeTooltip({required this.message, required this.child});

  @override
  Widget build(BuildContext context) {
    if (message == null) return child;
    return Tooltip(message: message!, child: child);
  }
}
