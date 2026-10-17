import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../equipment/dialogs/profile_editor_dialog.dart';

const _kDefaultManualFilter = 'Unfiltered';

class FlatWizardDialog extends ConsumerStatefulWidget {
  const FlatWizardDialog({super.key});

  @override
  ConsumerState<FlatWizardDialog> createState() => _FlatWizardDialogState();
}

class _FlatCalibrationSnapshot {
  final String sequenceId;
  final String cameraId;
  final String profileFingerprint;
  final String wheelFingerprint;
  final List<String> filters;
  final FlatCaptureConfig captureConfig;
  final double targetPercent;
  final double targetAdu;
  final double minExposure;
  final double maxExposure;

  const _FlatCalibrationSnapshot({
    required this.sequenceId,
    required this.cameraId,
    required this.profileFingerprint,
    required this.wheelFingerprint,
    required this.filters,
    required this.captureConfig,
    required this.targetPercent,
    required this.targetAdu,
    required this.minExposure,
    required this.maxExposure,
  });
}

class _FlatWizardDialogState extends ConsumerState<FlatWizardDialog> {
  int _currentStep = 0;
  double _targetPercent = 50;
  final double _tolerancePercent = 5;
  int _framesPerFilter = 25;
  final Set<String> _selectedFilters = {_kDefaultManualFilter};
  late final TextEditingController _minExposureController;
  late final TextEditingController _maxExposureController;
  late final TextEditingController _manualFilterController;

  bool _isCalculating = false;
  int _runGeneration = 0;
  FlatCancelToken? _cancelToken;

  final Map<String, FlatResult> _results = {};
  _FlatCalibrationSnapshot? _snapshot;
  String? _errorMessage;
  String? _calculationStatus;

  @override
  void initState() {
    super.initState();
    _minExposureController = TextEditingController(text: '0.001');
    _maxExposureController = TextEditingController(text: '10.0');
    _manualFilterController = TextEditingController(
      text: _kDefaultManualFilter,
    );
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    _minExposureController.dispose();
    _maxExposureController.dispose();
    _manualFilterController.dispose();
    super.dispose();
  }

  bool get _allCalibrated {
    final snapshot = _snapshot;
    return snapshot != null &&
        snapshot.filters.isNotEmpty &&
        snapshot.filters.every((filter) => _results[filter]?.success == true);
  }

  void _invalidateCalibration() {
    _snapshot = null;
    _results.clear();
    _errorMessage = null;
    _calculationStatus = null;
    if (_currentStep > 1) _currentStep = 1;
  }

  void _changeCalibrationInput(VoidCallback change) {
    if (_isCalculating) return;
    setState(() {
      change();
      _invalidateCalibration();
    });
  }

  String _profileFingerprint(EquipmentProfileModel? profile) {
    if (profile == null) return 'none';
    return <Object?>[
      profile.id,
      profile.name,
      profile.updatedAt?.microsecondsSinceEpoch,
      profile.defaultGain,
      profile.defaultOffset,
      profile.defaultBinX,
      profile.defaultBinY,
      ...profile.filterNames,
    ].join('|');
  }

  String _wheelFingerprint(FilterWheelState wheel) => <Object?>[
        wheel.connectionState.name,
        wheel.deviceId,
        ...wheel.filterNames,
      ].join('|');

  List<String> _availableFilters(
    FilterWheelState wheel,
    List<String> profileFilters,
  ) {
    if (wheel.connectionState == DeviceConnectionState.connected &&
        wheel.filterNames.isNotEmpty) {
      return wheel.filterNames;
    }
    if (profileFilters.isNotEmpty) return profileFilters;
    final manualFilter = _manualFilterController.text.trim();
    return manualFilter.isEmpty ? const [] : [manualFilter];
  }

  List<String> _orderedSelectedFilters(List<String> available) {
    final ordered = <String>[
      for (final filter in available)
        if (_selectedFilters.contains(filter)) filter,
    ];
    for (final filter in _selectedFilters) {
      if (!ordered.contains(filter)) ordered.add(filter);
    }
    return ordered;
  }

