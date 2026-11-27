// A phone that is not linked reads rig data from a stand-in host that refuses
// every call. Asking it again on a timer only repeats the refusal, and no
// reader may leave that refusal uncaught.

import 'dart:async';

import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

class _Offline extends BackendNotifier {
  _Offline(super.ref) {
    state = DisconnectedBackend();
  }
}

void main() {
  test('an unlinked phone that read the science default session leaves no '
      'refusal uncaught, however long it waits', () {
    final uncaught = <Object>[];
    runZonedGuarded(() {
      fakeAsync((async) {
        final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
        final container = ProviderContainer(
          overrides: [
            databaseProvider.overrideWithValue(db),
            launchRoleProvider.overrideWithValue(LaunchRole.mobile),
            backendProvider.overrideWith((ref) => _Offline(ref)),
          ],
        );
        // The Analytics screen reads it, then the phone moves on.
        container.listen(scienceDefaultSessionProvider, (_, __) {}).close();
        async.elapse(const Duration(minutes: 3));
        container.dispose();
        unawaited(db.close());
        async.flushMicrotasks();
      });
    }, (error, _) => uncaught.add(error));
    expect(uncaught, isEmpty);
  });
}
