// A guide step carries only the correction; the star's SNR and mass come in
// the GuideStats event both guiders send with every step. The shown values
// stay the last measured ones across the step, over both transports.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/utils.dart';

import '../harness/event_wire.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  for (final path in EventPath.values) {
    test('a guide step keeps the measured SNR and star mass ($path)', () async {
      final events = StreamController<SkotiqEvent>.broadcast();
      addTearDown(events.close);
      final backend = _MockNetworkBackend();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          loggingServiceProvider.overrideWithValue(LoggingService()),
        ],
      );
      addTearDown(container.dispose);
      container.read(guideStatsProvider);

      // The order both guiders publish a guided frame in.
      for (var frame = 0; frame < 3; frame++) {
        events
          ..add(
            wireEventOver(
              path,
              const bridge.EventPayload.guiding(
                bridge.GuidingEvent.guideStats(snr: 18.5, starMass: 4200),
              ),
            ),
          )
          ..add(
            wireEventOver(
              path,
              bridge.EventPayload.guiding(
                bridge.GuidingEvent.correction(
                  ra: 0.3 * (frame + 1),
                  dec: -0.2,
                  raRaw: 0.3 * (frame + 1),
                  decRaw: -0.2,
                ),
              ),
            ),
          );
        await Future<void>.delayed(Duration.zero);
        final stats = container.read(guideStatsProvider);
        expect(stats.frameCount, frame + 1);
        expect(stats.snr, 18.5, reason: 'frame ${frame + 1}');
        expect(stats.starMass, 4200, reason: 'frame ${frame + 1}');
      }
    });
  }
}
