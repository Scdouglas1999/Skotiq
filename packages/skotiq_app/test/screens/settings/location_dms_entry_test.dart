// Settings → Location must accept a coordinate written the way coordinates
// are written.
//
// Live: Latitude and Longitude were plain numeric fields whose digits-only
// input formatter rejected every other character. A site held in
// degrees-minutes-seconds — what a GPS handset, a topo map and most club site
// lists give you — could not be typed, and pasting one was a SILENT no-op:
// the box did not change and nothing was said. The only route was to leave
// the app, convert by hand, and come back with a decimal.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_search_index.g.dart';
import 'package:skotiq_app/screens/settings/widgets/location_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

Future<HarnessHandle> _pumpLocation(WidgetTester tester) async {
  final handle = await pumpAppScreen(
    tester,
    const LocationSettingsPage(),
    size: const Size(1280, 1400),
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(const AppSettingsState()),
      ),
      isRemoteModeProvider.overrideWithValue(false),
    ],
  );
  await tester.pumpAndSettle();
  return handle;
}

Finder _fieldIn(String rowTitle) => find.descendant(
      of: find.widgetWithText(SettingRow, rowTitle),
      matching: find.byType(TextField),
    );

/// Type into a coordinate row and leave it, which is how the row commits.
Future<void> _enter(
  WidgetTester tester,
  String rowTitle,
  String text,
) async {
  final field = _fieldIn(rowTitle);
  await tester.ensureVisible(field);
  await tester.pump();
  await tester.enterText(field, text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the site coordinate fields', () {
    testWidgets('take a latitude in degrees, minutes and seconds', (
      tester,
    ) async {
      final handle = await _pumpLocation(tester);

      await _enter(tester, 'Latitude', '44 3 29 N');

      expect(
        handle.container.read(appSettingsProvider).requireValue.latitude,
        closeTo(44.058056, 1e-6),
      );
    });

    testWidgets('take a west longitude and store it negative', (tester) async {
      final handle = await _pumpLocation(tester);

      await _enter(tester, 'Longitude', '121° 18\' 55" W');

      expect(
        handle.container.read(appSettingsProvider).requireValue.longitude,
        closeTo(-121.315278, 1e-6),
      );
    });

    testWidgets('show back what they understood, in decimal degrees', (
      tester,
    ) async {
      await _pumpLocation(tester);

      await _enter(tester, 'Latitude', '44 3 29 N');

      // The operator must be able to see that "44 3 29 N" was read as 44.058
      // and not, say, 4432.9 — the field normalises rather than echoing.
      final field = tester.widget<TextField>(_fieldIn('Latitude'));
      expect(field.controller!.text, '44.058056');
    });

    testWidgets('still take plain decimal degrees', (tester) async {
      final handle = await _pumpLocation(tester);

      await _enter(tester, 'Latitude', '-33.8688');

      expect(
        handle.container.read(appSettingsProvider).requireValue.latitude,
        closeTo(-33.8688, 1e-6),
      );
    });

    testWidgets('refuse a string they cannot read instead of inventing one', (
      tester,
    ) async {
      final handle = await _pumpLocation(tester);

      await _enter(tester, 'Latitude', '44 3 29 N');
      await _enter(tester, 'Latitude', 'somewhere in Oregon');

      expect(
        handle.container.read(appSettingsProvider).requireValue.latitude,
        closeTo(44.058056, 1e-6),
        reason: 'an unreadable entry must not overwrite the stored site',
      );
      expect(
        tester.widget<TextField>(_fieldIn('Latitude')).controller!.text,
        '44.058056',
      );
    });
  });

  // The two row subtitles were reworded to name the accepted notations, but
  // the generated search index was not regenerated - on the (wrong) belief
  // that only `title:` is indexed. The generator's `title:` pattern has no
  // left word boundary, so `subtitle:` is indexed too, and the index kept the
  // DELETED wording. That cost the new capability its discoverability AND left
  // 'Positive for East, negative for West' in the index as a row-shaped term
  // the search offers as a tappable result that no longer exists on the page.
  group('the search index knows what the coordinate rows now accept', () {
    const location = 'location';

    test('DMS entry is findable by name', () {
      final terms = kSettingsSearchTerms[location] ?? const <String>[];
      expect(
        terms.any((t) => t.toLowerCase().contains('dms')),
        isTrue,
        reason: 'searching "DMS" must reach the page that accepts it; rerun '
            'dart run tools/production/settings_search_index_gen.dart',
      );
    });

    test('the deleted subtitles are gone from the index', () {
      final terms = kSettingsSearchTerms[location] ?? const <String>[];
      for (final stale in const [
        'Positive for North, negative for South',
        'Positive for East, negative for West',
      ]) {
        expect(
          terms,
          isNot(contains(stale)),
          reason: 'no row says this any more, so a result naming it opens the '
              'page and marks nothing',
        );
      }
    });
  });

  group('parseSiteAngle', () {
    double? lat(String text) => parseSiteAngle(
          text,
          maxDegrees: 90,
          positiveHemisphere: 'N',
          negativeHemisphere: 'S',
        );
    double? lon(String text) => parseSiteAngle(
          text,
          maxDegrees: 180,
          positiveHemisphere: 'E',
          negativeHemisphere: 'W',
        );

    test('reads the notations a coordinate is quoted in', () {
      expect(lat('44.0582'), closeTo(44.0582, 1e-9));
      expect(lat('44 3 29 N'), closeTo(44.058056, 1e-6));
      expect(lat('44° 3\' 29" N'), closeTo(44.058056, 1e-6));
      expect(lat('N 44 03 29'), closeTo(44.058056, 1e-6));
      expect(lat('44 3 29 S'), closeTo(-44.058056, 1e-6));
      expect(lat('44:03:29'), closeTo(44.058056, 1e-6));
      expect(lat('44 3.5'), closeTo(44.058333, 1e-6));
      expect(lon('121 18 55 W'), closeTo(-121.315278, 1e-6));
      expect(lon('-121.3153'), closeTo(-121.3153, 1e-9));
      expect(lon('121.3153 E'), closeTo(121.3153, 1e-9));
    });

    test('the seconds marker is not read as South', () {
      // "44d03m29s" is a full degrees/minutes/seconds spelling with no
      // hemisphere in it; reading its trailing s as South would put the site
      // in the wrong hemisphere without saying so.
      expect(lat('44d03m29s'), closeTo(44.058056, 1e-6));
      expect(lat('44 3 29 s'), closeTo(-44.058056, 1e-6));
    });

    test('a hemisphere written AFTER a d/m/s triple is still a hemisphere', () {
      // "44d03m29s S" must not read as +44.058: taking the trailing S for a
      // second seconds marker — the string already uses d/m unit letters —
      // stores the site 88 degrees away in the wrong hemisphere. A seconds
      // marker is glued to its digits; a hemisphere stands alone.
      expect(lat('44d03m29s S'), closeTo(-44.058056, 1e-6));
      expect(lat('44d03m29s N'), closeTo(44.058056, 1e-6));
      expect(lat('44d03m29 S'), closeTo(-44.058056, 1e-6));
      // ...without breaking the case it was written for.
      expect(lat('44d03m29s'), closeTo(44.058056, 1e-6));
      expect(lat('S44d03m29s'), closeTo(-44.058056, 1e-6));
    });

    test('refuses what it cannot read rather than guessing', () {
      expect(lat(''), isNull);
      expect(lat('Bend, Oregon'), isNull);
      expect(lat('91 0 0 N'), isNull, reason: 'past the pole');
      expect(lon('181'), isNull);
      expect(lat('44 75 0 N'), isNull, reason: '75 arcminutes is not an angle');
      expect(lat('-44 N'), isNull, reason: 'sign and hemisphere disagree');
      expect(lat('44 3 29 12 N'), isNull, reason: 'four components');
      expect(lat('44 3.5 29 N'), isNull, reason: 'fraction before the last');
      expect(lat('121 18 55 W'), isNull, reason: 'W is not a latitude');
    });
  });
}
