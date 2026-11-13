import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

final _night = DateTime(2026, 3, 1, 22);

Map<String, dynamic> _hostRow(int id, {required int sessionId}) => {
  'id': id,
  'filePath': '/host/frame-$id.fits',
  'fileName': 'frame-$id.fits',
  'fileFormat': 'fits',
  'frameType': 'light',
  'exposureDuration': 120,
  'binX': 1,
  'binY': 1,
  'sessionId': sessionId,
  'capturedAt': _night.add(Duration(minutes: id)).millisecondsSinceEpoch,
  'createdAt': _night.add(Duration(minutes: id)).millisecondsSinceEpoch,
  'isAccepted': true,
  'isPlateSolved': false,
};

Future<List<DbCapturedImage>> _settled(
  ProviderContainer container,
  ProviderListenable<AsyncValue<List<DbCapturedImage>>> provider,
) async {
  final subscription = container.listen(provider, (_, __) {});
  addTearDown(subscription.close);
  for (var i = 0; i < 50 && !container.read(provider).hasValue; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return container.read(provider).requireValue;
}

void main() {
  final window = (
    start: _night.subtract(const Duration(hours: 10)),
    end: _night.add(const Duration(hours: 14)),
  );

  test('the host reads a session and a night from its own database', () async {
    final container = ProviderContainer(overrides: [inMemoryDatabaseOverride()]);
    addTearDown(container.dispose);
    final images = container.read(imagesDaoProvider);
    final sessionId = await container
        .read(sessionsDaoProvider)
        .startSession(name: 'Night');
    for (final (minute, session) in [(2, sessionId), (1, sessionId), (3, null)]) {
      await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/data/frame-$minute.fits',
          fileName: 'frame-$minute.fits',
          frameType: const Value('light'),
          exposureDuration: 120,
          capturedAt: _night.add(Duration(minutes: minute)),
          sessionId: Value(session),
        ),
      );
    }

    final ofSession = await _settled(
      container,
      sessionImageRowsProvider(sessionId),
    );
    expect(ofSession.map((row) => row.fileName), [
      'frame-1.fits',
      'frame-2.fits',
    ]);
    final ofNight = await _settled(
      container,
      imageRowsCapturedBetweenProvider(window),
    );
    expect(ofNight, hasLength(3));
    expect(container.read(watchedHostSessionIdProvider), isNull);
  });

  test('a linked client cuts the same lists from its host rows, and never '
      'from its own database', () async {
    final backend = _MockNetworkBackend();
    when(
      () => backend.eventStream,
    ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    when(() => backend.getAllImageRows()).thenAnswer(
      (_) async => [
        _hostRow(12, sessionId: 1),
        _hostRow(11, sessionId: 1),
        _hostRow(5, sessionId: 6),
      ],
    );
    when(() => backend.getAllSessions()).thenAnswer(
      (_) async => [
        {
          'id': 1,
          'startTime': _night.millisecondsSinceEpoch,
          'status': 'active',
        },
      ],
    );
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
      ],
    );
    addTearDown(container.dispose);
    // A row in the client's own database is nobody's frame.
    final ownSession = await container
        .read(sessionsDaoProvider)
        .startSession(name: 'Own');
    expect(ownSession, 1, reason: 'the stray row shares the session id');
    await container
        .read(imagesDaoProvider)
        .createImage(
          CapturedImagesCompanion.insert(
            filePath: '/client/stray.fits',
            fileName: 'stray.fits',
            frameType: const Value('light'),
            exposureDuration: 1,
            capturedAt: _night,
            sessionId: Value(ownSession),
          ),
        );

    final ofSession = await _settled(container, sessionImageRowsProvider(1));
    expect(ofSession.map((row) => row.id), [11, 12]);
    final ofNight = await _settled(
      container,
      imageRowsCapturedBetweenProvider(window),
    );
    expect(ofNight.map((row) => row.id), [5, 11, 12]);

    container.listen(allSessionsProvider, (_, __) {});
    await container.read(allSessionsProvider.future);
    expect(container.read(watchedHostSessionIdProvider), 1);
  });
}
