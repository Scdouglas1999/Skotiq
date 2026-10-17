// Importing a horizon must not quietly throw most of the file away.
//
// Live: a 36-point .hor (one sample every 10° of azimuth) imported with the
// snackbar "Horizon profile imported from test36.hor" and eight compass fields
// that were exactly the MAXIMUM sample in each 45° sector — the other 28
// samples were discarded with no mention anywhere in the UI. A single 29° tree
// at azimuth 190 therefore marked 157.5°–202.5° as blocked, and the planner
// refused targets that were plainly clear, on exactly the southern sky a
// horizon survey is taken for.
//
// The samples are now kept and interpolated; the eight fields are the sector
// summary the settings page edits. These tests pin both halves: the stored
// profile answers at the file's resolution, and the UI says which of the two
// models is in force.
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// 36 samples, one every 10° of azimuth: flat 5° except a 29° obstruction at
/// azimuth 190, which sits inside the S sector (157.5°–202.5°).
String _thirtySixSamples() {
  final lines = <String>['# test horizon'];
  for (var az = 0; az < 360; az += 10) {
    lines.add('$az ${az == 190 ? 29 : 5}');
  }
  return '${lines.join('\n')}\n';
}

/// A mask the operator already tuned by hand; an import must not overwrite it
/// without being accepted first.
const _existingMask = '{"N":40.0,"NE":40.0,"E":40.0,"SE":40.0,'
    '"S":40.0,"SW":40.0,"W":40.0,"NW":40.0}';

Future<HarnessHandle> _pumpImport(
  WidgetTester tester, {
  String? existingProfileJson,
  String? content,
}) async {
  final handle = await pumpAppScreen(
    tester,
    const LocationSettingsPage(),
    size: const Size(1280, 1000),
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          AppSettingsState(
            horizonProfileJson: existingProfileJson ?? _existingMask,
          ),
        ),
      ),
      horizonImportPickerProvider.overrideWithValue(
        () async => XFile('/tmp/test36.hor'),
      ),
      horizonImportReaderProvider.overrideWithValue(
        (file) async => content ?? _thirtySixSamples(),
      ),
    ],
  );
  final button = find.text('Import .hor / CSV');
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await _advance(tester);
  return handle;
}

/// The import button spins for as long as the flow is in flight — including
/// while the confirmation dialog waits for an answer — so `pumpAndSettle`
/// never returns here. Advance by hand instead.
Future<void> _advance(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the import states the sample count and what it keeps',
      (tester) async {
    await _pumpImport(tester);

    expect(find.textContaining('36 samples read'), findsOneWidget);
    expect(
      find.textContaining('All 36 are stored and interpolated'),
      findsOneWidget,
    );
    // The eight fields are named as a summary, and the one edit that throws
    // the survey away is named too.
    expect(
      find.textContaining('Summarised on this page'),
      findsOneWidget,
    );
    expect(
      find.textContaining('replaces the imported skyline'),
      findsOneWidget,
    );
  });

  testWidgets('the import shows the eight values it is about to store',
      (tester) async {
    await _pumpImport(tester);

    // One 29° obstruction at azimuth 190 becomes the whole S sector.
    expect(find.text('S 29°'), findsOneWidget);
    expect(find.text('SE 5°'), findsOneWidget);
    expect(find.text('SW 5°'), findsOneWidget);
    expect(find.text('N 5°'), findsOneWidget);
  });

  testWidgets('cancelling leaves the existing mask untouched', (tester) async {
    final handle = await _pumpImport(tester);

    await tester.tap(find.text('Cancel'));
    await _advance(tester);

    final stored = LegacyHorizonProfile.fromJson(
      handle.container.read(appSettingsProvider).value!.horizonProfileJson,
    );
    expect(stored.altitudeAt('S'), 40);
    expect(stored.altitudeAt('N'), 40);
    expect(find.text('Import .hor / CSV'), findsOneWidget);
  });

  testWidgets('accepting stores the whole survey, not just the eight sectors',
      (tester) async {
    final handle = await _pumpImport(tester);

    await tester.tap(find.text('Import'));
    await _advance(tester);

    final stored = LegacyHorizonProfile.fromJson(
      handle.container.read(appSettingsProvider).value!.horizonProfileJson,
    );
    // The summary still reads as the per-sector maximum.
    expect(stored.altitudeAt('S'), 29);
    expect(stored.altitudeAt('N'), 5);

    // ...but the profile the planner and the sky chart query answers at the
    // file's resolution. The 29° tree sits at azimuth 190; azimuth 160 and
    // 200 are 5° in the file and used to come back 29° because the whole S
    // sector (157.5°-202.5°) inherited the tallest sample in it.
    expect(stored.sampleCount, 36);
    expect(stored.altitudeAtAzimuth(190), closeTo(29, 0.01));
    expect(
      stored.altitudeAtAzimuth(160),
      closeTo(5, 0.01),
      reason: 'a target at azimuth 160 is clear in the imported file',
    );
    expect(stored.altitudeAtAzimuth(220), closeTo(5, 0.01));
    // Between samples it interpolates rather than stepping.
    expect(stored.altitudeAtAzimuth(185), closeTo(17, 0.5));

    expect(
      find.textContaining('36 samples stored'),
      findsOneWidget,
    );
  });

  testWidgets('a single-sample file is stored as a flat horizon',
      (tester) async {
    await _pumpImport(tester, content: '180 21\n');

    expect(find.textContaining('1 sample read'), findsOneWidget);
    expect(find.textContaining('flat horizon'), findsOneWidget);
  });

  testWidgets('the page says which horizon model is in force', (tester) async {
    final handle = await _pumpImport(tester);
    await tester.tap(find.text('Import'));
    await _advance(tester);
    await tester.pump();

    expect(
      find.textContaining('An imported survey of 36 samples is in use'),
      findsOneWidget,
    );
    expect(
      find.textContaining('are the whole mask'),
      findsNothing,
      reason: 'the coarse-mask wording would be untrue with a survey loaded',
    );

    // Editing a compass field is an explicit override: the survey goes, and
    // the page has to stop claiming one is in use.
    final northField = find.descendant(
      of: find
          .ancestor(
            of: find.text('N (0°)'),
            matching: find.byType(Row),
          )
          .first,
      matching: find.byType(SettingsNumberInput),
    );
    await tester.ensureVisible(northField.first);
    await tester.pump();
    await tester.enterText(northField.first, '12');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _advance(tester);

    final stored = LegacyHorizonProfile.fromJson(
      handle.container.read(appSettingsProvider).value!.horizonProfileJson,
    );
    expect(
      stored.sampleCount,
      0,
      reason: 'the eight fields are now the whole mask again',
    );
    expect(stored.altitudeAt('N'), 12);
    expect(
      find.textContaining('are the whole mask'),
      findsOneWidget,
    );
  });
}
