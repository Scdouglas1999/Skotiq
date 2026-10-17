import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import '../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

void main() {
  const csv =
      'Title,Subject,Integration\n'
      '"Andromeda","M31","6.5"\n';

  test(
    'AstroBin import resolves through the remote imaging-host catalog',
    () async {
      final backend = _MockNetworkBackend();
      when(() => backend.planetariumCatalogSearch('M31')).thenAnswer(
        (_) async => {
          'results': [
            {
              'name': 'Andromeda Galaxy',
              'catalogId': 'NGC 224',
              'ra': 10.683,
              'raHours': 0.7122,
              'dec': 41.269,
            },
          ],
        },
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

      final result = await container
          .read(sequenceImporterProvider)
          .importAstrobinAsync(
            csv,
            forceUnsupported: false,
            forceImport: true,
            sequenceName: 'AstroBin import',
          );

      expect(result.resolvedRows, 1);
      expect(result.unresolved, isEmpty);
      final target = result.importResult.sequence.nodes.values
          .whereType<TargetHeaderNode>()
          .single;
      expect(target.targetName, 'Andromeda Galaxy');
      expect(target.raHours, closeTo(0.7122, 1e-6));
      expect(target.decDegrees, closeTo(41.269, 1e-6));
      verify(() => backend.planetariumCatalogSearch('M31')).called(1);
    },
  );

  test(
    'malformed remote catalog response fails instead of unresolved success',
    () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.planetariumCatalogSearch('M31'),
      ).thenAnswer((_) async => {'unexpected': true});
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      expect(
        () => container
            .read(sequenceImporterProvider)
            .importAstrobinAsync(
              csv,
              forceUnsupported: false,
              forceImport: true,
              sequenceName: 'AstroBin import',
            ),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
