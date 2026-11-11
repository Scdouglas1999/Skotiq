import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

void main() {
  test('local backends have no remote host', () {
    final disconnected = DisconnectedBackend();
    final ffi = FfiBackend();
    addTearDown(disconnected.dispose);
    addTearDown(ffi.dispose);

    expect(disconnected.remoteHost, isNull);
    expect(ffi.remoteHost, isNull);
  });

  test('a network backend has one remote host with stable roles', () {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();

    final remoteA = hostA.remoteHost;
    expect(remoteA, isNotNull);
    expect(hostA.remoteHost, same(remoteA));
    expect(hostA.remoteHost!.observingLists, same(remoteA!.observingLists));
    expect(hostB.remoteHost, isNot(same(remoteA)));
    expect(
      hostB.remoteHost!.observingLists,
      isNot(same(remoteA.observingLists)),
    );
  });

  group('remote observing lists', () {
    late _MockNetworkBackend host;
    late ObservingListsStore store;

    setUp(() {
      host = _MockNetworkBackend();
      store = host.remoteHost!.observingLists;
    });

    test(
      'a write refreshes a live watch without waiting for the poll',
      () async {
        var lists = <ObservingList>[];
        when(host.getObservingLists).thenAnswer((_) async => lists);
        when(
          () => host.createObservingList(name: 'Spring', description: null),
        ).thenAnswer((_) async {
          lists = [
            ObservingList(
              id: 3,
              name: 'Spring',
              sortOrder: 0,
              createdAt: DateTime.utc(2026),
              updatedAt: DateTime.utc(2026),
            ),
          ];
          return 3;
        });

        final seen = <List<ObservingList>>[];
        final sub = store.watchAllLists().listen(seen.add);
        addTearDown(sub.cancel);
        await pumpEventQueue();
        expect(seen, [isEmpty]);

        expect(await store.createList(name: 'Spring'), 3);
        await pumpEventQueue();

        expect(seen, hasLength(2));
        expect(seen.last.single.name, 'Spring');
        verify(host.getObservingLists).called(2);
      },
    );

    test('clearing a description tells the wire it is deliberate', () async {
      when(
        () => host.updateObservingList(
          id: any(named: 'id'),
          name: any(named: 'name'),
          description: any(named: 'description'),
          setDescription: any(named: 'setDescription'),
        ),
      ).thenAnswer((_) async {});

      await store.updateList(id: 1, name: 'Renamed');
      await store.updateList(id: 1, description: 'Galaxies');
      await store.updateList(id: 1, clearDescription: true);

      verifyInOrder([
        () => host.updateObservingList(
          id: 1,
          name: 'Renamed',
          description: null,
          setDescription: false,
        ),
        () => host.updateObservingList(
          id: 1,
          name: null,
          description: 'Galaxies',
          setDescription: true,
        ),
        () => host.updateObservingList(
          id: 1,
          name: null,
          description: null,
          setDescription: true,
        ),
      ]);
    });

    test('a failed write surfaces the host error unchanged', () {
      const conflict = ServerError(
        code: 'conflict',
        message: 'M 31 is already in this list.',
        httpStatus: 409,
      );
      when(
        () => host.addObservingListItem(
          listId: 1,
          objectName: 'M 31',
          catalogId: any(named: 'catalogId'),
          objectType: any(named: 'objectType'),
          ra: 0.7,
          dec: 41.3,
          magnitude: any(named: 'magnitude'),
          sizeArcmin: any(named: 'sizeArcmin'),
          notes: any(named: 'notes'),
        ),
      ).thenThrow(conflict);

      expect(
        store.addItem(listId: 1, objectName: 'M 31', ra: 0.7, dec: 41.3),
        throwsA(same(conflict)),
      );
    });
  });
}
