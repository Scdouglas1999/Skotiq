// The page that owns the weather-safety master switch showed neither which
// safety sources are attached nor the fail mode that decides what "no source"
// means — the fail-mode selector lived on the Sequencer page, so the operator
// met the consequence of the shipped default only when a run refused to start.
//
// Asserted against WeatherSafetyPolicyRows, the widget the page renders for
// exactly these two rows: pumping the whole WeatherSafetySettings page hangs
// the flutter_test isolate at HEAD too, so it is not a usable seam.

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/weather_safety_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Future<HarnessHandle> _pump(
  WidgetTester tester, {
  SafetySourceReading weather = SafetySourceReading.absent,
  SafetySourceReading monitor = SafetySourceReading.absent,
  String? failMode,
  bool masterEnabled = true,
}) async {
  final database = mockDatabase();
  addTearDown(database.close);
  if (failMode != null) {
    await database.settingsDao.setSetting('safety_fail_mode', failMode);
  }
  final handle = await pumpAppScreen(
    tester,
    WeatherSafetyPolicyRows(masterEnabled: masterEnabled),
    database: database,
    extraOverrides: [
      weatherSafetySourceReadingsProvider.overrideWithValue(
        (weather: weather, monitor: monitor),
      ),
    ],
    settle: false,
  );
  await handle.container.read(appSettingsProvider.future);
  await tester.pump();
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a sensorless rig is told so, and what fail-closed does', (
    tester,
  ) async {
    final handle = await _pump(tester);
    addTearDown(handle.container.dispose);

    expect(find.text('Safety sources'), findsOneWidget);
    expect(
      find.textContaining('No weather device or safety monitor is connected'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'With Fail Closed (Park), missing data counts as unsafe: a run will '
        'refuse to start and the rig is parked.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('the fail mode is selectable on this page', (tester) async {
    final handle = await _pump(tester);
    addTearDown(handle.container.dispose);

    expect(find.text('Safety fail mode'), findsOneWidget);
    expect(find.text('Fail Closed (Park)'), findsWidgets);
  });

  testWidgets('a permissive fail mode states its own consequence', (
    tester,
  ) async {
    final handle = await _pump(tester, failMode: 'failOpen');
    addTearDown(handle.container.dispose);

    expect(
      find.textContaining(
        'With Fail Open (Continue), missing data counts as safe',
      ),
      findsOneWidget,
    );
  });

  testWidgets('connected sources are reported by their reading', (
    tester,
  ) async {
    final handle = await _pump(
      tester,
      weather: SafetySourceReading.safe,
      monitor: SafetySourceReading.unknown,
    );
    addTearDown(handle.container.dispose);

    expect(
      find.textContaining(
        'Weather device: reporting safe · Safety monitor: connected, '
        'not reporting',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('No weather device or safety monitor is connected'),
      findsNothing,
    );
  });

  testWidgets('with the master switch off the rows do not read as protection', (
    tester,
  ) async {
    final handle = await _pump(tester, masterEnabled: false);
    addTearDown(handle.container.dispose);

    expect(
      find.textContaining('inactive until "Enable weather safety" is on'),
      findsOneWidget,
    );
  });
}
