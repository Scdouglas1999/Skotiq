// The post-session integration-progress wiring.
//
// The progress feature spans two contracts that must agree on the exact
// `eventType` token and `data` keys:
//
//   1. The FFI event mapper (`_extractImagingEventInfo` in
//      ffi_backend/event_mapping.dart) must turn a native
//      `ImagingEvent::IntegrationProgress` into a SkotiqEvent whose
//      `category == EventCategory.imaging`, `eventType == 'IntegrationProgress'`,
//      and whose `data` carries 'phase' and 'fraction'.
//   2. The production seam (`BridgePostSessionSeam.integrationProgress`) filters
//      the backend event stream on exactly that category + eventType and reads
//      exactly those data keys.
//
// The mapper half runs over native types and cannot be exercised without the
// Rust library, but it has only one job: emit the event shape this test feeds
// in. This test pins the consumer contract (category, eventType, data keys) so
// that if the mapper ever drifts back to 'UnknownImagingEvent' or renames a
// key, the seam side that depends on the spelling is caught here.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/src/backend/skotiq_backend.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';

class _MockBackend extends Mock implements SkotiqBackend {}

SkotiqEvent _progressEvent({
  required String phase,
  required double fraction,
  int? framesDone,
  int? framesTotal,
}) => SkotiqEvent(
  timestamp: 0,
  severity: EventSeverity.info,
  category: EventCategory.imaging,
  eventType: 'IntegrationProgress',
  data: {
    'phase': phase,
    'fraction': fraction,
    if (framesDone != null) 'frames_done': framesDone,
    if (framesTotal != null) 'frames_total': framesTotal,
  },
);

void main() {
  group('BridgePostSessionSeam.integrationProgress', () {
    test('yields (phase, fraction) for imaging IntegrationProgress events and '
        'drops everything else', () async {
      final backend = _MockBackend();
      final controller = StreamController<SkotiqEvent>();
      when(() => backend.eventStream).thenAnswer((_) => controller.stream);

      final seam = BridgePostSessionSeam(backend);
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

      final seam = BridgePostSessionSeam(backend);
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
