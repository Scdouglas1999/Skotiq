import 'package:drift/drift.dart' show Value;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

DbCapturedImage _frame(String name) => DbCapturedImage(
      id: 7,
      filePath: '/host/$name',
      fileName: name,
      fileFormat: 'fits',
      sessionId: 42,
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 14),
      createdAt: DateTime.utc(2026, 7, 14),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  test(
    'a linked client cuts a session\'s frames from the one polled table',
    () async {
      final backend = _MockNetworkBackend();
      final other = _frame('other.fits').copyWith(id: 8, sessionId: const Value(9));
      when(() => backend.getAllImageRows()).thenAnswer(
        (_) async => [_frame('first.fits').toJson(), other.toJson()],
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

      final session = container.listen(dbSessionImagesProvider(42), (_, __) {});
      final standalone = container.listen(standaloneImagesProvider, (_, __) {});
      addTearDown(session.close);
      addTearDown(standalone.close);

      final images = await container.read(dbSessionImagesProvider(42).future);
      expect(images.map((image) => image.fileName), ['first.fits']);
      expect(await container.read(standaloneImagesProvider.future), isEmpty);
      verify(() => backend.getAllImageRows()).called(1);
      verifyNever(() => backend.getSessionImageRows(any()));
    },
  );
}
