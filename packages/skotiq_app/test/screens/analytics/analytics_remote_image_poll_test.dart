import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
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
    'remote image polling suppresses duplicates and retains data through a blip',
    () async {
      final backend = _MockNetworkBackend();
      final first = _frame('first.fits');
      final updated = _frame('updated.fits');
      var calls = 0;
      when(() => backend.getSessionImageRows(42)).thenAnswer((_) async {
        calls++;
        return switch (calls) {
          1 || 2 => [first.toJson()],
          3 => throw StateError('temporary host blip'),
          _ => [updated.toJson()],
        };
      });

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          analyticsRemoteImagePollIntervalProvider.overrideWithValue(
            const Duration(milliseconds: 5),
          ),
        ],
      );
      addTearDown(container.dispose);

      final states = <AsyncValue<List<DbCapturedImage>>>[];
      final subscription = container.listen(
        dbSessionImagesProvider(42),
        (_, next) => states.add(next),
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final deadline = DateTime.now().add(const Duration(seconds: 1));
      while (calls < 4 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(calls, greaterThanOrEqualTo(4));
      expect(states.where((state) => state.hasError), isEmpty);
      expect(
        states
            .map((state) => state.valueOrNull)
            .whereType<List<DbCapturedImage>>()
            .map((images) => images.single.fileName)
            .toList(),
        ['first.fits', 'updated.fits'],
      );
    },
  );
}
