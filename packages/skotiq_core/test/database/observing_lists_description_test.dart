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

  test('an explicit description clear persists as null', () async {
    final dao = database.observingListsDao;
    final id = await dao.createList(
      name: 'Winter targets',
      description: 'Old description',
    );

    await dao.updateList(id: id, clearDescription: true);

    expect((await dao.getListById(id))!.description, isNull);
  });
}
