import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/services.dart';

/// Thrown when the caller invokes the watch-complication service on a
/// platform that does not (and cannot) support it.
///
/// Thrown rather than no-op so a caller reaching this service from desktop or
/// Android code fails visibly instead of silently believing the complication
/// was updated.
class WatchComplicationUnsupportedPlatformException implements Exception {
  WatchComplicationUnsupportedPlatformException(this.message);

  final String message;

  @override
  String toString() =>
      'WatchComplicationUnsupportedPlatformException: $message';
}

/// Immutable snapshot pushed from the host into the Apple Watch
/// complication's App Group container.
///
/// Field names MUST stay in lockstep with the Swift `SnapshotPayload`
/// inside `SkotiqWatchTimelineProvider.swift` — the JSON keys are
/// the schema between the two layers.
class WatchComplicationSnapshot {
  WatchComplicationSnapshot({
    required this.targetName,
    required this.framesCompleted,
    required this.framesTotal,
    required this.currentFilter,
    required this.jobState,
    required this.weatherSafe,
    required this.weatherLabel,
  });

  /// Display name for the active target / sequence. Empty string when the
  /// host has nothing to show (idle rig). The widget treats empty as
  /// "fall back to brand name".
  final String targetName;

  /// Frames completed and accepted on the current run.
  final int framesCompleted;

  /// Total frames planned. Zero is interpreted as "unknown" by the
  /// complication views.
  final int framesTotal;

  /// Currently active filter name. Empty when no filter wheel / no filter
  /// node is active.
  final String currentFilter;

  /// Coarse rig state. Same vocabulary as the iOS Live Activity widget —
  /// `exposing` / `guiding` / `focusing` / `centering` / `recovering` /
  /// `idle` / `paused` / `stopping` / `completed` / `failed`.
  final String jobState;

  /// True when the weather-safety subsystem says it is safe to image.
  final bool weatherSafe;

  /// Human-readable shorthand for the weather alert level — "Clear",
  /// "Watch", "Warning", "Critical". Empty when no sample is available.
  final String weatherLabel;

  Map<String, Object?> toJson() => <String, Object?>{
    'targetName': targetName,
    'framesCompleted': framesCompleted,
    'framesTotal': framesTotal,
    'currentFilter': currentFilter,
    'jobState': jobState,
    'weatherSafe': weatherSafe,
    'weatherLabel': weatherLabel,
  };

  String encode() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WatchComplicationSnapshot &&
        other.targetName == targetName &&
        other.framesCompleted == framesCompleted &&
        other.framesTotal == framesTotal &&
        other.currentFilter == currentFilter &&
        other.jobState == jobState &&
        other.weatherSafe == weatherSafe &&
        other.weatherLabel == weatherLabel;
  }

  @override
  int get hashCode => Object.hash(
    targetName,
    framesCompleted,
    framesTotal,
    currentFilter,
    jobState,
    weatherSafe,
    weatherLabel,
  );
}

/// Host-side bridge for the Apple Watch complication declared in
/// `apps/mobile/ios/SkotiqWatchComplication/`.
///
/// Lifecycle:
///   * [publish] writes the snapshot JSON into the App Group `UserDefaults`
///     suite (`group.com.skotiq.app`) under
///     `watch_complication_snapshot` and triggers
///     `WidgetCenter.shared.reloadAllTimelines()` so WidgetKit re-renders
///     the complication immediately. The watch complication's
///     `TimelineProvider` reads the same key when WidgetKit invokes
///     `getTimeline(...)`.
///
/// MethodChannel: `skotiq/watch_complication`. The single method
/// `publishSnapshot` takes the full JSON payload as a string argument
/// (we send a pre-encoded string rather than a `Map` so the host can
/// write it into `UserDefaults` verbatim — that way the same UTF-8
/// bytes Swift decodes are the ones Dart emitted).
///
/// This service is iOS-only. Every method throws
/// [WatchComplicationUnsupportedPlatformException] on non-iOS platforms.
class WatchComplicationService {
  WatchComplicationService({MethodChannel? channel, bool? platformIsIos})
    : _channel = channel ?? const MethodChannel(_channelName),
      _platformIsIos = platformIsIos ?? Platform.isIOS;

  /// Public for tests.
  static const String channelName = _channelName;
  static const String _channelName = 'skotiq/watch_complication';

  /// MethodChannel method name. Public so tests can match against the
  /// same string the host expects.
  static const String publishMethod = 'publishSnapshot';

  final MethodChannel _channel;

  /// Captured at construction so tests can simulate iOS without touching
  /// the global `Platform.isIOS`.
  final bool _platformIsIos;

  /// True iff the host platform can drive the complication. On non-iOS
  /// platforms returns false synchronously; on iOS we forward to the
  /// host bridge which can additionally refuse if WidgetKit is unhappy
  /// (no widget extension installed, etc.).
  Future<bool> isSupported() async {
    if (!_platformIsIos) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('isSupported');
      return result ?? false;
    } on PlatformException catch (e, st) {
      developer.log(
        '[WatchComplicationService] isSupported failed: ${e.message}',
        name: 'WatchComplicationService',
        level: 1000,
        error: e,
        stackTrace: st,
      );
      return false;
    }
  }

  /// Publish a full snapshot and trigger a complication reload.
  ///
  /// Throws a [PlatformException] from the host bridge if writing to
  /// `UserDefaults` or invoking `WidgetCenter` fails. We do not catch
  /// here — callers (typically the lifecycle provider) decide whether
  /// the failure is recoverable.
  Future<void> publish(WatchComplicationSnapshot snapshot) async {
    _assertIos('publish');
    await _channel.invokeMethod<void>(publishMethod, <String, Object?>{
      'snapshotJson': snapshot.encode(),
    });
  }

  void _assertIos(String method) {
    if (!_platformIsIos) {
      throw WatchComplicationUnsupportedPlatformException(
        'WatchComplicationService.$method called on '
        '${Platform.operatingSystem} — the Apple Watch complication is iOS-only.',
      );
    }
  }
}
