// SY-11 (sync night 2026-11-03): Analytics > Session opened on the host's last
// night ("Rig test NGC 7331") on the host and on "Quick captures (no session
// selected)" on a linked client, because the client had no answer to "the
// newest session that holds light frames" and fell through to none.
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart'
    show latestScienceSessionProvider;
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('host and client open on the same session', () async {
    final db = mockDatabase();
    addTearDown(db.close);
    final host = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(host.dispose);

    Future<int> night(DateTime at,
        {required String type, int frames = 2}) async {
      final id = await host.read(sessionsDaoProvider).createSession(
            ImagingSessionsCompanion.insert(startTime: at),
          );
      for (var i = 0; i < frames; i++) {
        await host.read(imagesDaoProvider).createImage(
              CapturedImagesCompanion.insert(
                filePath: '/subs/$id-$i.fits',
                fileName: '$id-$i.fits',
                sessionId: Value(id),
                exposureDuration: 60,
                frameType: Value(type),
                capturedAt: at.add(Duration(minutes: i)),
              ),
            );
      }
      return id;
    }

    // The imaging run, then the end-of-night darks in a session of their own,
    // then quick captures outside any session.
    final imaging = await night(DateTime(2026, 11, 3, 18, 17), type: 'light');
    await night(DateTime(2026, 11, 3, 18, 33), type: 'dark', frames: 3);
    await host.read(imagesDaoProvider).createImage(
          CapturedImagesCompanion.insert(
            filePath: '/subs/snap.fits',
            fileName: 'snap.fits',
            exposureDuration: 3,
            frameType: const Value('light'),
            capturedAt: DateTime(2026, 11, 3, 19, 40),
          ),
        );

    expect(await host.read(latestScienceSessionProvider.future), imaging);

    final backend = _MockNetworkBackend();
    when(() => backend.eventStream)
        .thenAnswer((_) => const Stream<SkotiqEvent>.empty());
    final hostRows = await db.imagesDao.getAllImages();
    final client = ProviderContainer(
      overrides: [
        backendProvider
            .overrideWith((ref) => TestBackendNotifier(ref, backend)),
        allDbImagesProvider.overrideWith((ref) => Stream.value(hostRows)),
      ],
    );
    addTearDown(client.dispose);

    expect(await client.read(latestScienceSessionProvider.future), imaging);
  });
}
