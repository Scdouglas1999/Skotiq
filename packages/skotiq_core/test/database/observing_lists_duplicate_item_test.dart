// Adding a target that is already in an observing list is an ordinary thing for
// a user to do — it must not be reported as a failure, and it must never leak a
// Dart exception string.
//
// The DAO threw a bare `StateError`, the notifier stored `'Failed to add item:
// $e'`, and the planner's add-to-list dialog rendered that string verbatim in
// red: `Failed to add item: Bad state: NGC6015 is already in this list as
// "NGC6015"`. Three things wrong at once — an internal exception prefix shown to
// a user, a tautological sentence, and a benign no-op presented as an error.

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  late SkotiqDatabase database;

  setUp(() {
    database = SkotiqDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await database.close();
  });

  Future<int> seedList(String catalogId, {String? objectName}) async {
    final dao = database.observingListsDao;
    final listId = await dao.createList(name: 'Summer Galaxies');
    await dao.addItem(
      listId: listId,
      objectName: objectName ?? catalogId,
      catalogId: catalogId,
      ra: 15.9,
      dec: 62.3,
    );
    return listId;
  }

  test('a duplicate add throws a typed, user-safe exception', () async {
    final listId = await seedList('NGC6015');

    await expectLater(
      database.observingListsDao.addItem(
        listId: listId,
        objectName: 'NGC6015',
        catalogId: 'NGC6015',
        ra: 15.9,
        dec: 62.3,
      ),
      throwsA(
        isA<ObservingListDuplicateItemException>()
            .having((e) => e.catalogId, 'catalogId', 'NGC6015')
            .having((e) => e.listId, 'listId', listId)
            .having((e) => e.existingItemId, 'existingItemId', isPositive),
      ),
    );
  });

  test(
    'the message is not tautological and carries no "Bad state:" prefix',
    () async {
      final listId = await seedList('NGC6015');

      Object? thrown;
      try {
        await database.observingListsDao.addItem(
          listId: listId,
          objectName: 'NGC6015',
          catalogId: 'NGC6015',
          ra: 15.9,
          dec: 62.3,
        );
      } catch (error) {
        thrown = error;
      }

      expect(thrown, isNotNull);
      expect('$thrown', 'NGC6015 is already in this list');
      expect('$thrown', isNot(contains('Bad state')));
    },
  );

  test(
    'a differently-named duplicate still names the existing entry',
    () async {
      final listId = await seedList(
        'NGC6015',
        objectName: 'My favourite spiral',
      );

      Object? thrown;
      try {
        await database.observingListsDao.addItem(
          listId: listId,
          objectName: 'NGC6015',
          catalogId: 'NGC6015',
          ra: 15.9,
          dec: 62.3,
        );
      } catch (error) {
        thrown = error;
      }

      expect(
        '$thrown',
        'NGC6015 is already in this list as "My favourite spiral"',
      );
    },
  );

  test('it is still a StateError so the host keeps answering HTTP 409', () async {
    // apps/desktop's POST /api/observing-lists/items maps `on StateError` to a
    // 409 so a remote slave gets the same outcome as the local UI. Narrowing the
    // DAO to a new type must not quietly break that mapping.
    final listId = await seedList('NGC6015');

    await expectLater(
      database.observingListsDao.addItem(
        listId: listId,
        objectName: 'NGC6015',
        catalogId: 'NGC6015',
        ra: 15.9,
        dec: 62.3,
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('a genuinely new catalog id is still added', () async {
    final listId = await seedList('NGC6015');

    final id = await database.observingListsDao.addItem(
      listId: listId,
      objectName: 'NGC6140',
      catalogId: 'NGC6140',
      ra: 16.35,
      dec: 65.4,
    );

    expect(id, isPositive);
    expect(
      await database.observingListsDao.getItemsForList(listId),
      hasLength(2),
    );
  });
}
