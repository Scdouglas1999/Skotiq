import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

/// Fake disk service: returns canned [DiskSpaceInfo] (or throws). Test-only —
/// production code uses [DiskSpaceService].
class _FakeDiskSpaceService implements DiskSpaceService {
  DiskSpaceInfo? _next;
  Object? _error;

  void set(DiskSpaceInfo info) {
    _next = info;
    _error = null;
  }

  void setError(Object e) {
    _error = e;
    _next = null;
  }

  @override
  Future<DiskSpaceInfo> query(String path) async {
    if (_error != null) throw _error!;
    if (_next == null) {
      throw const DiskSpaceException('', 'no canned response configured');
    }
    return _next!;
  }
}

class _PendingDiskSpaceService implements DiskSpaceService {
  final List<String> paths = <String>[];
  final List<Completer<DiskSpaceInfo>> requests = <Completer<DiskSpaceInfo>>[];
  int inFlight = 0;
  int maxInFlight = 0;

  @override
  Future<DiskSpaceInfo> query(String path) async {
    paths.add(path);
    final request = Completer<DiskSpaceInfo>();
    requests.add(request);
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      return await request.future;
    } finally {
      inFlight--;
    }
  }
}

int _gb(int n) => n * 1024 * 1024 * 1024;

// 6000x4000 16-bit mono => 48 MB + 64 KB header ≈ 50.4 MB per frame.
const _cap6kMono16 = CameraCapabilities(
  maxWidth: 6000,
  maxHeight: 4000,
  bitDepth: 16,
);

Sequence _seqWithExposures(int count, {BinningMode binning = BinningMode.one}) {
  const exposureId = 'exp1';
  final exposure = ExposureNode(
    id: exposureId,
    durationSecs: 60,
    count: count,
    binning: binning,
  );
  return Sequence.create(
    id: 'seq1',
    name: 'test',
    nodes: {exposureId: exposure},
    rootNodeId: exposureId,
  );
}

