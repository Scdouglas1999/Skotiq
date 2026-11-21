import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/in_memory_database.dart';
import 'mirror_link.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a viewer that joins after 120 steps has the host graph and totals',
    () async {
      final host = mirrorHost();
      when(() => host.backend.guiderGetStatus()).thenAnswer(
        (_) async => const Phd2Status(
          state: 'Guiding',
          connected: true,
          stopReason: 'autofocus',
        ),
      );
      when(
        () => host.backend.guiderGetCalibration(),
      ).thenAnswer((_) async => const Phd2CalibrationData(isCalibrated: false));
      final guider = host.container.read(guiderStateProvider.notifier)
        ..setConnecting('native:builtin_guider:multi_star', 'Built-in')
        ..setConnected()
        ..setPixelScale(0.78);
      host.container.read(lockPositionProvider.notifier).applyHostPosition((
        x: 251.5,
        y: 130.25,
      ));
      const lost = '2026-11-21T03:15:00.000Z';
      host.container.read(starLostEventProvider.notifier).state =
          DateTime.parse(lost);
      host.container.read(guiderSettleTimeoutProvider.notifier).state = (
        at: DateTime.parse('2026-11-21T03:16:00.000Z'),
        error: 'star did not settle',
      );
      host.container
          .read(calibrationStateProvider.notifier)
          .applyHostState(
            const Phd2CalibrationData(isCalibrated: true, raRate: 1.5),
          );

      const steps = 120;
      final base = DateTime.utc(2026, 11, 21, 3).millisecondsSinceEpoch;
      final ra = <double>[];
      final dec = <double>[];
      for (var i = 1; i <= steps; i++) {
        final raPx = i * 0.05;
        const decPx = -0.2;
        ra.add(raPx);
        dec.add(decPx);
        host.events.add(
          SkotiqEvent(
            timestamp: base + i * 1000,
            severity: EventSeverity.info,
            category: EventCategory.guiding,
            eventType: 'GuideStep',
            data: {'RADistanceRaw': raPx, 'DECDistanceRaw': decPx},
          ),
        );
      }
      host.events.add(
        SkotiqEvent(
          timestamp: base + 121 * 1000,
          severity: EventSeverity.info,
          category: EventCategory.guiding,
          eventType: 'GuideStep',
          data: {'RADistanceRaw': 'lost', 'DECDistanceRaw': 0.4},
        ),
      );
      // The graph publish is coalesced; a viewer that connects after the burst
      // reads the store, not the events.
      await Future<void>.delayed(const Duration(milliseconds: 400));

      final events = StreamController<SkotiqEvent>.broadcast();
      addTearDown(events.close);
      final backend = MockLinkBackend();
      when(
        () => backend.connectionState,
      ).thenReturn(BackendConnectionState.connected);
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      when(
        () => backend.guiderGetCalibration(),
      ).thenAnswer((_) async => const Phd2CalibrationData(isCalibrated: false));
      when(() => backend.getHostRuntimeState()).thenAnswer(
        (_) async =>
            host.container.read(hostRuntimeStateStoreProvider).snapshot(),
      );
      final viewer = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) => _Fixed(ref, backend)),
        ],
      );
      addTearDown(viewer.dispose);
      await hydrateHostRuntimeState(viewer, backend);

      final shown = viewer.read(guideGraphProvider);
      expect(shown, hasLength(steps));
      expect(shown.last.time.millisecondsSinceEpoch, base + steps * 1000);
      expect(shown.map((p) => p.ra), ra);
      expect(shown.every((p) => p.ra != 0), isTrue);

      final expectedRa = _rms(ra.sublist(ra.length - 100));
      final expectedDec = _rms(dec.sublist(dec.length - 100));
      final expectedTotal = math.sqrt(
        expectedRa * expectedRa + expectedDec * expectedDec,
      );
      final stats = viewer.read(guideStatsProvider);
      expect(stats.frameCount, steps);
      expect(stats.rmsRa, closeTo(expectedRa, 1e-9));
      expect(stats.rmsDec, closeTo(expectedDec, 1e-9));
      expect(stats.rmsTotal, closeTo(expectedTotal, 1e-9));
      expect(
        viewer.read(guiderStateProvider).rmsTotal,
        closeTo(expectedTotal, 1e-9),
      );
      expect(viewer.read(guiderStateProvider).pixelScaleArcsecPerPixel, 0.78);
      expect(viewer.read(guidingStopReasonProvider), 'autofocus');
      expect(viewer.read(lockPositionProvider), (x: 251.5, y: 130.25));
      expect(
        viewer.read(guiderSettleTimeoutProvider)?.error,
        'star did not settle',
      );
      expect(viewer.read(calibrationStateProvider).isCalibrated, isTrue);
      expect(viewer.read(calibrationStateProvider).raRate, 1.5);
      expect(
        viewer.read(starLostEventProvider)?.millisecondsSinceEpoch,
        DateTime.parse(lost).millisecondsSinceEpoch,
      );
      verifyNever(() => backend.guiderGetCalibration());

      events.add(
        SkotiqEvent(
          timestamp: base + 122 * 1000,
          severity: EventSeverity.info,
          category: EventCategory.guiding,
          eventType: 'GuideStep',
          data: {'RADistanceRaw': 9.0, 'DECDistanceRaw': 9.0},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(viewer.read(guideGraphProvider), hasLength(steps));
      expect(guider.deviceId, 'native:builtin_guider:multi_star');
    },
  );
}

double _rms(List<double> values) {
  var sum = 0.0;
  for (final value in values) {
    sum += value * value;
  }
  return math.sqrt(sum / values.length);
}

class _Fixed extends BackendNotifier {
  _Fixed(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}
