import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_desktop/host/accepted_quit.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(AcceptedDesktopQuit.resetForTest);

  test(
    'quit closes the database before exit and does not destroy the window',
    () async {
      final root = Directory.systemTemp.createTempSync('sk-quit-');
      addTearDown(() => root.deleteSync(recursive: true));
      final file = File('${root.path}/skotiq.sqlite');
      final db = SkotiqDatabase.onFile(file);
      await db.settingsDao.setSetting('quit-probe', 'kept');

      final order = <String>[];
      var destroyed = false;
      await AcceptedDesktopQuit.run(
        flushPlacement: () async => order.add('flush'),
        handOffDarkroomWork: () async => order.add('handoff'),
        closeDatabase: () async {
          order.add('close');
          await db.close();
        },
        exitProcess: (code) {
          order.add('exit:$code');
          destroyed = destroyed;
        },
      );

      expect(order, ['flush', 'handoff', 'close', 'exit:0']);
      expect(destroyed, isFalse);

      final again = SkotiqDatabase.onFile(file);
      addTearDown(again.close);
      expect(await again.settingsDao.getSetting('quit-probe'), 'kept');
    },
  );

  test('a handoff that throws does not exit', () async {
    var exited = false;
    await expectLater(
      AcceptedDesktopQuit.run(
        flushPlacement: () async {},
        handOffDarkroomWork: () async => throw StateError('darkroom'),
        closeDatabase: () async => fail('closed after a failed handoff'),
        exitProcess: (_) => exited = true,
      ),
      throwsA(isA<StateError>()),
    );
    expect(exited, isFalse);
  });

  test('a second close while the first is running is ignored', () async {
    var exits = 0;
    var closes = 0;
    final gate = Future<void>.delayed(const Duration(milliseconds: 20));
    final first = AcceptedDesktopQuit.run(
      flushPlacement: () => gate,
      handOffDarkroomWork: () async {},
      closeDatabase: () async => closes++,
      exitProcess: (_) => exits++,
    );
    await Future<void>.delayed(Duration.zero);
    await AcceptedDesktopQuit.run(
      flushPlacement: () async => fail('second flush'),
      handOffDarkroomWork: () async {},
      closeDatabase: () async => closes++,
      exitProcess: (_) => exits++,
    );
    await first;
    expect(exits, 1);
    expect(closes, 1);
  });
}
