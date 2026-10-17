// The settings field used to persist any string, so an unknown $TOKEN or an
// unsafe path segment was only reported when the first exposure of the night
// failed inside ImagingService.buildImageFilePath. Two things are pinned here:
//
//  1. the settings field refuses the same patterns the capture pipeline
//     refuses (drift guard: every case is run through BOTH implementations);
//  2. the Imaging page rejects the edit, keeps the stored value, and shows the
//     resolved example filename for a good one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/imaging_naming_pattern.dart';
import 'package:skotiq_app/screens/settings/widgets/imaging_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:path/path.dart' as p;

import '../../harness/harness.dart';

/// Patterns exercised against both implementations. Mix of good, unknown
/// token, traversal, absolute, empty and unsafe-character cases.
const _corpus = <String>[
  r'$TARGET_$FILTER_$DATE_$SEQ',
  r'$TARGET/$FRAMETYPE/$TARGET_$FILTER_$EXPTIME_$FRAMENUM',
  r'$SESSION/$CAMERA/$TELESCOPE_$BINNING_$GAIN_$OFFSET_$TEMP_$FRAMENUM',
  r'$DATETIME_$TIME_$EXPOSURE',
  'literal_name',
  r'$TARGET_$BANANA',
  r'$NOPE',
  r'../../../pwned/$NOPE',
  r'../$TARGET',
  r'$TARGET/../$FILTER',
  r'/abs/$TARGET',
  '',
  '   ',
  r'$TARGET//$FILTER',
  r'$TARGET:$FILTER',
  r'$TARGET\$FILTER',
  r'$target',
  r'$TARGET$',
];

bool _pipelineAccepts(String pattern, Map<String, String> substitutions) {
  try {
    ImagingService.buildImageFilePath(
      pattern: pattern,
      basePath: '/base',
      extension: 'fits',
      substitutions: substitutions,
    );
    return true;
  } catch (_) {
    // ValidationException is not exported from the skotiq_core barrel;
    // any throw at all is a failed capture, which is what matters here.
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('validator matches the capture pipeline', () {
    final now = DateTime.utc(2026, 8, 3, 21, 34, 56);
    final substitutions = namingPatternExampleSubstitutions(now: now);

    for (final pattern in _corpus) {
      test('accept/reject agree for "$pattern"', () {
        final check = checkNamingPattern(pattern, now: now);
        expect(
          check.isValid,
          _pipelineAccepts(pattern, substitutions),
          reason:
              'settings validation diverged from ImagingService for "$pattern"',
        );
      });
    }

    test('the preview is the path the pipeline would actually write', () {
      for (final pattern in _corpus) {
        final check = checkNamingPattern(pattern, now: now);
        if (!check.isValid) continue;
        final real = ImagingService.buildImageFilePath(
          pattern: pattern,
          basePath: '/base',
          extension: 'fits',
          substitutions: substitutions,
        );
        expect(
          check.preview,
          p.relative(real, from: '/base'),
          reason: 'preview for "$pattern" is not what would be captured',
        );
      }
    });

    test('every token the pipeline knows is offered by the validator', () {
      // ImagingService._patternVariables is private; probe it by round-tripping
      // each token the validator claims to support through the real path.
      for (final token in kNamingPatternVariables) {
        expect(
          _pipelineAccepts(token, substitutions),
          isTrue,
          reason: '$token is advertised in settings but rejected at capture',
        );
      }
    });
  });

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
  });
}
