import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/src/database/daos/focus_history_dao.dart';
import 'package:skotiq_core/src/services/focus_model_service.dart';

void main() {
  test(
    'a failed initialize is not cached, so the next call can succeed',
    () async {
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      var failFolderOnce = true;
      final focus = FocusModelService(
        FocusHistoryDao(db),
        jsonFolder: () async {
          if (failFolderOnce) {
            failFolderOnce = false;
            throw StateError('transient storage failure');
          }
          return null;
        },
      );

      await expectLater(focus.initialize(), throwsStateError);
      await focus.setReferenceFilter('fresh-profile', 'L');
      expect(focus.getProfileData('fresh-profile')?.referenceFilter, 'L');
    },
  );
}
