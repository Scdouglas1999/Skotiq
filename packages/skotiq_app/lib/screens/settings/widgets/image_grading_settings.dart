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

import 'dart:async';

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
  const ImageGradingSettings({
    super.key,
  });

  @override
  ConsumerState<ImageGradingSettings> createState() =>
      _ImageGradingSettingsState();
}

class _ImageGradingSettingsState extends ConsumerState<ImageGradingSettings> {
  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(appSettingsProvider);

    return settingsAsync.when(
      loading: () => const SettingsLoadingState(),
      error: (error, stack) => SettingsErrorState(
        error: error,
        onRetry: () => ref.invalidate(appSettingsProvider),
      ),
      data: (settings) {
        final notifier = ref.read(appSettingsProvider.notifier);
        final enabled = settings.enableImageGrading;

        return SettingsPage(
          title: 'Image grading',
          description:
              'Auto-reject blurry / trailed / clouded frames at capture time',
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
                  trailing: _gradingField<double?>(
                    inputKey: const ValueKey('image-grading-hfr-threshold'),
                    // Clamped to what the detector can report: below the floor
                    // every frame is a reject, past the ceiling the gate is
                    // dead. See _hfrFloorPx / _hfrCeilingPx.
                    codec: const OptionalCodec(
                      NumberCodec(
                        min: _hfrFloorPx,
                        max: _hfrCeilingPx,
                        decimals: 2,
                        unit: 'px',
                        fixedDecimals: true,
                      ),
                    ),
                    value: settings.imageGradingHfrThresholdPx,
                    enabled: enabled,
                    onChanged: notifier.setImageGradingHfrThreshold,
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.trendingUp,
                  title: 'HFR baseline percent',
                  subtitle:
                      'Reject if HFR is more than this percent above the baseline, the median of the first 5 accepted frames of the run.',
                  trailing: _gradingField<double?>(
                    inputKey:
                        const ValueKey('image-grading-hfr-baseline-percent'),
                    codec: const OptionalCodec(
                      NumberCodec(
                        min: 1.0,
                        max: 500.0,
                        decimals: 0,
                        unit: '%',
                        fixedDecimals: true,
                      ),
                    ),
                    value: settings.imageGradingHfrBaselinePercent,
                    enabled: enabled,
                    onChanged: notifier.setImageGradingHfrBaselinePercent,
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
                  trailing: _gradingField<double?>(
                    inputKey:
                        const ValueKey('image-grading-eccentricity-threshold'),
                    codec: const OptionalCodec(
                      NumberCodec(
                        min: 0.0,
                        max: _eccentricityMaxInput,
                        decimals: 2,
                        unit: '',
                        fixedDecimals: true,
                      ),
                    ),
                    value: settings.imageGradingEccentricityThreshold,
                    enabled: enabled,
                    onChanged: notifier.setImageGradingEccentricityThreshold,
                  ),
                ),
                SettingRow(
                  icon: LucideIcons.star,
                  title: 'Star count min',
                  subtitle:
                      'Reject if fewer stars than this are detected, or fewer than half the stars of the first 3 accepted frames of the same target and filter. Trips when clouds roll in, stars trail, or the slew misses the target. Leave blank to disable both.',
                  trailing: _gradingField<int?>(
                    inputKey:
                        const ValueKey('image-grading-star-count-minimum'),
                    codec: const OptionalCodec(
                      IntCodec(min: 1, max: 100000, unit: 'stars'),
                    ),
                    value: settings.imageGradingStarCountMin,
                    enabled: enabled,
                    onChanged: notifier.setImageGradingStarCountMin,
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
                  trailing: _gradingField<int>(
                    inputKey: const ValueKey('image-grading-max-rejects'),
                    codec: const IntCodec(min: 1, max: 100, unit: 'frames'),
                    value: settings.imageGradingMaxConsecutiveRejects,
                    enabled: enabled,
                    onChanged: notifier.setImageGradingMaxConsecutiveRejects,
                  ),
                  isLast: true,
                ),
              ],
            ),
            const FrameWatchSettingsSection(),
            SettingsSection(
              title: 'Reject folder',
              children: [
                SettingRow(
                  icon: LucideIcons.folderX,
                  title: 'Reject folder path',
                  subtitle:
                      'Where rejected frames go. Leave blank for a Reject folder beside the frames, <save_path>/<target>/Reject/. A relative path is taken from the frames\' folder; an absolute path is used as it is.',
                  trailing: SettingsTextInput(
                    authoritativeValue:
                        settings.imageGradingRejectFolderPath ?? '',
                    hint: '<save_path>/<target>/Reject/',
                    onChanged: (value) async {
                      // SettingsTextInput commits on Enter or blur and the
                      // setter trims empty input to null.
                      await notifier.setImageGradingRejectFolderPath(value);
                    },
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

/// A threshold field in this page's outlined style. An optional codec makes
/// an empty field mean "check disabled".
Widget _gradingField<T>({
  required Key inputKey,
  required SettingCodec<T> codec,
  required T value,
  required bool enabled,
  required FutureOr<void> Function(T value) onChanged,
}) {
  return SettingsValueField<T>(
    inputKey: inputKey,
    codec: codec,
    value: value,
    enabled: enabled,
    onChanged: onChanged,
    hint: codec is OptionalCodec ? '\u2014' : '',
    builder: (context, parts) {
      final colors = SkotiqColors.of(context);
      final radius = BorderRadius.circular(SkotiqTokens.radiusMd);
      return Opacity(
        opacity: parts.enabled ? 1.0 : 0.5,
        child: IgnorePointer(
          ignoring: !parts.enabled,
          child: SettingsControlBox(
            width: 140,
            narrowWidth: 120,
            child: TextField(
              key: parts.inputKey,
              controller: parts.controller,
              focusNode: parts.focusNode,
              keyboardType: parts.keyboardType,
              inputFormatters: parts.inputFormatters,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textPrimary,
              ),
              decoration: InputDecoration(
                hintText: parts.hint,
                suffixText: parts.unit.isEmpty ? null : parts.unit,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                border: OutlineInputBorder(borderRadius: radius),
                enabledBorder: parts.hasProblem
                    ? OutlineInputBorder(
                        borderRadius: radius,
                        borderSide: BorderSide(color: colors.error),
                      )
                    : null,
              ),
              onChanged: parts.onChanged,
              onSubmitted: parts.onSubmitted,
            ),
          ),
        ),
      );
    },
  );
}