  bool _sameSelectedFilters(List<String> filters) =>
      filters.length == _selectedFilters.length &&
      filters.every(_selectedFilters.contains);

  bool _snapshotContextIsCurrent(_FlatCalibrationSnapshot snapshot) {
    final sequence = ref.read(currentSequenceProvider);
    final camera = ref.read(cameraStateProvider);
    final profile = ref.read(activeEquipmentProfileProvider);
    final wheel = ref.read(filterWheelStateProvider);
    final minExposure = double.tryParse(_minExposureController.text.trim());
    final maxExposure = double.tryParse(_maxExposureController.text.trim());
    return sequence?.id == snapshot.sequenceId &&
        camera.connectionState == DeviceConnectionState.connected &&
        camera.deviceId == snapshot.cameraId &&
        _profileFingerprint(profile) == snapshot.profileFingerprint &&
        _wheelFingerprint(wheel) == snapshot.wheelFingerprint &&
        _sameSelectedFilters(snapshot.filters) &&
        _targetPercent == snapshot.targetPercent &&
        minExposure == snapshot.minExposure &&
        maxExposure == snapshot.maxExposure;
  }

  bool _isActiveRun(int generation, FlatCancelToken token) =>
      mounted && generation == _runGeneration && identical(token, _cancelToken);

  void _requestCancel() {
    final token = _cancelToken;
    if (token == null || token.isCancelled) return;
    token.cancel();
    setState(() {
      _calculationStatus = 'Cancelling and waiting for the camera to stop...';
    });
  }

