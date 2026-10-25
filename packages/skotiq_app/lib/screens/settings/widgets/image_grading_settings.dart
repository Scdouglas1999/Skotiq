// Image-grading settings UI.
//
// Surfaces the master toggle and per-check thresholds that the Rust
// executor's `RuntimeConfig.default_quality_check` reads at sequence
// start. Each numeric threshold is independently nullable so an operator
// can enable just the checks they want (e.g. "absolute HFR + min star
// count" without the eccentricity gate). The master toggle is the
// safety valve: when false, grading is disabled regardless of the
// individual thresholds.
//
// FITS-side companion: see `expose.rs` / `image_grading.rs` for how
// these thresholds drive the per-frame Pass/Reject decision and the
// reject-folder side-channel.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'frame_watch_settings_section.dart';
import 'settings_widgets.dart';

// Bounds of what the capture pipeline can actually measure, mirrored from
// `skotiq_imaging`. A threshold outside them is not a strict setting, it is
// a gate that can never fire (or one that rejects every frame), and on screen a
// dead gate looks exactly like a live one. The inputs clamp to these bounds;
// `_hfrInertNote` / `_eccentricityInertNote` call out values persisted before
// the bounds existed, which load unclamped.

/// `frame_shape::MIN_HFR` — the grader leaves out any star under 1.0 px as a
/// hot pixel, so the median HFR it grades is never below it and a threshold
/// under it rejects every frame that has stars.
const double _hfrFloorPx = 1.0;

/// `frame_shape::APERTURE_RADIUS` — the grader measures each star's half-flux
/// radius inside a 10 px aperture, so no frame grades at an HFR past it.
const double _hfrCeilingPx = 10.0;

/// `skotiq_imaging::DETECTION_MAX_ECCENTRICITY` — `detect_stars` drops
/// anything more elongated as a streak, so the median `frame_eccentricity`
/// returns is never above it. Grading rejects on `ecc > threshold`, so a
/// threshold *at* the ceiling is as dead as one above it.
const double _eccentricityCeiling = 0.95;

/// Highest threshold the gate can still fire on, at the field's 2 decimals.
const double _eccentricityMaxInput = 0.94;

/// Warning appended to a threshold's subtitle when the stored value sits
/// outside the measurable range. Returns null while the value is usable.
String? _hfrInertNote(double? value) {
  if (value == null) return null;
  if (value < _hfrFloorPx) {
    return 'Heads up: at ${value.toStringAsFixed(2)} px this rejects every '
        'frame — the detector never reports an HFR below '
        '${_hfrFloorPx.toStringAsFixed(2)} px.';
  }
  if (value >= _hfrCeilingPx) {
    return 'Heads up: at ${value.toStringAsFixed(2)} px this check never '
        'fires — HFR is measured inside a '
        '${_hfrCeilingPx.toStringAsFixed(0)} px window, so no frame reports '
        'more.';
  }
  return null;
}

/// Eccentricity counterpart to [_hfrInertNote].
String? _eccentricityInertNote(double? value) {
  if (value == null || value < _eccentricityCeiling) return null;
  return 'Heads up: at ${value.toStringAsFixed(2)} this check never fires — '
      'the detector stops measuring past '
      '${_eccentricityCeiling.toStringAsFixed(2)} and reads anything more '
      'elongated as a streak, not a star.';
}

String _withNote(String base, String? note) =>
    note == null ? base : '$base $note';

class ImageGradingSettings extends ConsumerStatefulWidget {
  final bool isMobile;

  const ImageGradingSettings({
    super.key,
    this.isMobile = false,
  });

  @override
  ConsumerState<ImageGradingSettings> createState() =>
      _ImageGradingSettingsState();
}

class _ImageGradingSettingsState extends ConsumerState<ImageGradingSettings> {
  final _hfrController = TextEditingController();
  final _baselineController = TextEditingController();
  final _eccentricityController = TextEditingController();
  final _starCountController = TextEditingController();
  final _maxRejectsController = TextEditingController();
  final _rejectFolderController = TextEditingController();
  final _lastSyncedValues = <TextEditingController, String>{};

