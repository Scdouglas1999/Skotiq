// End-to-end trace: typed `FrameRejected` / `FrameAccepted` payloads
// flow from the backend event stream into Tonight's run-grading state without
// any regex / string parsing: the running counts, the reject streak and the
// last reject (HFR, eccentricity, star count, reason) come straight off the
// typed event.
//
// Why a typed-payload test: routing the same data through
// `InstructionProgress.detail` strings and a regex parser silently drops
// HFR / ecc / star count fields whenever the format string does not match. This
// pins the typed contract, so a refactor that reintroduces string parsing fails
// loudly here.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/data/session/run_grading_provider.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../../harness/mock_backend.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Lightweight `BackendNotifier` subclass that pins the backend state to
/// our `MockBackend` instance so the grading notifier subscribes
/// to the same `eventStream` we drive via `MockBackend.emitEvent`.
class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }

  void swapTo(SkotiqBackend backend) => state = backend;
}

/// Build a typed `FrameRejected` `SkotiqEvent` matching what
/// `FfiBackend._extractSequencerEventInfo` emits when the Rust bridge
/// publishes a `SequencerEvent::FrameRejected` payload. Pinning the exact
/// `data` map shape here is the contract.
SkotiqEvent _typedFrameRejected({
  required int frame,
  required int total,
  required String reason,
  double? hfr,
  double? eccentricity,
  int? starCount,
  String rejectPath = '/save/Reject/M42_001.fits',
  required int consecutiveRejects,
  required int acceptedTotal,
  required int rejectedTotal,
  String nodeId = 'exposure-1',
}) {
  return SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.info,
    category: EventCategory.sequencer,
    eventType: 'FrameRejected',
    data: {
      'node_id': nodeId,
      'frame': frame,
      'total': total,
      'reason': reason,
      'hfr': hfr,
      'eccentricity': eccentricity,
      'star_count': starCount,
      'reject_path': rejectPath,
      'consecutive_rejects': consecutiveRejects,
      'accepted_total': acceptedTotal,
      'rejected_total': rejectedTotal,
      // The capture record every frame event carries.
      'exposure_secs': 60.0,
      'bin_x': 1,
      'bin_y': 1,
      'frame_type': 'Light',
    },
  );
}

