import 'package:freezed_annotation/freezed_annotation.dart';

part 'meridian_flip_settings.freezed.dart';
part 'meridian_flip_settings.g.dart';

/// Method used to determine when to trigger a meridian flip
enum MeridianTriggerMethod {
  /// Flip X minutes after target crosses meridian
  minutesPastMeridian,

  /// Flip X minutes before mount tracking limit
  minutesBeforeLimit,

  /// Flip when hour angle exceeds threshold
  hourAngleThreshold,

  /// Flip when mount stops tracking due to hitting its custom tracking limits
  onTrackingLimitHit,
}

/// Extension for MeridianTriggerMethod display
extension MeridianTriggerMethodExtension on MeridianTriggerMethod {
  /// Whether the Dart-side standalone monitor can evaluate this trigger
  /// without an active native sequence.
  bool get supportsStandaloneMonitoring => switch (this) {
    MeridianTriggerMethod.minutesPastMeridian ||
    MeridianTriggerMethod.hourAngleThreshold => true,
    MeridianTriggerMethod.minutesBeforeLimit ||
    MeridianTriggerMethod.onTrackingLimitHit => false,
  };

  String? get standaloneMonitoringLimitation => switch (this) {
    MeridianTriggerMethod.minutesBeforeLimit =>
      'Mount tracking-limit time is only reported to an active sequence.',
    MeridianTriggerMethod.onTrackingLimitHit =>
      'Tracking-limit detection is only available inside an active sequence.',
    MeridianTriggerMethod.minutesPastMeridian ||
    MeridianTriggerMethod.hourAngleThreshold => null,
  };

  String get displayName {
    switch (this) {
      case MeridianTriggerMethod.minutesPastMeridian:
        return 'Minutes Past Meridian';
      case MeridianTriggerMethod.minutesBeforeLimit:
        return 'Minutes Before Limit';
      case MeridianTriggerMethod.hourAngleThreshold:
        return 'Hour Angle Threshold';
      case MeridianTriggerMethod.onTrackingLimitHit:
        return 'On Tracking Limit Hit';
    }
  }

  String get description {
    switch (this) {
      case MeridianTriggerMethod.minutesPastMeridian:
        return 'Flip a specified number of minutes after the target crosses the meridian';
      case MeridianTriggerMethod.minutesBeforeLimit:
        return 'Flip a specified number of minutes before the mount reaches its tracking limit';
      case MeridianTriggerMethod.hourAngleThreshold:
        return 'Flip when the hour angle exceeds a specified threshold';
      case MeridianTriggerMethod.onTrackingLimitHit:
        return 'Flip when mount stops tracking due to hitting its custom tracking limits';
    }
  }
}

/// Action to take when meridian flip fails after all retries
enum FlipFailureAction {
  /// Pause sequence and alert user for manual intervention
  pauseAndAlert,

  /// Abort sequence and park mount
  abortAndPark,
}

/// Extension for FlipFailureAction display
extension FlipFailureActionExtension on FlipFailureAction {
  String get displayName {
    switch (this) {
      case FlipFailureAction.pauseAndAlert:
        return 'Pause & Alert';
      case FlipFailureAction.abortAndPark:
        return 'Abort & Park';
    }
  }

  String get description {
    switch (this) {
      case FlipFailureAction.pauseAndAlert:
        return 'Pause the sequence and alert the user for manual intervention';
      case FlipFailureAction.abortAndPark:
        return 'Abort the sequence and park the mount to protect equipment';
    }
  }
}

/// Settings for auto meridian flip behavior
@freezed
abstract class MeridianFlipSettings with _$MeridianFlipSettings {
  const MeridianFlipSettings._();