  @override
  void dispose() {
    _hfrController.dispose();
    _baselineController.dispose();
    _eccentricityController.dispose();
    _starCountController.dispose();
    _maxRejectsController.dispose();
    _rejectFolderController.dispose();
    super.dispose();
  }

  void _syncController(TextEditingController controller, String value) {
    // Only overwrite when the committed setting changed. Rebuilds caused by an
    // unrelated toggle must not erase text the operator is still editing.
    if (_lastSyncedValues[controller] == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _lastSyncedValues[controller] = value;
  }

  void _syncControllers(AppSettingsState settings) {
    _syncController(
      _hfrController,
      settings.imageGradingHfrThresholdPx?.toStringAsFixed(2) ?? '',
    );
    _syncController(
      _baselineController,
      settings.imageGradingHfrBaselinePercent?.toStringAsFixed(0) ?? '',
    );
    _syncController(
      _eccentricityController,
      settings.imageGradingEccentricityThreshold?.toStringAsFixed(2) ?? '',
    );
    _syncController(
      _starCountController,
      settings.imageGradingStarCountMin?.toString() ?? '',
    );
    _syncController(
      _maxRejectsController,
      settings.imageGradingMaxConsecutiveRejects.toString(),
    );
    _syncController(
      _rejectFolderController,
      settings.imageGradingRejectFolderPath ?? '',
    );
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => SettingsLoadingState(
        isMobile: widget.isMobile,
      ),
      error: (error, stack) => SettingsErrorState(
        isMobile: widget.isMobile,
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        _syncControllers(settings);
        final notifier = ref.read(appSettingsProvider.notifier);
        final enabled = settings.enableImageGrading;

        return SettingsPage(
          title: 'Image grading',
          description:
              'Auto-reject blurry / trailed / clouded frames at capture time',
          isMobile: widget.isMobile,
          hideHeader: widget.isMobile,
          children: [
            SettingsSection(
              title: 'Master toggle',
              children: [
                SettingRow(
                  icon: LucideIcons.toggleLeft,
                  title: 'Enable image grading',
                  subtitle:
                      'When on, every captured frame is scored against the thresholds below. Bad frames are moved to the reject folder.',
                  trailing: SettingsSwitch(
                    value: enabled,
                    onChanged: (value) async {
                      await notifier.setEnableImageGrading(value);
                    },
                  ),
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Focus thresholds',
              children: [
                SettingRow(
                  icon: LucideIcons.crosshair,
                  title: 'HFR absolute (pixels)',
                  subtitle: _withNote(
                    'Reject if the median HFR exceeds this many pixels. The right value depends on your pixel scale and seeing: a sharp frame at 0.8 arcsec/px measures about 2.5 px. The baseline check below adapts to your own frames. Leave blank to disable.',
                    _hfrInertNote(settings.imageGradingHfrThresholdPx),
                  ),
                  trailing: _OptionalNumberInput(
                    fieldKey: const ValueKey('image-grading-hfr-threshold'),
                    controller: _hfrController,
                    suffix: 'px',
                    // Clamped to what the detector can report: below the floor
                    // every frame is a reject, past the ceiling the gate is
                    // dead. See _hfrFloorPx / _hfrCeilingPx.
                    min: _hfrFloorPx,
                    max: _hfrCeilingPx,
                    decimals: 2,
                    enabled: enabled,
                    onCommit: (value) async {
                      await notifier.setImageGradingHfrThreshold(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.trendingUp,
                  title: 'HFR baseline percent',
                  subtitle:
                      'Reject if HFR is more than this percent above the baseline, the median of the first 5 accepted frames of the run.',
                  trailing: _OptionalNumberInput(
                    fieldKey:
                        const ValueKey('image-grading-hfr-baseline-percent'),
                    controller: _baselineController,
                    suffix: '%',
                    min: 1.0,
                    max: 500.0,
                    decimals: 0,
                    enabled: enabled,
                    onCommit: (value) async {
                      await notifier.setImageGradingHfrBaselinePercent(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Star shape thresholds',
              children: [
                SettingRow(
                  icon: LucideIcons.move,
                  title: 'Eccentricity max',
                  subtitle: _withNote(
                    'Reject if median star eccentricity across the frame exceeds this value. The default 0.8 is a 1.7:1 smear: in-focus frames on a fast Newtonian can measure 0.7 or a little more, while a trailed frame measures 0.8 and up. The field stops at 0.94 because the detector reads anything past 0.95 as a satellite trail rather than a star, so nothing rounder ever gets measured. Leave blank to disable.',
                    _eccentricityInertNote(
                      settings.imageGradingEccentricityThreshold,
                    ),
                  ),
                  trailing: _OptionalNumberInput(
                    fieldKey:
                        const ValueKey('image-grading-eccentricity-threshold'),
                    controller: _eccentricityController,
                    suffix: '',
                    min: 0.0,
                    max: _eccentricityMaxInput,
                    decimals: 2,
                    enabled: enabled,
                    onCommit: (value) async {
                      await notifier
                          .setImageGradingEccentricityThreshold(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.star,
                  title: 'Star count min',
                  subtitle:
                      'Reject if fewer stars than this are detected, or fewer than half the stars of the first 3 accepted frames of the same target and filter. Trips when clouds roll in, stars trail, or the slew misses the target. Leave blank to disable both.',
                  trailing: _OptionalIntInput(
                    fieldKey:
                        const ValueKey('image-grading-star-count-minimum'),
                    controller: _starCountController,
                    suffix: 'stars',
                    min: 1,
                    max: 100000,
                    enabled: enabled,
                    onCommit: (value) async {
                      await notifier.setImageGradingStarCountMin(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                  isLast: true,
                ),
              ],
            ),
            SettingsSection(
              title: 'Reject streaks',
              children: [
                SettingRow(
                  icon: LucideIcons.alertOctagon,
                  title: 'Notify after consecutive rejects',
                  subtitle:
                      'Send one notification when this many frames in a row are rejected: something is probably wrong (drifted focus, clouds, dome misalignment). The run keeps going and every frame is kept; rejects go to the Reject folder.',
                  trailing: _OptionalIntInput(
                    fieldKey: const ValueKey('image-grading-max-rejects'),
                    controller: _maxRejectsController,
                    suffix: 'frames',
                    min: 1,
                    max: 100,
                    enabled: enabled,
                    allowClear: false,
                    onCommit: (value) async {
                      if (value == null) return;
                      await notifier
                          .setImageGradingMaxConsecutiveRejects(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                  isLast: true,
                ),
              ],
            ),
            FrameWatchSettingsSection(isMobile: widget.isMobile),
            SettingsSection(
              title: 'Reject folder',
              children: [
                SettingRow(
                  icon: LucideIcons.folderX,
                  title: 'Reject folder path',
                  subtitle:
                      'Where rejected frames go. Leave blank for a Reject folder beside the frames, <save_path>/<target>/Reject/. A relative path is taken from the frames\' folder; an absolute path is used as it is.',
                  trailing: SettingsTextInput(
                    controller: _rejectFolderController,
                    hint: '<save_path>/<target>/Reject/',
                    onChanged: (value) async {
                      // SettingsTextInput commits on Enter or blur and the
                      // setter trims empty input to null.
                      await notifier.setImageGradingRejectFolderPath(value);
                    },
                    isMobile: widget.isMobile,
                  ),
                  isLast: true,
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

/// A number input that supports an "empty = null" state for the
/// optional thresholds. Clearing the field commits `null` to the setting
/// (disabling that specific check while keeping the master toggle on).
class _OptionalNumberInput extends StatelessWidget {
  final Key fieldKey;
  final TextEditingController controller;
  final String suffix;
  final double min;
  final double max;
  final int decimals;
  final bool enabled;
  final Future<void> Function(double?) onCommit;
  final bool isMobile;

  const _OptionalNumberInput({
    required this.fieldKey,
    required this.controller,
    required this.suffix,
    required this.min,
    required this.max,
    required this.decimals,
    required this.enabled,
    required this.onCommit,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context) {
    return _OptionalNumericInput<double>(
      fieldKey: fieldKey,
      controller: controller,
      suffix: suffix,
      enabled: enabled,
      allowClear: true,
      keyboardType: TextInputType.numberWithOptions(decimal: decimals > 0),
      tryParse: double.tryParse,
      normalize: (value) => value.clamp(min, max),
      format: (value) => value.toStringAsFixed(decimals),
      onCommit: onCommit,
      isMobile: isMobile,
    );
  }
}

/// Integer-only variant of `_OptionalNumberInput` for star
/// count + max consecutive rejects.
class _OptionalIntInput extends StatelessWidget {
  final Key fieldKey;
  final TextEditingController controller;
  final String suffix;
  final int min;
  final int max;
  final bool enabled;
  final bool allowClear;
  final Future<void> Function(int?) onCommit;
  final bool isMobile;

  const _OptionalIntInput({
    required this.fieldKey,
    required this.controller,
    required this.suffix,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onCommit,
    this.allowClear = true,
    this.isMobile = false,
  });

  @override
  Widget build(BuildContext context) {
    return _OptionalNumericInput<int>(
      fieldKey: fieldKey,
      controller: controller,
      suffix: suffix,
      enabled: enabled,
      allowClear: allowClear,
      keyboardType: TextInputType.number,
      tryParse: int.tryParse,
      normalize: (value) => value.clamp(min, max),
      format: (value) => value.toString(),
      onCommit: onCommit,
      isMobile: isMobile,
    );
  }
}

class _OptionalNumericInput<T extends num> extends StatefulWidget {
  final Key fieldKey;
  final TextEditingController controller;
  final String suffix;
  final bool enabled;
  final bool allowClear;
  final TextInputType keyboardType;
  final T? Function(String) tryParse;
  final T Function(T) normalize;
  final String Function(T) format;
  final Future<void> Function(T?) onCommit;
  final bool isMobile;

  const _OptionalNumericInput({
    required this.fieldKey,
    required this.controller,
    required this.suffix,
    required this.enabled,
    required this.allowClear,
    required this.keyboardType,
    required this.tryParse,
    required this.normalize,
    required this.format,
    required this.onCommit,
    required this.isMobile,
  });

  @override
  State<_OptionalNumericInput<T>> createState() =>
      _OptionalNumericInputState<T>();
}

class _OptionalNumericInputState<T extends num>
    extends State<_OptionalNumericInput<T>> {
  final _focusNode = FocusNode();
  late String _committedText;
  bool _saving = false;
  bool _submittedSinceLastEdit = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _committedText = widget.controller.text;
    _focusNode.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    if (_focusNode.hasFocus) return;
    if (_submittedSinceLastEdit) {
      _submittedSinceLastEdit = false;
      return;
    }
    _commit();
  }

  void _setText(String text) {
    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _commit() async {
    if (_saving) return;
    final raw = widget.controller.text.trim();
    T? value;
    late String canonical;
    if (raw.isEmpty) {
      if (!widget.allowClear) {
        _setText(_committedText);
        setState(() => _error = 'A value is required.');
        return;
      }
      canonical = '';
    } else {
      final parsed = widget.tryParse(raw);
      if (parsed == null) {
        _setText(_committedText);
        setState(() => _error = 'Enter a valid number.');
        return;
      }
      value = widget.normalize(parsed);
      canonical = widget.format(value);
    }

    _setText(canonical);
    if (canonical == _committedText) {
      if (_error != null) setState(() => _error = null);
      return;
    }

    final previous = _committedText;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onCommit(value);
      if (!mounted) return;
      _committedText = canonical;
    } catch (_) {
      if (!mounted) return;
      _setText(previous);
      setState(() => _error = 'Could not save. Previous value restored.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final effectiveWidth = widget.isMobile ? 120.0 : 140.0;
    final interactive = widget.enabled && !_saving;
    return Opacity(
      opacity: interactive ? 1.0 : 0.5,
      child: IgnorePointer(
        ignoring: !interactive,
        child: SizedBox(
          width: effectiveWidth,
          child: TextField(
            key: widget.fieldKey,
            controller: widget.controller,
            focusNode: _focusNode,
            keyboardType: widget.keyboardType,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textPrimary,
            ),
            decoration: InputDecoration(
              hintText: widget.allowClear ? '—' : '',
              suffixText: widget.suffix.isEmpty ? null : widget.suffix,
              errorText: _error,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(SkotiqTokens.radiusMd),
              ),
            ),
            onChanged: (_) {
              _submittedSinceLastEdit = false;
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) {
              _submittedSinceLastEdit = true;
              _commit();
            },
          ),
        ),
      ),
    );
  }
}
