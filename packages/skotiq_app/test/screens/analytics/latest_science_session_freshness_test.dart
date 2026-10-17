// After a run completes, Analytics ▸ Session must review the NEW night, not the
// previous one.
//
// With two completed runs on disk the tab opens on the older one — "Reviewing
// New Sequence · Aug 13, 2026 20:53 · 4 frames" — with the newer run one row up
// in its own dropdown. Picking the newer night works and then reverts on
// navigating away and back, while restarting the app opens the SAME screen on
// the newer night: the signature of a cached answer rather than a wrong query.
// A plain FutureProvider computes `latestScienceSession` on first read and is
// never invalidated again for the life of the process.
import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_analytics_tab.dart'
    show latestScienceSessionProvider;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart';

import '../../harness/mock_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SkotiqDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = mockDatabase();
    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<int> seedNight(DateTime at) async {
    final sessions = container.read(sessionsDaoProvider);
    final images = container.read(imagesDaoProvider);
    final id = await sessions.createSession(
      ImagingSessionsCompanion.insert(startTime: at),
    );
    await images.createImage(
      CapturedImagesCompanion.insert(
        filePath: '/subs/${at.millisecondsSinceEpoch}.fits',
        fileName: '${at.millisecondsSinceEpoch}.fits',
        sessionId: Value(id),
        exposureDuration: 60,
        frameType: const Value('light'),
        capturedAt: at,
      ),
    );
    return id;
  }

  test('a finished run becomes the session the tab opens on', () async {
    final first = await seedNight(DateTime(2026, 8, 13, 20, 53));

    expect(await container.read(latestScienceSessionProvider.future), first);

    // A second night runs while the app stays open. The run's completion is
    // what writes the session row's end time — the moment the answer changes.
    final second = await seedNight(DateTime(2026, 8, 14, 0, 20));
    await container.read(sessionsDaoProvider).endSession(second);

    // Let the session stream deliver the write.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(
      await container.read(latestScienceSessionProvider.future),
      second,
      reason: 'the tab followed the previous night until the app restarted',
    );
  });
}