  const factory MeridianFlipSettings({
    // Mode control
    /// Enable standalone monitoring when no sequence is running
    @Default(false) bool standaloneMonitoringEnabled,

    // Trigger conditions
    /// Which method to use for determining flip timing
    @Default(MeridianTriggerMethod.minutesPastMeridian)
    MeridianTriggerMethod triggerMethod,

    /// Minutes past meridian to trigger flip (default: 5)
    @Default(5.0) double minutesPastMeridian,

    /// Minutes before mount limit to trigger flip (default: 10)
    @Default(10.0) double minutesBeforeLimit,

    /// Hour angle threshold in hours to trigger flip (default: 0.5 = 30 min)
    @Default(0.5) double hourAngleThreshold,

    /// Minutes to wait after tracking limit hit before flipping (0 = immediate).
    /// Only used with onTrackingLimitHit trigger method.
    @Default(0.0) double trackingLimitWaitMinutes,

    // Flip sequence options
    /// Pause guider before flip
    @Default(true) bool pauseGuidingBeforeFlip,

    /// Plate solve and re-center after flip
    @Default(true) bool recenterAfterFlip,

    /// Run autofocus after flip
    @Default(false) bool refocusAfterFlip,

    /// Settle time in seconds after flip completes
    @Default(10.0) double settleTimeSeconds,

    /// Resume guiding after flip (if was running)
    @Default(true) bool resumeGuidingAfterFlip,

    // Error handling
    /// Maximum retry attempts
    @Default(3) int maxRetries,

    /// Delay between retries in seconds
    @Default([30.0, 60.0, 120.0]) List<double> retryDelaysSeconds,

    /// Action to take on permanent failure
    @Default(FlipFailureAction.pauseAndAlert) FlipFailureAction failureAction,

    // Notifications
    /// Play sound alert when flip starts/completes/fails
    @Default(false) bool soundAlertOnFlip,

    /// Send push notification to mobile app
    @Default(true) bool pushNotificationOnFlip,
  }) = _MeridianFlipSettings;

  factory MeridianFlipSettings.fromJson(Map<String, dynamic> json) =>
      _$MeridianFlipSettingsFromJson(json);

  /// Get the currently active trigger value based on the selected method
  double get activeTriggerValue {
    switch (triggerMethod) {
      case MeridianTriggerMethod.minutesPastMeridian:
        return minutesPastMeridian;
      case MeridianTriggerMethod.minutesBeforeLimit:
        return minutesBeforeLimit;
      case MeridianTriggerMethod.hourAngleThreshold:
        return hourAngleThreshold;
      case MeridianTriggerMethod.onTrackingLimitHit:
        return trackingLimitWaitMinutes;
    }
  }

  /// Get the unit for the currently active trigger value
  String get activeTriggerUnit {
    switch (triggerMethod) {
      case MeridianTriggerMethod.minutesPastMeridian:
        return 'minutes';
      case MeridianTriggerMethod.minutesBeforeLimit:
        return 'minutes';
      case MeridianTriggerMethod.hourAngleThreshold:
        return 'hours';
      case MeridianTriggerMethod.onTrackingLimitHit:
        return 'minutes';
    }
  }

  /// Get the retry delay for a specific attempt (0-indexed)
  /// Returns the last delay if attempt exceeds available delays
  double getRetryDelay(int attempt) {
    if (retryDelaysSeconds.isEmpty) {
      return 30.0; // Default fallback
    }
    if (attempt >= retryDelaysSeconds.length) {
      return retryDelaysSeconds.last;
    }
    return retryDelaysSeconds[attempt];
  }

  /// Whether any post-flip operations are enabled
  bool get hasPostFlipOperations =>
      recenterAfterFlip || refocusAfterFlip || resumeGuidingAfterFlip;

  /// Validate settings and return any validation errors
  List<String> validate() {
    final errors = <String>[];

    if (minutesPastMeridian < 0) {
      errors.add('Minutes past meridian cannot be negative');
    }
    if (minutesPastMeridian > 120) {
      errors.add('Minutes past meridian should not exceed 120 minutes');
    }

    if (minutesBeforeLimit < 0) {
      errors.add('Minutes before limit cannot be negative');
    }
    if (minutesBeforeLimit > 120) {
      errors.add('Minutes before limit should not exceed 120 minutes');
    }

    if (hourAngleThreshold < 0) {
      errors.add('Hour angle threshold cannot be negative');
    }
    if (hourAngleThreshold > 6) {
      errors.add('Hour angle threshold should not exceed 6 hours');
    }

    if (trackingLimitWaitMinutes < 0) {
      errors.add('Tracking limit wait time cannot be negative');
    }
    if (trackingLimitWaitMinutes > 60) {
      errors.add('Tracking limit wait time should not exceed 60 minutes');
    }

    if (settleTimeSeconds < 0) {
      errors.add('Settle time cannot be negative');
    }
    if (settleTimeSeconds > 300) {
      errors.add('Settle time should not exceed 300 seconds');
    }

    if (maxRetries < 0) {
      errors.add('Max retries cannot be negative');
    }
    if (maxRetries > 10) {
      errors.add('Max retries should not exceed 10');
    }

    for (var i = 0; i < retryDelaysSeconds.length; i++) {
      if (retryDelaysSeconds[i] < 0) {
        errors.add('Retry delay ${i + 1} cannot be negative');
      }
      if (retryDelaysSeconds[i] > 600) {
        errors.add('Retry delay ${i + 1} should not exceed 600 seconds');
      }
    }

    return errors;
  }
}
