// A stored horizon that is not valid JSON is read for what it holds, or as a
// flat horizon, which lowers every plan's altitude floor. Location settings
// says so; a readable horizon shows no notice.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/location_settings.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

Future<void> _pump(WidgetTester tester, String horizonJson) async {
  await pumpAppScreen(
    tester,
    const LocationSettingsPage(),
    size: const Size(1280, 1000),
    extraOverrides: [
      appSettingsProvider.overrideWith(
        () => _StubAppSettingsNotifier(
          AppSettingsState(horizonProfileJson: horizonJson),
        ),
      ),
    ],
  );
  await tester.pump();
}

const _notice = 'The stored horizon could not be read';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('an unreadable stored horizon is reported on the page', (
    tester,
  ) async {
    await _pump(tester, '{"N": 12, "E": 20, "samples": [[0, 5], [90');
    expect(find.textContaining(_notice), findsOneWidget);
  });

  testWidgets('a readable horizon shows no notice', (tester) async {
    await _pump(
        tester,
        '{"N":5.0,"NE":0,"E":0,"SE":0,"S":0,"SW":0,"W":0,'
        '"NW":0}');
    expect(find.textContaining(_notice), findsNothing);
  });
}
