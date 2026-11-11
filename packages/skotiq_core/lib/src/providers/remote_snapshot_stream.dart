import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';

/// Quiet period after a relevant host event before a re-fetch, so a burst of
/// related events costs one request.
const Duration remoteSnapshotRefetchDebounce = Duration(milliseconds: 750);

/// Per-tick host telemetry: these events arrive many times a second while
/// guiding or exposing and never change a stored list on the host.
const Set<String> hostTelemetryEventTypes = {
  'ExposureProgress',
  'GuideStep',
  'GuideStats',
  'MountPositionChanged',
  'CameraTemperatureChanged',
  'TemperatureChanged',
  'FocuserPositionChanged',
  'FilterWheelPositionChanged',
  'InstructionProgress',
  'InstructionProgressStructured',
  'AutofocusProgress',
  'IntegrationProgress',
  'Progress',
  'ProgressUpdated',
  'Heartbeat',
  'HeartbeatOk',
};

/// A REST snapshot of a host-owned list, kept current on a companion.
///
/// Fetches once, then again after a host event [shouldRefetch] accepts. At
/// most one request is outstanding; events that arrive meanwhile coalesce into
/// one follow-up fetch, and fetches start at least [minInterval] apart. A
/// failed re-fetch keeps the last good snapshot; a failed first fetch is
/// surfaced so the view can show its error and Retry state. The stream and its
/// event subscription end when [ref] is disposed.
Stream<List<T>> remoteSnapshotStream<T>({
  required Ref ref,
  required SkotiqBackend backend,
  required Future<List<Map<String, dynamic>>> Function() fetch,
  required T Function(Map<String, dynamic>) decode,
  required bool Function(SkotiqEvent event) shouldRefetch,
  required Duration minInterval,
  void Function(Object error)? onRefetchError,
}) {
  final controller = StreamController<List<T>>();
  Timer? debounce;
  Timer? cooldown;
  var inFlight = false;
  var pending = false;
  var emittedOnce = false;

  Future<void> refetch() async {
    try {
      final rows = (await fetch()).map(decode).toList(growable: false);
      if (!controller.isClosed) {
        controller.add(rows);
        emittedOnce = true;
      }
    } catch (e) {
      if (!emittedOnce) {
        if (!controller.isClosed) controller.addError(e);
        return;
      }
      onRefetchError?.call(e);
    }
  }

  late void Function() maybeStart;

  Future<void> run() async {
    if (controller.isClosed) return;
    pending = false;
    inFlight = true;
    cooldown = Timer(minInterval, () {
      cooldown = null;
      if (pending) maybeStart();
    });
    try {
      await refetch();
    } finally {
      inFlight = false;
    }
    if (pending) maybeStart();
  }

  maybeStart = () {
    if (controller.isClosed || inFlight) return;
    if (cooldown != null || debounce != null) return;
    debounce = Timer(remoteSnapshotRefetchDebounce, () {
      debounce = null;
      if (!inFlight && cooldown == null) unawaited(run());
    });
  };

  StreamSubscription<SkotiqEvent>? sub;
  ref.onDispose(() {
    debounce?.cancel();
    cooldown?.cancel();
    unawaited(sub?.cancel());
    unawaited(controller.close());
  });
  unawaited(run());
  sub = backend.eventStream.listen((event) {
    if (!shouldRefetch(event)) return;
    pending = true;
    maybeStart();
  });
  return controller.stream;
}
