import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

/// Thrown when the caller invokes the Live Activity service on a platform
/// that does not (and cannot) support it.
///
/// Thrown rather than no-op so a caller reaching this service from desktop or
/// Android code fails visibly instead of silently believing it started a Live
/// Activity.
class LiveActivityUnsupportedPlatformException implements Exception {
  LiveActivityUnsupportedPlatformException(this.message);

  final String message;

  @override
  String toString() => 'LiveActivityUnsupportedPlatformException: $message';
}

/// Host-side bridge to the iOS ActivityKit-backed Live Activity declared in
/// `apps/mobile/ios/SkotiqLiveActivity/`.
///
/// JSON keys passed across the [MethodChannel] mirror
/// `SkotiqLiveActivityAttributes.ContentState` field names 1:1. Touch
/// them only in lockstep with the Swift side; the [MethodChannel] is a
/// black-box JSON pipe, the field names ARE the schema.
///
/// Lifecycle:
///   * [start] requests an activity from ActivityKit and returns the host-
///     assigned `activityId`. Callers keep that id until the activity ends.
///   * [update] pushes a new `ContentState` snapshot.
///   * [end] dismisses the activity. Pass `dismissDate` to delay removal
///     of the lock-screen banner past `now`; defaults to immediate.
///
/// This service is iOS-only. Every method throws
/// [LiveActivityUnsupportedPlatformException] on non-iOS platforms.
class LiveActivityService {
  LiveActivityService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName);

  /// Public for tests that need to spy on the channel directly.
  static const String channelName = _channelName;
  static const String _channelName = 'skotiq/live_activity';

  final MethodChannel _channel;

  /// True iff the host platform can run Live Activities. The host bridge
  /// may further refuse if the user disabled Live Activities in Settings;
  /// we forward the result of `ActivityAuthorizationInfo.areActivitiesEnabled`.
  /// Returns false on non-iOS platforms.
  Future<bool> isSupported() async {
    if (!Platform.isIOS) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('isSupported');
      return result ?? false;
    } on PlatformException catch (e, st) {
      developer.log(
        '[LiveActivityService] isSupported failed: ${e.message}',
        name: 'LiveActivityService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  /// Start a new Live Activity for the given sequence.
  ///
  /// Returns the host-assigned activity id; pass it back to [update] /
  /// [end]. Throws a [PlatformException] from the host bridge if
  /// ActivityKit refuses (quota exhausted, disabled in Settings, missing
  /// widget extension).
  Future<String> start({
    required String sequenceId,
    required String targetName,
    required int framesCompleted,
    required int framesTotal,
    required int elapsedSeconds,
    int? estimatedRemainingSeconds,
    required String currentFilter,
    double? currentHfr,
    required String currentNodeName,
    required String jobState,
  }) async {
    _assertIos('start');
    final activityId = await _channel.invokeMethod<String>('start', {
      'sequenceId': sequenceId,
      'targetName': targetName,
      'framesCompleted': framesCompleted,
      'framesTotal': framesTotal,
      'elapsedSeconds': elapsedSeconds,
      'estimatedRemainingSeconds': estimatedRemainingSeconds,
      'currentFilter': currentFilter,
      'currentHfr': currentHfr,
      'currentNodeName': currentNodeName,
      'jobState': jobState,
    });
    if (activityId == null || activityId.isEmpty) {
      // The host always returns a non-empty id on success; null here means
      // the channel returned silently, which is a real bug. Don't swallow.
      throw PlatformException(
        code: 'invalid_host_response',
        message:
            'LiveActivityService.start: host returned no activityId. '
            'This indicates a host/Dart contract mismatch.',
      );
    }
    return activityId;
  }

  /// Push a new content-state snapshot for [activityId].
  ///
  /// Every state field is required so the Live Activity layouts never
  /// render mismatched data (e.g. last run's filter on this run's frame
  /// counter). Passing the full snapshot also matches Apple's intent that
  /// `Activity.update(_:)` receives a complete state.
  Future<void> update(
    String activityId, {
    required int framesCompleted,
    required int framesTotal,
    required int elapsedSeconds,
    int? estimatedRemainingSeconds,
    required String currentFilter,
    double? currentHfr,
    required String currentNodeName,
    required String jobState,
  }) async {
    _assertIos('update');
    await _channel.invokeMethod<void>('update', {
      'activityId': activityId,
      'framesCompleted': framesCompleted,
      'framesTotal': framesTotal,
      'elapsedSeconds': elapsedSeconds,
      'estimatedRemainingSeconds': estimatedRemainingSeconds,
      'currentFilter': currentFilter,
      'currentHfr': currentHfr,
      'currentNodeName': currentNodeName,
      'jobState': jobState,
    });
  }

  /// End the activity identified by [activityId].
  ///
  /// If [dismissDate] is provided, the lock-screen banner stays visible
  /// until that wall-clock time before being removed (Apple caps this at
  /// ~4 hours from now). The default is immediate dismissal so a completed
  /// sequence does not leave a stale banner.
  ///
  /// Optional terminal fields may be supplied so the final lock-screen
  /// frame shows the true outcome (e.g. `jobState: 'completed'`,
  /// `framesCompleted == framesTotal`).
  Future<void> end(
    String activityId, {
    DateTime? dismissDate,
    int? framesCompleted,
    int? framesTotal,
    int? elapsedSeconds,
    int? estimatedRemainingSeconds,
    String? currentFilter,
    double? currentHfr,
    String? currentNodeName,
    String? jobState,
  }) async {
    _assertIos('end');
    final args = <String, dynamic>{'activityId': activityId};
    if (dismissDate != null) {
      args['dismissDate'] = dismissDate.millisecondsSinceEpoch;
    }
    if (framesCompleted != null) args['framesCompleted'] = framesCompleted;
    if (framesTotal != null) args['framesTotal'] = framesTotal;
    if (elapsedSeconds != null) args['elapsedSeconds'] = elapsedSeconds;
    if (estimatedRemainingSeconds != null) {
      args['estimatedRemainingSeconds'] = estimatedRemainingSeconds;
    }
    if (currentFilter != null) args['currentFilter'] = currentFilter;
    if (currentHfr != null) args['currentHfr'] = currentHfr;
    if (currentNodeName != null) args['currentNodeName'] = currentNodeName;
    if (jobState != null) args['jobState'] = jobState;
    await _channel.invokeMethod<void>('end', args);
  }

  void _assertIos(String method) {
    if (!Platform.isIOS) {
      throw LiveActivityUnsupportedPlatformException(
        'LiveActivityService.$method called on '
        '${Platform.operatingSystem} — Live Activities are iOS-only.',
      );
    }
  }
}