void main() {
  group('DiskSpaceGuardService.projectFrameBytes', () {
    test('returns null when capabilities are null', () {
      final exposure = ExposureNode(id: 'e', count: 1);
      expect(DiskSpaceGuardService.projectFrameBytes(exposure, null), isNull);
    });

    test('computes mono 16-bit frame size at bin 1x1', () {
      final exposure = ExposureNode(id: 'e', count: 1);
      final bytes = DiskSpaceGuardService.projectFrameBytes(
        exposure,
        _cap6kMono16,
      );
      // 6000 * 4000 * 2 + 65536 header
      expect(bytes, 6000 * 4000 * 2 + 65536);
    });

    test('halves dimensions per axis under 2x2 binning', () {
      final exposure = ExposureNode(
        id: 'e',
        count: 1,
        binning: BinningMode.two,
      );
      final bytes = DiskSpaceGuardService.projectFrameBytes(
        exposure,
        _cap6kMono16,
      );
      // 3000 * 2000 * 2 + 65536
      expect(bytes, 3000 * 2000 * 2 + 65536);
    });
  });

  group('DiskSpaceGuardService.projectSequence', () {
    late _FakeDiskSpaceService fake;
    late DiskSpaceGuardService guard;

    setUp(() {
      fake = _FakeDiskSpaceService();
      guard = DiskSpaceGuardService(diskService: fake);
    });

    tearDown(() => guard.dispose());

    test('info severity when projected < 60% of free space', () async {
      fake.set(
        DiskSpaceInfo(
          path: 'C:/',
          totalBytes: _gb(500),
          freeBytes: _gb(100),
          sampledAt: DateTime.now(),
        ),
      );
      // 100 frames * ~50 MB ≈ 5 GB << 60% of 100 GB free
      final projection = await guard.projectSequence(
        capturePath: 'C:/data',
        sequence: _seqWithExposures(100),
        capabilities: _cap6kMono16,
      );
      expect(projection.severity, DiskSpaceSeverity.info);
      expect(projection.projectedBytes, lessThan(_gb(6)));
      expect(projection.freeBytes, _gb(100));
    });

    test('warning severity when projected > 60% of free space', () async {
      // Make the disk small enough that the run consumes >60% of free.
      // 1500 frames * ~50 MB ≈ 75 GB out of 100 GB free => 75% > 60%.
      fake.set(
        DiskSpaceInfo(
          path: 'C:/',
          totalBytes: _gb(500),
          freeBytes: _gb(100),
          sampledAt: DateTime.now(),
        ),
      );
      final projection = await guard.projectSequence(
        capturePath: 'C:/data',
        sequence: _seqWithExposures(1500),
        capabilities: _cap6kMono16,
      );
      expect(projection.severity, DiskSpaceSeverity.warning);
    });

    test('blocking severity when run would breach 2 GB safety margin', () async {
      // 2500 frames * ~50 MB = 125 GB, but only 100 GB free => after-run goes negative.
      fake.set(
        DiskSpaceInfo(
          path: 'C:/',
          totalBytes: _gb(500),
          freeBytes: _gb(100),
          sampledAt: DateTime.now(),
        ),
      );
      final projection = await guard.projectSequence(
        capturePath: 'C:/data',
        sequence: _seqWithExposures(2500),
        capabilities: _cap6kMono16,
      );
      expect(projection.severity, DiskSpaceSeverity.blocking);
    });

    test(
      'info severity (size unknown) when camera capabilities missing',
      () async {
        fake.set(
          DiskSpaceInfo(
            path: 'C:/',
            totalBytes: _gb(500),
            freeBytes: _gb(100),
            sampledAt: DateTime.now(),
          ),
        );
        final projection = await guard.projectSequence(
          capturePath: 'C:/data',
          sequence: _seqWithExposures(100),
          capabilities: null,
        );
        expect(projection.severity, DiskSpaceSeverity.info);
        expect(projection.projectedBytes, 0);
        expect(projection.headline, contains('projected size unknown'));
      },
    );

    test('disabled exposure nodes are excluded from projection', () async {
      fake.set(
        DiskSpaceInfo(
          path: 'C:/',
          totalBytes: _gb(500),
          freeBytes: _gb(100),
          sampledAt: DateTime.now(),
        ),
      );
      final exposureEnabled = ExposureNode(id: 'e1', count: 50);
      final exposureDisabled = ExposureNode(
        id: 'e2',
        count: 9999,
        isEnabled: false,
      );
      final sequence = Sequence.create(
        id: 'seq',
        name: 't',
        nodes: {
          exposureEnabled.id: exposureEnabled,
          exposureDisabled.id: exposureDisabled,
        },
        rootNodeId: exposureEnabled.id,
      );
      final projection = await guard.projectSequence(
        capturePath: 'C:/data',
        sequence: sequence,
        capabilities: _cap6kMono16,
      );
      // 50 frames * ~50 MB ≈ 2.5 GB, NOT 9999 frames.
      expect(projection.projectedBytes, lessThan(_gb(3)));
    });

    test('propagates DiskSpaceException from underlying service', () async {
      fake.setError(const DiskSpaceException('C:/data', 'drive missing'));
      expect(
        () => guard.projectSequence(
          capturePath: 'C:/data',
          sequence: _seqWithExposures(10),
          capabilities: _cap6kMono16,
        ),
        throwsA(isA<DiskSpaceException>()),
      );
    });
  });

  group('DiskSpaceGuardService watchdog', () {
    test('emits warning event when free space drops below threshold', () async {
      final fake = _FakeDiskSpaceService();
      final guard = DiskSpaceGuardService(diskService: fake);
      addTearDown(guard.dispose);

      fake.set(
        DiskSpaceInfo(
          path: 'C:/',
          totalBytes: _gb(500),
          freeBytes: _gb(5), // below 10 GB warning, above 2 GB abort
          sampledAt: DateTime.now(),
        ),
      );

      final events = <DiskSpaceWatchdogEvent>[];
      final sub = guard.events.listen(events.add);
      addTearDown(sub.cancel);

      guard.start(
        capturePath: 'C:/data',
        interval: const Duration(milliseconds: 50),
      );
      // Give the first immediate poll time to land.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      guard.stop();

      expect(events, isNotEmpty);
      expect(events.first.severity, DiskSpaceSeverity.warning);
    });

    test(
      'emits blocking event when free space drops below abort threshold',
      () async {
        final fake = _FakeDiskSpaceService();
        final guard = DiskSpaceGuardService(diskService: fake);
        addTearDown(guard.dispose);

        fake.set(
          DiskSpaceInfo(
            path: 'C:/',
            totalBytes: _gb(500),
            freeBytes: _gb(1), // below both thresholds
            sampledAt: DateTime.now(),
          ),
        );

        final events = <DiskSpaceWatchdogEvent>[];
        final sub = guard.events.listen(events.add);
        addTearDown(sub.cancel);

        guard.start(
          capturePath: 'C:/data',
          interval: const Duration(milliseconds: 50),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        guard.stop();

        // First emitted event should be the higher severity (blocking) — the
        // abort branch is checked before warning.
        expect(
          events.any((e) => e.severity == DiskSpaceSeverity.blocking),
          isTrue,
        );
      },
    );

    test('does not emit when free space is above both thresholds', () async {
      final fake = _FakeDiskSpaceService();
      final guard = DiskSpaceGuardService(diskService: fake);
      addTearDown(guard.dispose);

      fake.set(
        DiskSpaceInfo(
          path: 'C:/',
          totalBytes: _gb(500),
          freeBytes: _gb(50),
          sampledAt: DateTime.now(),
        ),
      );

      final events = <DiskSpaceWatchdogEvent>[];
      final sub = guard.events.listen(events.add);
      addTearDown(sub.cancel);

      guard.start(
        capturePath: 'C:/data',
        interval: const Duration(milliseconds: 50),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      guard.stop();

      expect(events, isEmpty);
    });

    test('does not overlap a slow disk query', () async {
      final fake = _PendingDiskSpaceService();
      final guard = DiskSpaceGuardService(diskService: fake);
      addTearDown(guard.dispose);

      guard.start(
        capturePath: 'C:/data',
        interval: const Duration(milliseconds: 5),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(fake.requests, hasLength(1));
      expect(fake.maxInFlight, 1);

      fake.requests.single.complete(
        DiskSpaceInfo(
          path: 'C:/',
          totalBytes: _gb(500),
          freeBytes: _gb(50),
          sampledAt: DateTime.now(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 15));

      expect(fake.requests.length, greaterThanOrEqualTo(2));
      expect(fake.maxInFlight, 1);
      guard.stop();
      for (final request in fake.requests.where((r) => !r.isCompleted)) {
        request.complete(
          DiskSpaceInfo(
            path: 'C:/',
            totalBytes: _gb(500),
            freeBytes: _gb(50),
            sampledAt: DateTime.now(),
          ),
        );
      }
    });

    test('discards a slow low-space result after stop', () async {
      final fake = _PendingDiskSpaceService();
      final guard = DiskSpaceGuardService(diskService: fake);
      addTearDown(guard.dispose);
      final events = <DiskSpaceWatchdogEvent>[];
      final sub = guard.events.listen(events.add);
      addTearDown(sub.cancel);

      guard.start(capturePath: 'C:/old', interval: const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      guard.stop();
      fake.requests.single.complete(
        DiskSpaceInfo(
          path: 'C:/old',
          totalBytes: _gb(500),
          freeBytes: _gb(1),
          sampledAt: DateTime.now(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events, isEmpty);
    });

    test('discards the previous capture path result after restart', () async {
      final fake = _PendingDiskSpaceService();
      final guard = DiskSpaceGuardService(diskService: fake);
      addTearDown(guard.dispose);
      final events = <DiskSpaceWatchdogEvent>[];
      final sub = guard.events.listen(events.add);
      addTearDown(sub.cancel);

      guard.start(capturePath: 'C:/old', interval: const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      guard.start(capturePath: 'D:/new', interval: const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(fake.paths, ['C:/old', 'D:/new']);
      fake.requests[0].complete(
        DiskSpaceInfo(
          path: 'C:/old',
          totalBytes: _gb(500),
          freeBytes: _gb(1),
          sampledAt: DateTime.now(),
        ),
      );
      fake.requests[1].complete(
        DiskSpaceInfo(
          path: 'D:/new',
          totalBytes: _gb(500),
          freeBytes: _gb(50),
          sampledAt: DateTime.now(),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(events, isEmpty);
    });
  });
}
