// The stage's exposure during a run follows the camera's own events: a run's
// frames never set `cameraStateProvider.isExposing` for longer than the
// moment between the executor's synthesized ExposureStarted and
// ExposureCompleted, which both arrive after the frame has finished.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/center/frame_stage.dart';
import 'package:skotiq_app/screens/night_control/data/session/camera_exposure_provider.dart';
import 'package:skotiq_core/skotiq_core.dart';

import 'session_test_support.dart';

class _TestClock implements Clock {
  _TestClock(this.instant);

  DateTime instant;

  @override
  DateTime now() => instant.toLocal();

  @override
  DateTime nowUtc() => instant;

  @override
  Duration get utcOffset => Duration.zero;

  @override
  DateTime fromUtc(DateTime utc) => utc.toLocal();
}

SkotiqEvent _imaging(String type, [Map<String, dynamic> data = const {}]) =>
    SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.imaging,
      eventType: type,
      data: data,
    );

SkotiqEvent _sequencer(String type, Map<String, dynamic> data) => SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.sequencer,
      eventType: type,
      data: data,
    );

void main() {
  final start = DateTime.utc(2026, 10, 21, 3, 40);

  Future<(SessionHarness, _TestClock)> harness() async {
    final clock = _TestClock(start);
    final h = await sessionHarness(
      overrides: <Override>[clockProvider.overrideWithValue(clock)],
    );
    final keep = h.container.listen(nightStageExposureProvider, (_, __) {});
    addTearDown(keep.close);
    return (h, clock);
  }

  Future<void> deliver(SessionHarness h, SkotiqEvent event) async {
    h.backend.emitEvent(event);
    await Future<void>.delayed(Duration.zero);
  }

  test('a run frame exposing reads its length and counts down', () async {
    final (h, clock) = await harness();
    await deliver(
      h,
      _imaging(
          'ExposureStarted', {'duration_secs': 90.0, 'frame_type': 'light'}),
    );

    // The camera card's flag is not what says so.
    expect(h.read(cameraStateProvider).isExposing, isFalse);
    final exposure = h.read(nightStageExposureProvider)!;
    expect(exposure.total, 90);
    clock.instant = start.add(const Duration(seconds: 53));
    expect(exposure.elapsedAt(clock.instant), 53);
    expect(exposure.fractionAt(clock.instant), closeTo(53 / 90, 1e-9));
  });

  test('the camera progress report re-anchors the countdown', () async {
    final (h, clock) = await harness();
    await deliver(h, _imaging('ExposureStarted', {'duration_secs': 90.0}));
    // The camera started later than this app heard: 30 s left at 58 s.
    clock.instant = start.add(const Duration(seconds: 58));
    await deliver(
      h,
      _imaging('ExposureProgress', {'progress': 0.67, 'remainingSecs': 30.0}),
    );
    final exposure = h.read(nightStageExposureProvider)!;
    expect(exposure.elapsedAt(clock.instant), closeTo(60, 1e-6));
  });

  test('the frame ending, failing or being cancelled clears it', () async {
    final (h, _) = await harness();
    for (final end in <String>[
      'ExposureComplete',
      'ExposureCancelled',
      'ExposureFailed',
      'DownloadStarted',
    ]) {
      await deliver(h, _imaging('ExposureStarted', {'duration_secs': 90.0}));
      expect(h.read(nightCameraExposureProvider), isNotNull);
      await deliver(h, _imaging(end));
      expect(h.read(nightCameraExposureProvider), isNull, reason: end);
      expect(h.read(nightStageExposureProvider), isNull, reason: end);
    }
  });

  test('the executor\'s after-the-fact pair is not an exposure', () async {
    final (h, _) = await harness();
    await deliver(
      h,
      _sequencer('ExposureStarted', {
        'frame': 3,
        'total': 8,
        'filter': 'L',
        'duration_secs': 90.0,
      }),
    );
    expect(h.read(nightCameraExposureProvider), isNull);
  });
}