SkotiqEvent _typedFrameAccepted({
  required int frame,
  required int total,
  double? hfr,
  double? eccentricity,
  int? starCount,
  required int acceptedTotal,
  required int rejectedTotal,
  String nodeId = 'exposure-1',
}) {
  return SkotiqEvent(
    timestamp: DateTime.now().millisecondsSinceEpoch,
    severity: EventSeverity.info,
    category: EventCategory.sequencer,
    eventType: 'FrameAccepted',
    data: {
      'node_id': nodeId,
      'frame': frame,
      'total': total,
      'hfr': hfr,
      'eccentricity': eccentricity,
      'star_count': starCount,
      'accepted_total': acceptedTotal,
      'rejected_total': rejectedTotal,
      // The capture record every frame event carries.
      'exposure_secs': 60.0,
      'bin_x': 1,
      'bin_y': 1,
      'frame_type': 'Light',
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runGradingProvider (typed payloads)', () {
    test(
      'typed FrameRejected updates the counts, the streak and the last reject '
      'without parsing detail strings',
      () async {
        final backend = mockBackend();
        final container = ProviderContainer(overrides: [
          inMemoryDatabaseOverride(),
          backendProvider
              .overrideWith((ref) => _TestBackendNotifier(ref, backend)),
        ]);
        addTearDown(container.dispose);

        // Wire the notifier up so it subscribes to the backend stream.
        // Reading the provider is enough; the notifier constructor calls
        // `_wireBackendEvents()` synchronously.
        final initial = container.read(runGradingProvider);
        expect(initial.total, 0,
            reason: 'starts empty before any event arrives');

        // Push a typed FrameRejected event. The notifier must read
        // HFR / eccentricity / reason DIRECTLY off `data`, not parse a
        // detail string. We omit the legacy `detail` key entirely to
        // prove the typed path is wired.
        backend.emitEvent(_typedFrameRejected(
          frame: 3,
          total: 10,
          reason: 'HFR 5.21 > threshold 3.50',
          hfr: 5.21,
          eccentricity: 0.62,
          starCount: 18,
          consecutiveRejects: 1,
          acceptedTotal: 2,
          rejectedTotal: 1,
        ));

        // The notifier's `_onEvent` is sync but the broadcast stream is
        // async. Drain the microtask queue.
        await Future<void>.delayed(Duration.zero);

        final after = container.read(runGradingProvider);
        expect(after.accepted, 2);
        expect(after.rejected, 1);
        expect(after.total, 3);
        expect(after.consecutiveRejects, 1);

        final r = after.lastReject!;
        expect(r.frame, 3);
        expect(r.total, 10);
        expect(r.decision, FrameGradeDecision.rejected);
        expect(r.reason, 'HFR 5.21 > threshold 3.50');
        expect(r.hfr, 5.21,
            reason:
                'HFR plumbed end-to-end via typed payload (was lost to regex parse pre-Pack-H)');
        expect(r.eccentricity, 0.62);
        expect(r.starCount, 18);
        expect(r.consecutiveRejects, 1);
        expect(r.path, '/save/Reject/M42_001.fits');
      },
    );

    test(
      'an accepted frame ends the reject streak and keeps the last reject',
      () async {
        final backend = mockBackend();
        final container = ProviderContainer(overrides: [
          inMemoryDatabaseOverride(),
          backendProvider
              .overrideWith((ref) => _TestBackendNotifier(ref, backend)),
        ]);
        addTearDown(container.dispose);

        container.read(runGradingProvider);

        backend.emitEvent(_typedFrameRejected(
          frame: 1,
          total: 10,
          reason: 'star count 12 below threshold 30',
          consecutiveRejects: 1,
          acceptedTotal: 0,
          rejectedTotal: 1,
        ));
        backend.emitEvent(_typedFrameRejected(
          frame: 2,
          total: 10,
          reason: 'star count 9 below threshold 30',
          consecutiveRejects: 2,
          acceptedTotal: 0,
          rejectedTotal: 2,
        ));
        await Future<void>.delayed(Duration.zero);
        var summary = container.read(runGradingProvider);
        expect(summary.consecutiveRejects, 2);
        expect(summary.lastReject?.frame, 2);

        backend.emitEvent(_typedFrameAccepted(
          frame: 3,
          total: 10,
          hfr: 2.45,
          acceptedTotal: 1,
          rejectedTotal: 2,
        ));
        await Future<void>.delayed(Duration.zero);

        summary = container.read(runGradingProvider);
        expect(summary.accepted, 1);
        expect(summary.rejected, 2);
        expect(summary.consecutiveRejects, 0);
        expect(summary.lastReject?.reason, 'star count 9 below threshold 30');
      },
    );

    test(
      "an InstructionProgress legacy event with the old 'frame N/M REJECTED' "
      'detail string is IGNORED — the regex pipeline is deleted',
      () async {
        final backend = mockBackend();
        final container = ProviderContainer(overrides: [
          inMemoryDatabaseOverride(),
          backendProvider
              .overrideWith((ref) => _TestBackendNotifier(ref, backend)),
        ]);
        addTearDown(container.dispose);

        container.read(runGradingProvider);

        // Push a legacy-shaped event. The typed pipeline deliberately drops it,
        // so the counts can NEVER silently fall back to the lossy regex path.
        backend.emitEvent(SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'InstructionProgress',
          data: {
            'node_id': 'exposure-1',
            'instruction': 'Exposure',
            'progress_percent': 100.0,
            'detail':
                'frame 4/10 REJECTED (3× consecutive): HFR 5.10 > 3.50 (path: /Reject/foo.fits)',
          },
        ));
        await Future<void>.delayed(Duration.zero);

        final after = container.read(runGradingProvider);
        expect(after.total, 0,
            reason:
                'legacy detail strings no longer drive the counts — typed events only');
        expect(after.lastReject, isNull);
      },
    );

    test(
      'Started event resets the per-run counters',
      () async {
        final backend = mockBackend();
        final container = ProviderContainer(overrides: [
          inMemoryDatabaseOverride(),
          backendProvider
              .overrideWith((ref) => _TestBackendNotifier(ref, backend)),
        ]);
        addTearDown(container.dispose);

        container.read(runGradingProvider);

        backend.emitEvent(_typedFrameRejected(
          frame: 1,
          total: 5,
          reason: 'star count 12 below threshold 30',
          hfr: 4.10,
          starCount: 12,
          consecutiveRejects: 1,
          acceptedTotal: 0,
          rejectedTotal: 1,
        ));
        await Future<void>.delayed(Duration.zero);
        expect(
          container.read(runGradingProvider).total,
          1,
        );

        // A new sequence starts.
        backend.emitEvent(SkotiqEvent(
          timestamp: DateTime.now().millisecondsSinceEpoch,
          severity: EventSeverity.info,
          category: EventCategory.sequencer,
          eventType: 'Started',
          data: const {'sequence_name': 'Test'},
        ));
        await Future<void>.delayed(Duration.zero);

        final reset = container.read(runGradingProvider);
        expect(reset.total, 0);
        expect(reset.consecutiveRejects, 0);
        expect(reset.lastReject, isNull);
      },
    );

    test('backend switch clears old-host quality and ignores late events',
        () async {
      final oldBackend = mockBackend();
      final newBackend = mockBackend();
      final container = ProviderContainer(overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _TestBackendNotifier(ref, oldBackend),
        ),
      ]);
      addTearDown(container.dispose);
      container.read(runGradingProvider);

      oldBackend.emitEvent(_typedFrameAccepted(
        frame: 1,
        total: 10,
        hfr: 2.4,
        acceptedTotal: 1,
        rejectedTotal: 0,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(runGradingProvider).total, 1);

      (container.read(backendProvider.notifier) as _TestBackendNotifier)
          .swapTo(newBackend);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(runGradingProvider).total, 0);

      oldBackend.emitEvent(_typedFrameRejected(
        frame: 2,
        total: 10,
        reason: 'late old-host frame',
        consecutiveRejects: 1,
        acceptedTotal: 1,
        rejectedTotal: 1,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(runGradingProvider).total, 0);

      newBackend.emitEvent(_typedFrameAccepted(
        frame: 1,
        total: 5,
        hfr: 1.9,
        acceptedTotal: 1,
        rejectedTotal: 0,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(runGradingProvider).total, 1);
    });
  });

  group('FrameGradeEvent.fromEvent', () {
    const capture = FrameCaptureMetadata(
      gainIsIso: false,
      exposureSecs: 120,
      binX: 1,
      binY: 1,
      frameType: 'Light',
    );

    test('reads an accepted frame with every field', () {
      final grade = FrameGradeEvent.fromEvent(
        const SequencerEvent.frameAccepted(
          nodeId: 'n',
          frame: 5,
          total: 20,
          hfr: 2.31,
          eccentricity: 0.18,
          starCount: 187,
          acceptedTotal: 5,
          rejectedTotal: 0,
          capture: capture,
        ),
      );
      expect(grade, isNotNull);
      expect(grade!.decision, FrameGradeDecision.accepted);
      expect(grade.frame, 5);
      expect(grade.total, 20);
      expect(grade.hfr, 2.31);
      expect(grade.eccentricity, 0.18);
      expect(grade.starCount, 187);
      expect(grade.acceptedTotal, 5);
      expect(grade.rejectedTotal, 0);
      expect(grade.consecutiveRejects, 0);
      expect(grade.reason, isEmpty);
      expect(grade.path, isNull);
    });

    test('reads a rejected frame with every field', () {
      final grade = FrameGradeEvent.fromEvent(
        const SequencerEvent.frameRejected(
          nodeId: 'n',
          frame: 7,
          total: 20,
          reason: 'eccentricity 0.81 > 0.65',
          hfr: 3.10,
          eccentricity: 0.81,
          starCount: 92,
          rejectPath: '/Reject/M101_007.fits',
          consecutiveRejects: 2,
          acceptedTotal: 4,
          rejectedTotal: 3,
          evidence: [],
          capture: capture,
        ),
      );
      expect(grade, isNotNull);
      expect(grade!.decision, FrameGradeDecision.rejected);
      expect(grade.frame, 7);
      expect(grade.reason, 'eccentricity 0.81 > 0.65');
      expect(grade.hfr, 3.10);
      expect(grade.eccentricity, 0.81);
      expect(grade.starCount, 92);
      expect(grade.path, '/Reject/M101_007.fits');
      expect(grade.consecutiveRejects, 2);
      expect(grade.acceptedTotal, 4);
      expect(grade.rejectedTotal, 3);
    });

    test('is null for any other event', () {
      expect(
        FrameGradeEvent.fromEvent(
          const SequencerEvent.nodeStarted(nodeId: 'n', nodeType: 'Exposure'),
        ),
        isNull,
      );
    });
  });
}
