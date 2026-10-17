import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart' as db;

/// Cover for the Dashboard "Recent Frames" strip on a *remote* client (the
/// Android companion, or a desktop launched with `--remote-host`).
///
/// Keying the remote branch off `sessionStateProvider.dbSessionId` empties the
/// strip: that id is only ever assigned by `SessionStateNotifier.startSession` /
/// `recoverSession`, and a client that merely *watches* a host-started run calls
/// neither. The phone's cockpit then renders "No frames captured this session
/// yet" while the host's `/api/sequencer/status` reports
/// `runVitals.framesCaptured: 1` and `/api/images/recent` returns the row.
class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _PinnedBackendNotifier extends BackendNotifier {
  _PinnedBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

db.ImagingSession _session({
  required int id,
  required String status,
  required DateTime startTime,
}) {
  return db.ImagingSession(
    id: id,
    name: 'session-$id',
    startTime: startTime,
    totalExposures: 0,
    successfulExposures: 0,
    failedExposures: 0,
    totalIntegrationSecs: 0,
    autofocusCount: 0,
    status: status,
  );
}

db.CapturedImage _imageRow({
  required int id,
  required int? sessionId,
  required DateTime capturedAt,
}) {
  return db.CapturedImage(
    id: id,
    filePath: '/captures/frame_$id.fits',
    fileName: 'frame_$id.fits',
    fileFormat: 'fits',
    sessionId: sessionId,
    frameType: 'light',
    exposureDuration: 3.0,
    binX: 1,
    binY: 1,
    isPlateSolved: false,
    capturedAt: capturedAt,
    createdAt: capturedAt,
    isAccepted: true,
  );
}

ProviderContainer _container({
  required List<db.ImagingSession> sessions,
  required List<db.CapturedImage> images,
}) {
  final container = ProviderContainer(
    overrides: [
      backendProvider.overrideWith(
        (ref) => _PinnedBackendNotifier(ref, _MockNetworkBackend()),
      ),
      databaseProvider.overrideWith(
        (ref) => throw StateError('remote client must not touch a local DB'),
      ),
      allSessionsProvider.overrideWith((ref) => Stream.value(sessions)),
      allDbImagesProvider.overrideWith((ref) => Stream.value(images)),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  final now = DateTime(2026, 7, 25, 17, 6);

  test(
    'remote client shows the host-started session frames without a local dbSessionId',
    () async {
      final container = _container(
        sessions: [
          // Newest-first, matching both SessionsDao.watchAllSessions and the
          // remote `_fetchRemoteSessions` sort.
          _session(id: 57, status: 'active', startTime: now),
          _session(
            id: 56,
            status: 'completed',
            startTime: now.subtract(const Duration(hours: 1)),
          ),
        ],
        images: [
          _imageRow(
            id: 147,
            sessionId: 57,
            capturedAt: now.add(const Duration(seconds: 4)),
          ),
          _imageRow(
            id: 140,
            sessionId: 56,
            capturedAt: now.subtract(const Duration(minutes: 50)),
          ),
        ],
      );

      // Nothing ever called startSession on this client.
      expect(container.read(sessionStateProvider).dbSessionId, isNull);

      // Let the overridden streams deliver their first value.
      await container.read(allSessionsProvider.future);
      await container.read(allDbImagesProvider.future);

      final frames = container.read(recentSessionFramesProvider);

      expect(
        frames,
        hasLength(1),
        reason:
            'the host reported a frame for the active session; the strip must '
            'render it instead of "No frames captured this session yet"',
      );
      expect(frames.single.filePath, '/captures/frame_147.fits');
    },
  );

  test(
    'frames from an older, already-finished session are not attributed to now',
    () async {
      final container = _container(
        sessions: [
          _session(
            id: 56,
            status: 'completed',
            startTime: now.subtract(const Duration(hours: 1)),
          ),
        ],
        images: [
          _imageRow(
            id: 140,
            sessionId: 56,
            capturedAt: now.subtract(const Duration(minutes: 50)),
          ),
        ],
      );

      await container.read(allSessionsProvider.future);
      await container.read(allDbImagesProvider.future);

      expect(
        container.read(recentSessionFramesProvider),
        isEmpty,
        reason:
            'no active session on the host — an empty strip is the truth here, '
            'and last night\'s frames must not be replayed as "this session"',
      );
    },
  );

  test('the newest active session wins when the host lists several', () async {
    final container = _container(
      sessions: [
        _session(id: 60, status: 'active', startTime: now),
        _session(
          id: 58,
          status: 'active',
          startTime: now.subtract(const Duration(hours: 2)),
        ),
      ],
      images: [
        _imageRow(id: 200, sessionId: 60, capturedAt: now),
        _imageRow(
          id: 180,
          sessionId: 58,
          capturedAt: now.subtract(const Duration(hours: 2)),
        ),
      ],
    );

    await container.read(allSessionsProvider.future);
    await container.read(allDbImagesProvider.future);

    final frames = container.read(recentSessionFramesProvider);
    expect(frames, hasLength(1));
    expect(frames.single.filePath, '/captures/frame_200.fits');
  });
}
