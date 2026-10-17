// Settings → Location presented an unset site as a configured one.
//
// Live repro (release bundle, empty SKOTIQ_DATABASE_DIR, onboarding
// skipped): the first launch writes observer_latitude/longitude/elevation = 0.0
// into `app_settings` and `db/profiles/settings.json` before the user has been
// asked anything, and this page then rendered
//
//     Latitude   0 °     Longitude  0 °     Elevation  0 m
//
// in the same numeric type as a site somebody typed, with no "not set" state
// anywhere on the page. One click away the Dashboard said "Set an observing
// location for twilight times", Weather said "Location Not Configured" and Plan
// Tonight said "Location not configured" — so the app contradicted itself, and
// this page was the surface asserting the fabricated position.
//
// The Sequencer solved the same problem for a Target node's 0h/+0° birth
// coordinates by saying "Not set" over the placeholder instead of printing
// `00h 00m 00s`. This mirrors that.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/location_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

Future<void> _pumpLocation(
  WidgetTester tester, {
  required AppSettingsState settings,
}) async {
  await pumpAppScreen(
    tester,
    const LocationSettingsPage(),
    size: const Size(1280, 1400),
    extraOverrides: [
      appSettingsProvider
          .overrideWith(() => _StubAppSettingsNotifier(settings)),
      isRemoteModeProvider.overrideWithValue(false),
    ],
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a fresh profile says the observing site is not set', (
    tester,
  ) async {
    // Exactly what a first launch persists.
    const fresh = AppSettingsState();
    expect(fresh.hasObserverLocation, isFalse,
        reason: 'fixture must be the real fresh-install state');

    await _pumpLocation(tester, settings: fresh);

    expect(
      // The banner renders its title and message as ONE rich text (05 §11),
      // so the title is a substring of a node, not a node of its own.
      find.textContaining('Observing site not set'),
      findsOneWidget,
      reason: 'the page rendered 0 °/0 °/0 m with no not-set state at all',
    );
    // And it says plainly that the zeros are not a location, rather than
    // leaving the reader to infer it.
    expect(
      find.textContaining('placeholders, not your location'),
      findsOneWidget,
    );
  });

  testWidgets('a configured site does not carry the not-set notice', (
    tester,
  ) async {
    await _pumpLocation(
      tester,
      settings: const AppSettingsState(
        latitude: 44.0581,
        longitude: -121.3153,
        elevation: 1100.0,
      ),
    );

    expect(
        // The banner renders its title and message as ONE rich text (05 §11),
        // so the title is a substring of a node, not a node of its own.
        find.textContaining('Observing site not set'),
        findsNothing);
  });

  testWidgets('a longitude-only site counts as set', (tester) async {
    // The sentinel is the ORIGIN, not "any zero": an observer on the equator
    // with a real longitude has a site, and must not be told otherwise.
    await _pumpLocation(
      tester,
      settings: const AppSettingsState(latitude: 0.0, longitude: -74.0),
    );

    expect(
        // The banner renders its title and message as ONE rich text (05 §11),
        // so the title is a substring of a node, not a node of its own.
        find.textContaining('Observing site not set'),
        findsNothing);
  });
}
