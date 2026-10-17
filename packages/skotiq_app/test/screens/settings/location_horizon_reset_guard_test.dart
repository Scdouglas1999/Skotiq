// "Reset All to 0°" must not throw a horizon survey away on one click.
//
// Live: the Reset button sits on the same row as "Import .hor / CSV", about
// 120 px away, and fired immediately — horizon_profile_json went to all zeros
// with no confirmation, no undo, and no record of the file it came from. A
// misclick beside Import cost the whole skyline, and recovering meant finding
// the .hor again.
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

/// A stored survey: 36 samples plus the eight-sector summary of them.
String _survey() {
  final samples = <String>[];
  for (var az = 0; az < 360; az += 10) {
    samples.add('[$az.00,${az == 190 ? '29.00' : '5.00'}]');
  }
  return '{"N":5.0,"NE":5.0,"E":5.0,"SE":5.0,"S":29.0,"SW":5.0,"W":5.0,'
      '"NW":5.0,"samples":[${samples.join(',')}]}';
}

const _flat = '{"N":0.0,"NE":0.0,"E":0.0,"SE":0.0,"S":0.0,"SW":0.0,"W":0.0,'
    '"NW":0.0}';

const _handTuned = '{"N":40.0,"NE":0.0,"E":0.0,"SE":0.0,"S":0.0,"SW":0.0,'
    '"W":0.0,"NW":0.0}';

Future<HarnessHandle> _pumpReset(
  WidgetTester tester, {
  required String profileJson,
}) async {
  final handle = await pumpAppScreen(
    tester,
    const LocationSettingsPage(),
    size: const Size(1280, 1000),
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          AppSettingsState(horizonProfileJson: profileJson),
        ),
      ),
    ],
  );
  final button = find.text('Reset All to 0°');
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return handle;
}

LegacyHorizonProfile _stored(HarnessHandle handle) {
  return LegacyHorizonProfile.fromJson(
    handle.container.read(appSettingsProvider).value!.horizonProfileJson,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('resetting an imported survey asks before discarding it',
      (tester) async {
    final handle = await _pumpReset(tester, profileJson: _survey());

    expect(find.text('Reset the horizon mask?'), findsOneWidget);
    expect(
      find.textContaining(
        'The imported survey of 36 samples, and the eight sector values',
      ),
      findsOneWidget,
      reason: 'the dialog has to name what is about to be lost',
    );
    // Nothing is written while the question is on screen.
    expect(_stored(handle).sampleCount, 36);
  });

  testWidgets('cancelling the reset keeps the survey', (tester) async {
    final handle = await _pumpReset(tester, profileJson: _survey());

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final stored = _stored(handle);
    expect(stored.sampleCount, 36);
    expect(stored.altitudeAt('S'), 29);
  });

  testWidgets('confirming the reset flattens the horizon', (tester) async {
    final handle = await _pumpReset(tester, profileJson: _survey());

    await tester.tap(find.text('Reset horizon'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final stored = _stored(handle);
    expect(stored.sampleCount, 0);
    for (final dir in horizonDirections) {
      expect(stored.altitudeAt(dir), 0);
    }
  });

  testWidgets('a hand-edited mask is guarded too', (tester) async {
    final handle = await _pumpReset(tester, profileJson: _handTuned);

    expect(find.text('Reset the horizon mask?'), findsOneWidget);
    expect(find.textContaining('eight sector values'), findsOneWidget);
    expect(_stored(handle).altitudeAt('N'), 40);
  });

  testWidgets('an already-flat horizon resets without a question',
      (tester) async {
    final handle = await _pumpReset(tester, profileJson: _flat);

    expect(
      find.text('Reset the horizon mask?'),
      findsNothing,
      reason: 'there is nothing to lose, so the dialog would be noise',
    );
    expect(_stored(handle).altitudeAt('N'), 0);
  });
}
