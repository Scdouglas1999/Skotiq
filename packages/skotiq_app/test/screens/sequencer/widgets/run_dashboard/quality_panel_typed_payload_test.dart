// End-to-end trace: typed `FrameRejected` / `FrameAccepted` payloads
// flow from the backend event stream into the run-dashboard quality panel's
// state notifier without any regex / string parsing. The panel surfaces
// the running counts, HFR, eccentricity, star count, reject reason, and
// consecutive-reject counter straight off the typed event.
//
// Why a typed-payload test: routing the same data through
// `InstructionProgress.detail` strings and a regex parser silently drops
// HFR / ecc / star count fields whenever the format string does not match. This
// pins the typed contract, so a refactor that reintroduces string parsing fails
// loudly here.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/run_dashboard/quality_panel.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../../harness/mock_backend.dart';
import '../../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

/// Lightweight `BackendNotifier` subclass that pins the backend state to
/// our `MockBackend` instance so the panel's `_QualityNotifier` subscribes
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
    },
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('runDashboardQualitySummaryProvider (typed payloads)', () {
    test(
      'typed FrameRejected updates accepted/rejected/recent/HFR fields '
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
        final initial = container.read(runDashboardQualitySummaryProvider);
        expect(initial.total, 0,
            reason: 'panel starts empty before any event arrives');

        // Push a typed FrameRejected event. The panel must read
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

        final after = container.read(runDashboardQualitySummaryProvider);
        expect(after.accepted, 2);
        expect(after.rejected, 1);
        expect(after.total, 3);
        expect(after.rejectRate, closeTo(1 / 3, 1e-9));
        expect(after.recent, hasLength(1));

        final r = after.recent.single;
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
      'typed FrameAccepted feeds the HFR sparkline',
      () async {
        final backend = mockBackend();
        final container = ProviderContainer(overrides: [
          inMemoryDatabaseOverride(),
          backendProvider
              .overrideWith((ref) => _TestBackendNotifier(ref, backend)),
        ]);
        addTearDown(container.dispose);

        container.read(runDashboardQualitySummaryProvider);

        // Three accepted frames — the typed payload includes HFR, so the
        // sparkline should grow.
        backend.emitEvent(_typedFrameAccepted(
          frame: 1,
          total: 10,
          hfr: 2.40,
          starCount: 142,
          acceptedTotal: 1,
          rejectedTotal: 0,
        ));
        backend.emitEvent(_typedFrameAccepted(
          frame: 2,
          total: 10,
          hfr: 2.51,
          starCount: 138,
          acceptedTotal: 2,
          rejectedTotal: 0,
        ));
        backend.emitEvent(_typedFrameAccepted(
          frame: 3,
          total: 10,
          hfr: 2.45,
          starCount: 141,
          acceptedTotal: 3,
          rejectedTotal: 0,
        ));
        await Future<void>.delayed(Duration.zero);

        final after = container.read(runDashboardQualitySummaryProvider);
        expect(after.accepted, 3);
        expect(after.rejected, 0);
        expect(after.hfrSparkline, [2.40, 2.51, 2.45],
            reason:
                'sparkline now populates from the typed HFR field; was empty pre-Pack-H');
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

        container.read(runDashboardQualitySummaryProvider);

        // Push a legacy-shaped event. The typed pipeline deliberately drops it,
        // so the panel can NEVER silently fall back to the lossy regex path.
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

        final after = container.read(runDashboardQualitySummaryProvider);
        expect(after.total, 0,
            reason:
                'legacy detail strings no longer drive the panel — typed events only');
        expect(after.recent, isEmpty);
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

        container.read(runDashboardQualitySummaryProvider);

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
          container.read(runDashboardQualitySummaryProvider).total,
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

        final reset = container.read(runDashboardQualitySummaryProvider);
        expect(reset.total, 0);
        expect(reset.recent, isEmpty);
        expect(reset.hfrSparkline, isEmpty);
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
      container.read(runDashboardQualitySummaryProvider);

      oldBackend.emitEvent(_typedFrameAccepted(
        frame: 1,
        total: 10,
        hfr: 2.4,
        acceptedTotal: 1,
        rejectedTotal: 0,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(runDashboardQualitySummaryProvider).total, 1);

      (container.read(backendProvider.notifier) as _TestBackendNotifier)
          .swapTo(newBackend);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(runDashboardQualitySummaryProvider).total, 0);

      oldBackend.emitEvent(_typedFrameRejected(
        frame: 2,
        total: 10,
        reason: 'late old-host frame',
        consecutiveRejects: 1,
        acceptedTotal: 1,
        rejectedTotal: 1,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(runDashboardQualitySummaryProvider).total, 0);

      newBackend.emitEvent(_typedFrameAccepted(
        frame: 1,
        total: 5,
        hfr: 1.9,
        acceptedTotal: 1,
        rejectedTotal: 0,
      ));
      await Future<void>.delayed(Duration.zero);
      expect(container.read(runDashboardQualitySummaryProvider).total, 1);
    });
  });

  group('FrameGradeEvent.fromTypedData (typed contract)', () {
    test('round-trips an Accepted payload with every field', () {
      final grade = FrameGradeEvent.fromTypedData('FrameAccepted', {
        'frame': 5,
        'total': 20,
        'hfr': 2.31,
        'eccentricity': 0.18,
        'star_count': 187,
        'accepted_total': 5,
        'rejected_total': 0,
      });
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

    test('round-trips a Rejected payload with every field', () {
      final grade = FrameGradeEvent.fromTypedData('FrameRejected', {
        'frame': 7,
        'total': 20,
        'reason': 'eccentricity 0.81 > 0.65',
        'hfr': 3.10,
        'eccentricity': 0.81,
        'star_count': 92,
        'reject_path': '/Reject/M101_007.fits',
        'consecutive_rejects': 2,
        'accepted_total': 4,
        'rejected_total': 3,
      });
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

    test('returns null for unrelated event types', () {
      expect(
        FrameGradeEvent.fromTypedData(
            'InstructionProgress', const {'detail': 'foo'}),
        isNull,
      );
      expect(
        FrameGradeEvent.fromTypedData('NodeStarted', const {}),
        isNull,
      );
    });
  });
}
