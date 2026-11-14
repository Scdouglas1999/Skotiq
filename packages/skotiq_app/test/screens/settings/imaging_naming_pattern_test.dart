// The settings field refuses a pattern the capture pipeline would refuse
// (`NamingPattern.problem`, the rule both share), keeps the stored value, and
// shows the example filename for a good one and every token it may use.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/imaging_settings.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Imaging settings page', () {
    Future<HarnessHandle> pump(
      WidgetTester tester, {
      String stored = r'$TARGET_$FILTER_$DATE_$SEQ',
    }) async {
      final database = mockDatabase();
      await database.settingsDao.setSettings({
        'file_naming_pattern': stored,
      });
      addTearDown(database.close);
      return pumpAppScreen(
        tester,
        const ImagingSettings(),
        size: const Size(1000, 800),
        database: database,
        settle: false,
      );
    }

    testWidgets('an unknown variable is refused and never persisted',
        (tester) async {
      final handle = await pump(tester);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      await tester.enterText(find.byType(TextField), r'$TARGET_$BANANA');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      expect(
        find.byKey(const Key('imaging.namingPattern.error')),
        findsOneWidget,
      );
      expect(find.textContaining(r'Unknown variable $BANANA'), findsOneWidget);
      expect(
        handle.container.read(appSettingsProvider).value!.fileNamingPattern,
        r'$TARGET_$FILTER_$DATE_$SEQ',
      );
      expect(
        await handle.database.settingsDao.getSetting('file_naming_pattern'),
        r'$TARGET_$FILTER_$DATE_$SEQ',
      );
    });

    testWidgets('a traversal segment is refused and never persisted',
        (tester) async {
      final handle = await pump(tester);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      await tester.enterText(find.byType(TextField), r'../../../pwned/$TARGET');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      expect(find.textContaining('Unsafe path segment'), findsOneWidget);
      expect(
        await handle.database.settingsDao.getSetting('file_naming_pattern'),
        r'$TARGET_$FILTER_$DATE_$SEQ',
      );
    });

    testWidgets('a valid pattern saves and shows the example it resolves to',
        (tester) async {
      final handle = await pump(tester);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      expect(
        find.byKey(const Key('imaging.namingPattern.preview')),
        findsOneWidget,
      );

      await tester.enterText(
        find.byType(TextField),
        r'$TARGET/$FRAMETYPE/$TARGET_$FILTER_$FRAMENUM',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      expect(
          find.byKey(const Key('imaging.namingPattern.error')), findsNothing);
      expect(
        handle.container.read(appSettingsProvider).value!.fileNamingPattern,
        r'$TARGET/$FRAMETYPE/$TARGET_$FILTER_$FRAMENUM',
      );
      expect(
        find.text('Example: M31/light/M31_L_0001.fits'),
        findsOneWidget,
      );
    });

    testWidgets('a pattern persisted before validation existed is reported',
        (tester) async {
      // Upgrade path: the DB can already hold a pattern that will fail the
      // first exposure. It must not sit there looking healthy.
      await pump(tester, stored: r'$TARGET_$BANANA');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      expect(
        find.byKey(const Key('imaging.namingPattern.error')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('imaging.namingPattern.preview')),
        findsNothing,
      );
    });

    testWidgets('the field lists every token the pattern may use',
        (tester) async {
      await pump(tester);
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      final subtitle = find.textContaining('Variables: ');
      expect(subtitle, findsOneWidget);
      final text = tester.widget<Text>(subtitle).data!;
      for (final token in NamingToken.values) {
        expect(text, contains(token.text));
      }
    });
  });
}
