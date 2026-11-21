import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../harness/in_memory_database.dart';

void main() {
  test(
    'a new session starts empty and keeps both runs in the database',
    () async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);
      final session = container.read(sessionStateProvider.notifier);
      final images = container.read(imagesDaoProvider);
      final at = DateTime.utc(2026, 10, 19, 2);

      await session.startSession(targetName: 'Session A');
      final sessionA = container.read(sessionStateProvider).dbSessionId!;
      await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/session-a.fits',
          fileName: 'session-a.fits',
          frameType: const Value('light'),
          exposureDuration: 60,
          capturedAt: at,
          sessionId: Value(sessionA),
        ),
      );
      container
          .read(sessionImagesProvider.notifier)
          .addImage(
            CapturedImage(
              id: '1',
              filePath: '/session-a.fits',
              capturedAt: at,
              settings: const ExposureSettings(
                exposureTime: 60,
                gain: 100,
                offset: 10,
              ),
            ),
          );
      await session.endSession(status: SessionStatus.completed);
      expect(
        container.read(sessionImagesProvider).map((frame) => frame.filePath),
        ['/session-a.fits'],
      );

      await session.startSession(targetName: 'Session B');
      expect(container.read(sessionImagesProvider), isEmpty);

      final sessionB = container.read(sessionStateProvider).dbSessionId!;
      await images.createImage(
        CapturedImagesCompanion.insert(
          filePath: '/session-b.fits',
          fileName: 'session-b.fits',
          frameType: const Value('light'),
          exposureDuration: 90,
          capturedAt: at.add(const Duration(hours: 1)),
          sessionId: Value(sessionB),
        ),
      );
      container
          .read(sessionImagesProvider.notifier)
          .addImage(
            CapturedImage(
              id: '2',
              filePath: '/session-b.fits',
              capturedAt: at.add(const Duration(hours: 1)),
              settings: const ExposureSettings(
                exposureTime: 90,
                gain: 100,
                offset: 10,
              ),
            ),
          );
      expect(
        container.read(sessionImagesProvider).map((frame) => frame.filePath),
        ['/session-b.fits'],
      );
      expect(await images.getImageCount(), 2);
    },
  );
}
