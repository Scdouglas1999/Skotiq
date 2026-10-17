import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_session_summary.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('science summary sources session images and target from the host',
      () async {
    final backend = _MockNetworkBackend();
    final timestamp = DateTime.utc(2026, 7, 13);
    final hostImage = DbCapturedImage(
      id: 99,
      filePath: '/host/light.fits',
      fileName: 'light.fits',
      fileFormat: 'fits',
      sessionId: 7,
      targetId: 42,
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      isPlateSolved: true,
      capturedAt: timestamp,
      createdAt: timestamp,
      isAccepted: true,
    );
    when(() => backend.getSessionImageRows(7)).thenAnswer(
      (_) async => [hostImage.toJson()],
    );
    when(() => backend.getSessionById(7)).thenAnswer(
      (_) async => {'id': 7, 'targetId': 42},
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

    final images = await container.read(dbSessionImagesProvider(7).future);
    expect(images.single.id, 99);
    expect(
      await container.read(scienceSessionTargetIdProvider(7).future),
      42,
    );
    verify(() => backend.getSessionImageRows(7)).called(1);
    verify(() => backend.getSessionById(7)).called(1);
  });
}
