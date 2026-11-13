import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/src/providers/sequence/sequence_catalog_sync.dart'
    as catalog_sync;

import '../../harness/in_memory_database.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _MockLocalBackend extends Mock implements SkotiqBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) => state = backend;
}

void main() {
  setUpAll(() {
    registerFallbackValue(const Stream<SkotiqEvent>.empty());
  });

  group('SequenceCatalogUpdateBus', () {
    test('notifies subscribers with update payload', () async {
      final container = ProviderContainer(
        overrides: [inMemoryDatabaseOverride()],
      );
      addTearDown(container.dispose);

      final bus = container.read(sequenceCatalogUpdateBusProvider);
      final updates = <SequenceCatalogUpdate>[];
      final sub = bus.stream.listen(updates.add);

      catalog_sync.notifySequenceCatalogChangedFromContainer(
        container,
        sequenceId: 12,
        action: 'saved',
        name: 'M42',
      );

      // Allow broadcast stream delivery (listener registered before notify).
      await Future<void>.delayed(Duration.zero);

      expect(updates, hasLength(1));
      expect(updates.single.sequenceId, 12);
      expect(updates.single.action, 'saved');
      expect(updates.single.name, 'M42');

      unawaited(sub.cancel());
    });

    test('toSkotiqEvent uses SequenceUpdated event type', () {
      const update = SequenceCatalogUpdate(sequenceId: 3, action: 'deleted');

      expect(update.toSkotiqEvent().eventType, sequenceUpdatedEventType);
      expect(update.toSkotiqEvent().category, EventCategory.sequencer);
    });
  });

  group('sequenceLibrarySyncProvider', () {
    test('invalidates savedSequencesProvider when bus notifies', () async {
      final backend = _MockNetworkBackend();
      when(
        () => backend.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      when(() => backend.listFullSequences()).thenAnswer((_) async => []);

      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(container.dispose);

      container.read(sequenceLibrarySyncProvider);
      container.listen(savedSequencesProvider, (_, __) {});
      await container.read(savedSequencesProvider.future);

      catalog_sync.notifySequenceCatalogChangedFromContainer(
        container,
        sequenceId: 1,
        action: 'saved',
        name: 'Test',
      );

      await Future<void>.delayed(Duration.zero);
      await container.read(savedSequencesProvider.future);
      // Two consumers now reload on a catalog change: the full-sequence list
      // and the lightweight summary list. Both derive from the remote
      // listFullSequences endpoint, so a single notify re-fetches it: once for
      // the initial full-list load and once each time the library invalidates.
      verify(() => backend.listFullSequences()).called(greaterThanOrEqualTo(2));
    });

    test(
      'invalidates savedSequencesProvider on SequenceUpdated WS event',
      () async {
        final eventController = StreamController<SkotiqEvent>.broadcast();
        final backend = _MockNetworkBackend();
        when(
          () => backend.eventStream,
        ).thenAnswer((_) => eventController.stream);
        when(() => backend.listFullSequences()).thenAnswer((_) async => []);

        final container = ProviderContainer(
          overrides: [
            inMemoryDatabaseOverride(),
            backendProvider.overrideWith(
              (ref) => _FixedBackendNotifier(ref, backend),
            ),
          ],
        );
        addTearDown(() async {
          await eventController.close();
          container.dispose();
        });

        container.read(sequenceLibrarySyncProvider);

        var fetchCount = 0;
        container.listen(savedSequencesProvider, (_, __) {
          fetchCount++;
        }, fireImmediately: true);

        await container.read(savedSequencesProvider.future);
        final before = fetchCount;

        eventController.add(
          const SequenceCatalogUpdate(
            sequenceId: 9,
            action: 'saved',
          ).toSkotiqEvent(),
        );

        await Future<void>.delayed(Duration.zero);
        await container.read(savedSequencesProvider.future);
        expect(fetchCount, greaterThan(before));
      },
    );

    test('follows the events of a host linked after start-up', () async {
      final local = _MockLocalBackend();
      when(
        () => local.eventStream,
      ).thenAnswer((_) => const Stream<SkotiqEvent>.empty());
      final eventController = StreamController<SkotiqEvent>.broadcast();
      final host = _MockNetworkBackend();
      when(() => host.eventStream).thenAnswer((_) => eventController.stream);
      when(() => host.listFullSequences()).thenAnswer((_) async => []);

      late _FixedBackendNotifier backendNotifier;
      final container = ProviderContainer(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => backendNotifier = _FixedBackendNotifier(ref, local),
          ),
        ],
      );
      addTearDown(() async {
        await eventController.close();
        container.dispose();
      });

      container.read(sequenceLibrarySyncProvider);
      backendNotifier.replaceWith(host);
      expect(eventController.hasListener, isTrue);
    });
  });
}
