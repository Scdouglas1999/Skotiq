import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

void main() {
  setUpAll(() {
    registerFallbackValue(<String, dynamic>{});
  });

  group('TargetLibraryService', () {
    test('uses host REST API when connected remotely', () async {
      final backend = _MockNetworkBackend();
      when(() => backend.getAllTargets()).thenAnswer((_) async => []);
      when(() => backend.createTarget(any())).thenAnswer((_) async => 42);

      final container = ProviderContainer(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      final id = await container
          .read(targetLibraryServiceProvider)
          .createTarget(
            name: 'SN 2026abc',
            raHours: 5.5,
            decDegrees: 20.0,
            catalogId: 'SN2026abc',
            objectType: 'star',
          );

      expect(id, 42);
      verify(
        () => backend.createTarget(
          any(
            that: predicate<Map<String, dynamic>>(
              (payload) =>
                  payload['name'] == 'SN 2026abc' && payload['ra'] == 5.5,
            ),
          ),
        ),
      ).called(1);
    });

    test('writes to local database when using FFI backend', () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() async => db.close());

      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, DisconnectedBackend()),
          ),
        ],
      );
      addTearDown(container.dispose);

      final id = await container
          .read(targetLibraryServiceProvider)
          .createTarget(
            name: 'M31',
            raHours: 0.7,
            decDegrees: 41.3,
            catalogId: 'M31',
          );

      final rows = await db.targetsDao.getAllTargets();
      expect(id, greaterThan(0));
      expect(rows.any((t) => t.id == id && t.name == 'M31'), isTrue);
    });

    test(
      'ensureCatalogTarget returns existing row without duplicate',
      () async {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        addTearDown(() async => db.close());

        final existingId = await db.targetsDao.createTarget(
          TargetsCompanion.insert(
            name: 'M42',
            ra: 5.58,
            dec: -5.39,
            catalogId: const Value('M42'),
          ),
        );

        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, DisconnectedBackend()),
            ),
          ],
        );
        addTearDown(container.dispose);

        final resolved = await container
            .read(targetLibraryServiceProvider)
            .ensureCatalogTarget(
              targetName: 'M42',
              raHours: 5.58,
              decDegrees: -5.39,
              catalogId: 'M42',
            );

        expect(resolved.id, existingId);
        expect(await db.targetsDao.getAllTargets(), hasLength(1));
      },
    );

    test(
      'host switch during catalog lookup cannot create on the replacement rig',
      () async {
        final oldBackend = _MockNetworkBackend();
        final newBackend = _MockNetworkBackend();
        final oldTargets = Completer<List<Map<String, dynamic>>>();
        when(
          () => oldBackend.getAllTargets(),
        ).thenAnswer((_) => oldTargets.future);
        when(() => newBackend.getAllTargets()).thenAnswer((_) async => []);

        late _FixedBackendNotifier backendNotifier;
        final container = ProviderContainer(
          overrides: [
            backendProvider.overrideWith((ref) {
              backendNotifier = _FixedBackendNotifier(ref, oldBackend);
              return backendNotifier;
            }),
          ],
        );
        addTearDown(container.dispose);
        final service = container.read(targetLibraryServiceProvider);

        final ensuring = service.ensureCatalogTarget(
          targetName: 'M31',
          raHours: 0.7,
          decDegrees: 41.3,
          catalogId: 'M31',
        );
        await Future<void>.delayed(Duration.zero);
        backendNotifier.replaceWith(newBackend);
        oldTargets.complete([]);

        await expectLater(
          ensuring,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('host changed'),
            ),
          ),
        );
        verifyNever(() => oldBackend.createTarget(any()));
        verifyNever(() => newBackend.createTarget(any()));
      },
    );
  });
}