  Future<void> _calculateExposure() async {
    if (_isCalculating) return;
    if (_selectedFilters.isEmpty) {
      setState(() {
        _errorMessage = 'Select at least one filter before calibration.';
      });
      return;
    }

    final sequence = ref.read(currentSequenceProvider);
    if (sequence == null) {
      setState(() {
        _errorMessage = 'Create or open a sequence before adding flats.';
      });
      return;
    }

    final camera = ref.read(cameraStateProvider);
    if (camera.connectionState != DeviceConnectionState.connected ||
        camera.deviceId == null) {
      setState(() {
        _errorMessage = 'Connect a camera before calibration.';
      });
      return;
    }

    final minExposure = double.tryParse(_minExposureController.text.trim());
    final maxExposure = double.tryParse(_maxExposureController.text.trim());
    if (minExposure == null ||
        maxExposure == null ||
        !minExposure.isFinite ||
        !maxExposure.isFinite ||
        minExposure <= 0 ||
        maxExposure <= minExposure) {
      setState(() {
        _errorMessage =
            'Enter finite exposure limits greater than zero, with maximum '
            'greater than minimum.';
      });
      return;
    }

    final wheel = ref.read(filterWheelStateProvider);
    final profileFilters = ref.read(profileFiltersProvider);
    final filters = _orderedSelectedFilters(
      _availableFilters(wheel, profileFilters),
    );
    if (filters.length > 1 &&
        (wheel.connectionState != DeviceConnectionState.connected ||
            wheel.deviceId == null)) {
      setState(() {
        _errorMessage =
            'Connect a filter wheel to calibrate multiple filters. Without a '
            'wheel, calibrate one manually installed filter at a time.';
      });
      return;
    }
    if (wheel.connectionState == DeviceConnectionState.connected &&
        wheel.deviceId != null) {
      final missing =
          filters.where((filter) => !wheel.filterNames.contains(filter));
      if (missing.isNotEmpty) {
        setState(() {
          _errorMessage = 'The connected filter wheel does not report: '
              '${missing.join(', ')}. Refresh its filter names before '
              'calibration.';
        });
        return;
      }
    }

    final token = FlatCancelToken();
    final generation = ++_runGeneration;
    _cancelToken = token;
    setState(() {
      _isCalculating = true;
      _errorMessage = null;
      _calculationStatus = 'Reading camera capabilities...';
      _snapshot = null;
      _results.clear();
    });

    try {
      final config = await ref
          .read(flatCameraConfigProvider.notifier)
          .resolve(failIfStale: true);
      if (!_isActiveRun(generation, token)) return;
      if (!config.rangeKnown) {
        setState(() {
          _errorMessage =
              'The camera did not report an ADU range or bit depth. '
              'Reconnect it or refresh capabilities before automatic '
              'calibration.';
        });
        return;
      }
      if (config.binX != config.binY) {
        setState(() {
          _errorMessage = 'The sequence format cannot represent asymmetric '
              '${config.binX}×${config.binY} binning. Choose symmetric '
              'binning in the active equipment profile and recalculate.';
        });
        return;
      }

      final profile = ref.read(activeEquipmentProfileProvider);
      final liveWheel = ref.read(filterWheelStateProvider);
      final snapshot = _FlatCalibrationSnapshot(
        sequenceId: sequence.id,
        cameraId: camera.deviceId!,
        profileFingerprint: _profileFingerprint(profile),
        wheelFingerprint: _wheelFingerprint(liveWheel),
        filters: List.unmodifiable(filters),
        captureConfig: config,
        targetPercent: _targetPercent,
        targetAdu: config.targetAduFor(_targetPercent),
        minExposure: minExposure,
        maxExposure: maxExposure,
      );

      final flatService = ref.read(flatWizardServiceProvider);
      for (var i = 0; i < snapshot.filters.length; i++) {
        if (token.isCancelled) break;
        final filter = snapshot.filters[i];

        if (liveWheel.connectionState == DeviceConnectionState.connected &&
            liveWheel.deviceId != null) {
          final position = liveWheel.filterNames.indexOf(filter);
          final moveError = await ref
              .read(flatWizardProvider.notifier)
              .moveFilterWheelAndWait(position, token);
          if (!_isActiveRun(generation, token)) return;
          if (token.isCancelled) break;
          if (moveError != null) {
            setState(() {
              _errorMessage = '$filter: $moveError. Calibration stopped.';
            });
            break;
          }
        }

        if (!_snapshotContextIsCurrent(snapshot)) {
          token.cancel();
          setState(() {
            _results.clear();
            _errorMessage =
                'The sequence or equipment configuration changed during '
                'calibration. Recalculate with the current setup.';
          });
          break;
        }

        final result = await flatService.calibrateFilter(
          deviceId: snapshot.cameraId,
          filter: filter,
          gain: config.gain,
          offset: config.offset,
          targetAdu: snapshot.targetAdu,
          tolerance: _tolerancePercent,
          minExposure: snapshot.minExposure,
          maxExposure: snapshot.maxExposure,
          binX: config.binX,
          binY: config.binY,
          cancelToken: token,
          onProgress: (iteration, exposure, adu) {
            if (!_isActiveRun(generation, token) || token.isCancelled) return;
            setState(() {
              _calculationStatus =
                  '$filter (${i + 1}/${snapshot.filters.length}) — iteration '
                  '$iteration: ${exposure.toStringAsFixed(3)}s, ADU '
                  '${adu.toStringAsFixed(0)}';
            });
          },
        );
        if (!_isActiveRun(generation, token)) return;
        if (result.cancelled || token.isCancelled) break;
        setState(() {
          _results[filter] = result;
          if (!result.success) {
            _errorMessage =
                '$filter: ${result.errorMessage ?? 'did not converge within '
                    'the configured exposure limits.'}';
          }
        });
        if (result.haltRun) break;
      }

      if (!_isActiveRun(generation, token)) return;
      if (token.isCancelled) {
        setState(() {
          _snapshot = null;
          _calculationStatus = 'Calibration cancelled.';
        });
      } else if (snapshot.filters
          .every((filter) => _results[filter]?.success == true)) {
        if (_snapshotContextIsCurrent(snapshot)) {
          setState(() {
            _snapshot = snapshot;
            _calculationStatus =
                'Calibration complete for ${snapshot.filters.length} '
                'filter${snapshot.filters.length == 1 ? '' : 's'}';
          });
        } else {
          setState(() {
            _results.clear();
            _snapshot = null;
            _errorMessage = 'The sequence or equipment configuration changed. '
                'Recalculate before generating flat nodes.';
          });
        }
      }
    } catch (error) {
      if (_isActiveRun(generation, token)) {
        setState(() {
          _snapshot = null;
          _errorMessage = 'Calibration failed: $error';
        });
      }
    } finally {
      if (_isActiveRun(generation, token)) {
        setState(() {
          _isCalculating = false;
          _cancelToken = null;
        });
      }
    }
  }

  void _generateFlatSequence() {
    final snapshot = _snapshot;
    if (snapshot == null || !_allCalibrated) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Run calibration successfully first.')),
      );
      return;
    }
    if (!_snapshotContextIsCurrent(snapshot)) {
      setState(() {
        _invalidateCalibration();
        _errorMessage =
            'The sequence or equipment configuration changed. Recalculate '
            'before generating flat nodes.';
      });
      return;
    }

    final calibrations = <FlatResult>[
      for (final filter in snapshot.filters) _results[filter]!,
    ];
    final nodes = ref.read(flatWizardServiceProvider).generateFlatSequence(
          calibrations: calibrations,
          framesPerFilter: _framesPerFilter,
          binX: snapshot.captureConfig.binX,
          binY: snapshot.captureConfig.binY,
          gain: snapshot.captureConfig.gain,
          offset: snapshot.captureConfig.offset,
          onlySuccessful: true,
        );

    if (nodes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No flat nodes were generated.')),
      );
      return;
    }

    try {
      final notifier = ref.read(currentSequenceProvider.notifier);
      notifier.withUndoGroup(() {
        for (final node in nodes) {
          notifier.addNode(node);
        }
      });
    } catch (error) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not add flat nodes: $error')),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Added ${nodes.length} calibrated flat capture '
          'node${nodes.length == 1 ? '' : 's'}. '
          'Save the sequence to persist them.',
        ),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SkotiqColors.of(context);

    return PopScope(
      canPop: !_isCalculating,
      child: SkotiqDialog(
        title: 'Calibrate Flat Exposures',
        icon: SkotiqIcons.sun,
        width: 700,
        height: 600,
        scrollableBody: false,
        bodyPadding: EdgeInsets.zero,
        showCloseButton: !_isCalculating,
        child: Stepper(
          currentStep: _currentStep,
          onStepContinue: _isCalculating
              ? null
              : () {
                  if (_currentStep == 1 && !_allCalibrated) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Run calibration successfully first.'),
                      ),
                    );
                    return;
                  }
                  if (_currentStep < 2) {
                    setState(() => _currentStep++);
                  } else {
                    _generateFlatSequence();
                  }
                },
          onStepCancel: _isCalculating
              ? _requestCancel
              : () {
                  if (_currentStep > 0) {
                    setState(() => _currentStep--);
                  } else {
                    Navigator.of(context).pop();
                  }
                },
          controlsBuilder: (context, details) {
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                children: [
                  SkotiqButton(
                    onPressed: details.onStepContinue,
                    label: _currentStep == 2 ? 'Generate' : 'Continue',
                    variant: ButtonVariant.primary,
                  ),
                  const SizedBox(width: 12),
                  SkotiqButton(
                    onPressed: details.onStepCancel,
                    label: _isCalculating
                        ? 'Cancel calibration'
                        : (_currentStep == 0 ? 'Cancel' : 'Back'),
                    variant: _isCalculating
                        ? ButtonVariant.destructive
                        : ButtonVariant.ghost,
                  ),
                ],
              ),
            );
          },
          steps: [
            Step(
              title: const Text('Configuration'),
              isActive: _currentStep >= 0,
              state: _currentStep > 0 ? StepState.complete : StepState.indexed,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildTargetAduSlider(colors),
                  const SizedBox(height: 24),
                  _buildFilterSelector(colors),
                  const SizedBox(height: 24),
                  _buildFramesPerFilterControl(colors),
                  const SizedBox(height: 24),
                  _buildExposureLimits(),
                ],
              ),
            ),
            Step(
              title: const Text('Calculate Exposure'),
              isActive: _currentStep >= 1,
              state: _currentStep > 1 ? StepState.complete : StepState.indexed,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'The wizard selects and verifies each connected filter, '
                    'then measures the exposure needed for the target signal.',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  if (_calculationStatus != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _calculationStatus!,
                        style: theme.textTheme.bodySmall,
                        textAlign: TextAlign.center,
                      ),
                    ),
                  if (_errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        _errorMessage!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.error,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  for (final filter in _selectedFilters)
                    _buildFilterResultCard(colors, theme, filter),
                  const SizedBox(height: 8),
                  SkotiqButton(
                    onPressed:
                        _isCalculating ? _requestCancel : _calculateExposure,
                    icon: _isCalculating
                        ? LucideIcons.xCircle
                        : LucideIcons.calculator,
                    label: _isCalculating
                        ? 'Cancel calibration'
                        : (_results.isEmpty ? 'Calculate' : 'Recalculate'),
                    variant: _isCalculating
                        ? ButtonVariant.destructive
                        : ButtonVariant.primary,
                  ),
                ],
              ),
            ),
            Step(
              title: const Text('Review'),
              isActive: _currentStep >= 2,
              content: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline8),
                  border: Border.all(color: colors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildReviewRow(
                      'Target signal:',
                      '${_targetPercent.toStringAsFixed(0)}% '
                          '(${_snapshot?.targetAdu.toStringAsFixed(0)} ADU)',
                    ),
                    _buildReviewRow(
                      'Capture settings:',
                      _snapshot == null
                          ? 'Not calibrated'
                          : '${_snapshot!.captureConfig.binX}×'
                              '${_snapshot!.captureConfig.binY}, gain '
                              '${_snapshot!.captureConfig.gain ?? 'camera default'}, '
                              'offset '
                              '${_snapshot!.captureConfig.offset ?? 'camera default'}',
                    ),
                    _buildReviewRow(
                      'Frames per filter:',
                      '$_framesPerFilter',
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Calibrated filters',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    for (final filter in _selectedFilters)
                      _buildReviewRow(
                        '$filter:',
                        _results[filter]?.success == true
                            ? '${_results[filter]!.exposure.toStringAsFixed(3)}s '
                                '× $_framesPerFilter'
                            : 'Not calculated',
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTargetAduSlider(SkotiqColors colors) {
    final config = ref.watch(flatCameraConfigProvider);
    final targetAdu = config.targetAduFor(_targetPercent).round();
    final rangeLabel = config.rangeKnown
        ? '$targetAdu / ${config.maxAdu} ADU'
        : 'camera range not detected';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Target signal'),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '${_targetPercent.toStringAsFixed(0)}% · $rangeLabel',
                textAlign: TextAlign.end,
                style: TextStyle(
                  color: config.rangeKnown ? colors.primary : colors.warning,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: _targetPercent,
          min: 20,
          max: 80,
          divisions: 60,
          onChanged: _isCalculating
              ? null
              : (value) =>
                  _changeCalibrationInput(() => _targetPercent = value),
          activeColor: colors.primary,
        ),
      ],
    );
  }

  Widget _buildFilterSelector(SkotiqColors colors) {
    final profileFilters = ref.watch(profileFiltersProvider);
    final wheel = ref.watch(filterWheelStateProvider);
    final availableFilters = _availableFilters(wheel, profileFilters);
    final usesManualFilter =
        wheel.filterNames.isEmpty && profileFilters.isEmpty;

    final hasStaleSelection =
        _selectedFilters.any((filter) => !availableFilters.contains(filter));
    if (hasStaleSelection && !_isCalculating) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _isCalculating) return;
        setState(() {
          _selectedFilters
              .removeWhere((filter) => !availableFilters.contains(filter));
          if (_selectedFilters.isEmpty && availableFilters.isNotEmpty) {
            _selectedFilters.add(availableFilters.first);
          }
          _invalidateCalibration();
        });
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Filters to calibrate'),
        const SizedBox(height: 8),
        if (usesManualFilter)
          TextField(
            controller: _manualFilterController,
            enabled: !_isCalculating,
            decoration: const InputDecoration(
              labelText: 'Manual filter name',
              helperText: 'Use “Unfiltered” when no filter is installed.',
            ),
            onChanged: (value) {
              if (_isCalculating) return;
              _changeCalibrationInput(() {
                _selectedFilters.clear();
                final filter = value.trim();
                if (filter.isNotEmpty) _selectedFilters.add(filter);
              });
            },
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final filter in availableFilters)
                FilterChip(
                  label: Text(filter),
                  selected: _selectedFilters.contains(filter),
                  onSelected: _isCalculating
                      ? null
                      : (selected) {
                          _changeCalibrationInput(() {
                            if (selected) {
                              _selectedFilters.add(filter);
                            } else {
                              _selectedFilters.remove(filter);
                            }
                          });
                        },
                ),
            ],
          ),
        const SizedBox(height: 4),
        InkWell(
          onTap:
              _isCalculating ? null : () => ProfileEditorDialog.show(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.settings, size: 12, color: colors.textMuted),
                const SizedBox(width: 4),
                Text(
                  'Edit filters...',
                  style: TextStyle(
                    fontSize: SkotiqTypography.fontSize11,
                    color: colors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFramesPerFilterControl(SkotiqColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Frames per filter'),
            const Spacer(),
            Text(
              '$_framesPerFilter',
              style: TextStyle(
                color: colors.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: _framesPerFilter.toDouble(),
          min: 1,
          max: 100,
          divisions: 99,
          onChanged: _isCalculating
              ? null
              : (value) => setState(() => _framesPerFilter = value.round()),
          activeColor: colors.primary,
        ),
      ],
    );
  }

  Widget _buildFilterResultCard(
    SkotiqColors colors,
    ThemeData theme,
    String filter,
  ) {
    final result = _results[filter];
    final isCalibrated = result?.success == true;
    final isFailed = result != null && !result.success;
    final accent = isCalibrated
        ? colors.success
        : isFailed
            ? colors.error
            : colors.border;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusInline8),
        border: Border.all(color: accent),
      ),
      child: Row(
        children: [
          Icon(
            isCalibrated
                ? SkotiqIcons.success
                : isFailed
                    ? SkotiqIcons.error
                    : SkotiqIcons.idea,
            color: accent,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              filter,
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            isCalibrated
                ? '${result!.exposure.toStringAsFixed(3)}s @ '
                    '${result.adu.toStringAsFixed(0)} ADU'
                : isFailed
                    ? 'Failed'
                    : 'Pending',
            style: theme.textTheme.bodySmall?.copyWith(color: accent),
          ),
        ],
      ),
    );
  }

  Widget _buildExposureLimits() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _minExposureController,
            enabled: !_isCalculating,
            decoration: const InputDecoration(labelText: 'Min Exposure (s)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) {
              if (_isCalculating) return;
              setState(_invalidateCalibration);
            },
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: TextField(
            controller: _maxExposureController,
            enabled: !_isCalculating,
            decoration: const InputDecoration(labelText: 'Max Exposure (s)'),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) {
              if (_isCalculating) return;
              setState(_invalidateCalibration);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildReviewRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
          Flexible(child: Text(value, textAlign: TextAlign.end)),
        ],
      ),
    );
  }
}
