import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Captured lights that auto-calibration kept uncalibrated, and why.
class UncalibratedFrames {
  const UncalibratedFrames({
    required this.reason,
    required this.frames,
    this.dismissed = false,
  });

  /// What stopped the calibration, as the operator reads it.
  final String reason;

  /// Frames kept uncalibrated for [reason] so far.
  final int frames;

  /// The operator closed the notice; it stays closed for this cause.
  final bool dismissed;

  /// [reason] as a sentence.
  String get sentence {
    final text = reason.trim();
    if (text.isEmpty) return text;
    final capitalized = text[0].toUpperCase() + text.substring(1);
    return capitalized.endsWith('.') ? capitalized : '$capitalized.';
  }

  UncalibratedFrames copyWith({int? frames, bool? dismissed}) =>
      UncalibratedFrames(
        reason: reason,
        frames: frames ?? this.frames,
        dismissed: dismissed ?? this.dismissed,
      );
}

/// Whether captured lights are being kept uncalibrated while auto-calibration
/// is on. One cause is one notice: the next frame failing for the same reason
/// only counts, a calibrated frame or a change to the calibration settings
/// ends it.
class AutoCalibrationNotice extends StateNotifier<UncalibratedFrames?> {
  AutoCalibrationNotice() : super(null);

  /// Record a frame kept uncalibrated for [reason]. True when the cause is
  /// new, which is when the operator is told.
  bool keptUncalibrated(String reason) {
    final current = state;
    if (current != null && current.reason == reason) {
      state = current.copyWith(frames: current.frames + 1);
      return false;
    }
    state = UncalibratedFrames(reason: reason, frames: 1);
    return true;
  }

  /// A frame was calibrated, or the settings that decide it changed.
  void resolved() => state = null;

  void dismiss() => state = state?.copyWith(dismissed: true);
}
