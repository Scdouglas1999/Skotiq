// Settings > Frame watch: obstruction detection is off until the operator
// turns it on, and once on a confirmed obstruction only notifies unless they
// choose Move on (owner, 2026-11-17).
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/frame_watch_settings_section.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('obstruction detection starts off and notifies once on', (
    tester,
  ) async {
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final handle = await pumpAppScreen(
      tester,
      const SingleChildScrollView(child: FrameWatchSettingsSection()),
      size: const Size(900, 1200),
      database: db,
    );
    await tester.pumpAndSettle();

    final detect = find.byKey(
      const ValueKey('frame-watch-obstruction-detection'),
    );
    expect(tester.widget<SettingsSwitch>(detect).value, isFalse);
    expect(find.text('When an obstruction is confirmed'), findsNothing);

    await tester.tap(detect);
    await tester.pump(const Duration(milliseconds: 400));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.text('When an obstruction is confirmed'), findsOneWidget);
    expect(find.text('Notify'), findsOneWidget);

    final settings = await tester.runAsync(
      () => handle.container.read(frameWatchSettingsProvider.future),
    );
    expect(settings!.obstructionDetection, isTrue);
    expect(settings.obstructionAction, ObstructionAction.notify);
    expect(
      settings.sequenceMetadata(
          latitude: 40, longitude: -75)['obstruction_action'],
      'notify',
    );
  });
}
