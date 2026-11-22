// The post-session integration-progress wiring.
//
// The native `ImagingEvent::IntegrationProgress` reaches the seam through the
// generated event codec (`wireEventFromTyped`), and the seam
// (`BridgePostSessionSeam.integrationProgress`) filters the event stream on
// its category and event type and reads its data keys. The progress events
// here are built from the typed event and encoded by that codec, so a renamed
// type or key on either side fails this test.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/src/backend/bridge_event_codec.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';
import 'package:skotiq_core/src/models/backend/backend_types.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

SkotiqEvent _progressEvent({
  required String phase,
  required double fraction,
  int? framesDone,
  int? framesTotal,
}) => wireEventFromTyped(
  bridge.SkotiqEvent(
    eventId: BigInt.one,
    timestamp: 0,
    severity: bridge.EventSeverity.info,
    category: bridge.EventCategory.imaging,
    payload: bridge.EventPayload.imaging(
      bridge.ImagingEvent.integrationProgress(
        phase: phase,
        fraction: fraction,
        framesDone: framesDone,
        framesTotal: framesTotal,
      ),
    ),
  ),
);

void main() {
  group('BridgePostSessionSeam.integrationProgress', () {
    test('yields (phase, fraction) for imaging IntegrationProgress events and '
        'drops everything else', () async {
      final backend = _MockBackend();
      final controller = StreamController<SkotiqEvent>();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);

      final seam = BridgePostSessionSeam(backend: backend);
      // Subscribe (via toList) BEFORE emitting and await the terminal future:
      // calling asFuture() AFTER close() races the already-delivered done event
      // and hangs. toList() resolves deterministically when the stream is done.
      final collected = seam.integrationProgress().toList();

      // A non-imaging event with the same eventType must be ignored.
      controller.add(
        const SkotiqEvent(
          timestamp: 0,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'IntegrationProgress',
          data: {'phase': 'calibrating', 'fraction': 0.0},
        ),
      );
      // An imaging event of a different type must be ignored.
      controller.add(
        const SkotiqEvent(
          timestamp: 0,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'ExposureProgress',
          data: {'progress': 0.5},
        ),
      );
      // The real progress events flow through, in order.
      controller.add(_progressEvent(phase: 'calibrating', fraction: 0.1));
      controller.add(
        _progressEvent(
          phase: 'integrating',
          fraction: 0.6,
          framesDone: 12,
          framesTotal: 20,
        ),
      );
      controller.add(_progressEvent(phase: 'preview', fraction: 1.0));

      await controller.close();

      expect(await collected, [
        (phase: 'calibrating', fraction: 0.1),
        (phase: 'integrating', fraction: 0.6),
        (phase: 'preview', fraction: 1.0),
      ]);
    });

    test('coerces an integer fraction and tolerates a missing phase', () async {
      final backend = _MockBackend();
      final controller = StreamController<SkotiqEvent>();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);

      final seam = BridgePostSessionSeam(backend: backend);
      final collected = seam.integrationProgress().toList();

      // `fraction` arriving as an int (num) must coerce to double; a missing
      // `phase` must fall back to '' rather than throwing.
      controller.add(
        const SkotiqEvent(
          timestamp: 0,
          severity: EventSeverity.info,
          category: EventCategory.imaging,
          eventType: 'IntegrationProgress',
          data: {'fraction': 1},
        ),
      );

      await controller.close();

      expect(await collected, [(phase: '', fraction: 1.0)]);
    });

    test('a backend-less seam yields an empty progress stream', () async {
      const seam = BridgePostSessionSeam();
      expect(await seam.integrationProgress().toList(), isEmpty);
    });
  });
}
