import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planner/widgets/planning_risks_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The resolution chain has its own tests in `skotiq_core`; these pump the
/// chain's OUTPUT so the banner and the provenance row are what is under test.
/// Standing a real database up here would also hand the test a live settings
/// stream whose timer outlives the widget tree.
ResolvedCameraSensorSpecs _resolved(String? cameraName, {int? gain}) =>
    CameraSensorSpecResolver().resolve(
      CameraSensorSpecInputs(cameraName: cameraName, gain: gain),
    );

/// The camera the owner reported the defect from, with nothing connected: only
/// the published specification can answer for it.
final _ownersCamera = _resolved('ASI1600MM-Cool', gain: 139);

/// A camera no manufacturer here publishes.
final _unknownCamera = _resolved('Acme SkyCam 9000');

Future<void> _pump(
  WidgetTester tester, {
  required List<String> riskFactors,
  required ResolvedCameraSensorSpecs specs,
  Widget? child,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeCameraSensorSpecsProvider.overrideWith((ref) async => specs),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: child ?? PlanningRisksBanner(riskFactors: riskFactors),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlanningRisksBanner', () {
    testWidgets('a non-sensor risk is said as the scorer said it', (
      tester,
    ) async {
      await _pump(
        tester,
        specs: _ownersCamera,
        riskFactors: const [
          'Moon separation is tight; gradients or contrast loss are more '
              'likely.',
        ],
      );
      expect(
        find.textContaining('Moon separation is tight'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('planner_sensor_specs_banner')),
          findsNothing);
    });

    testWidgets(
        'several sensor caveats collapse into one banner that names '
        'the camera', (tester) async {
      await _pump(
        tester,
        specs: _unknownCamera,
        riskFactors: [
          for (final field in [
            SensorSpecField.readNoise,
            SensorSpecField.fullWell,
            SensorSpecField.qePeak,
          ])
            sensorSpecCaveat(
              field: field,
              cameraLabel: 'Acme SkyCam 9000',
              estimate: 'an estimate',
            ),
        ],
      );

      expect(
        find.byKey(const ValueKey('planner_sensor_specs_banner')),
        findsOneWidget,
      );
      // ONE banner, and it names the camera it could not identify.
      expect(find.byType(SkotiqBanner), findsOneWidget);
      expect(
        find.textContaining('Acme SkyCam 9000'),
        findsWidgets,
      );
      // Geometry came off nothing either, so every field is listed.
      expect(find.textContaining('pixel size'), findsWidgets);
      // And the one action that fixes it is offered.
      expect(find.text('Enter camera specs'), findsOneWidget);
    });

    testWidgets(
        'a non-sensor risk rides on the sensor banner rather than '
        'becoming a second one', (tester) async {
      await _pump(
        tester,
        specs: _unknownCamera,
        riskFactors: [
          sensorSpecCaveat(
            field: SensorSpecField.readNoise,
            cameraLabel: 'Acme SkyCam 9000',
            estimate: 'an estimate',
          ),
          'Usable imaging window is short.',
        ],
      );
      expect(find.byType(SkotiqBanner), findsOneWidget);
      expect(
        find.textContaining('Usable imaging window is short.'),
        findsOneWidget,
      );
    });

    testWidgets('a profile with no camera says that, not "specs unknown"', (
      tester,
    ) async {
      await _pump(
        tester,
        specs: ResolvedCameraSensorSpecs.none,
        riskFactors: [
          sensorSpecCaveat(
            field: SensorSpecField.pixelSize,
            cameraLabel: 'this camera',
            estimate: 'an estimate',
          ),
        ],
      );
      expect(
        find.textContaining('This profile has no camera'),
        findsOneWidget,
      );
    });

    testWidgets('an empty risk list renders nothing', (tester) async {
      await _pump(tester, specs: _ownersCamera, riskFactors: const []);
      expect(find.byType(SkotiqBanner), findsNothing);
    });

    testWidgets('the field list reads as a sentence, capitalised', (
      tester,
    ) async {
      // The owner's camera resolves everything from the published
      // specification except nothing — so use one that is missing exactly one
      // field: ZWO publishes no usable read noise for the ASI533MM Pro.
      await _pump(
        tester,
        specs: _resolved('ASI533MM Pro', gain: 100),
        riskFactors: [
          sensorSpecCaveat(
            field: SensorSpecField.readNoise,
            cameraLabel: 'ZWO ASI533MM Pro',
            estimate: 'an estimate',
          ),
        ],
      );
      expect(
        find.textContaining('Read noise is not published for ZWO ASI533MM Pro'),
        findsOneWidget,
      );
    });

    testWidgets('a malformed override is reported as its own problem', (
      tester,
    ) async {
      await _pump(
        tester,
        specs: _ownersCamera,
        riskFactors: const [unreadableSensorOverridesCaveat],
      );
      // It is a sensor caveat, so it collapses into the sensor banner rather
      // than printing beside one.
      expect(find.byType(SkotiqBanner), findsOneWidget);
    });
  });

  group('CameraSensorSpecsRow', () {
    testWidgets('states the resolved values and where they came from', (
      tester,
    ) async {
      await _pump(
        tester,
        specs: _ownersCamera,
        riskFactors: const [],
        child: const CameraSensorSpecsRow(),
      );

      // This is the answer to the owner's report: the Plan screen states the
      // ASI1600MM's published figures instead of calling them unknown.
      expect(
        find.text(
          '3.8 µm · 4656 × 3520 · 1.2 e⁻ read noise · 20,000 e⁻ well · 60% QE',
        ),
        findsOneWidget,
      );
      expect(find.text('Published specs'), findsOneWidget);
      expect(find.text('Camera sensor'), findsOneWidget);
    });

    testWidgets('says nothing when nothing resolved', (tester) async {
      await _pump(
        tester,
        specs: _unknownCamera,
        riskFactors: const [],
        child: const CameraSensorSpecsRow(),
      );
      expect(find.text('Camera sensor'), findsNothing);
    });

    testWidgets('says nothing when there is no camera at all', (tester) async {
      await _pump(
        tester,
        specs: ResolvedCameraSensorSpecs.none,
        riskFactors: const [],
        child: const CameraSensorSpecsRow(),
      );
      expect(find.text('Camera sensor'), findsNothing);
    });

    testWidgets('the row is one activatable node that reads its provenance', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await _pump(
        tester,
        specs: _ownersCamera,
        riskFactors: const [],
        child: const CameraSensorSpecsRow(),
      );

      // ONE node for the whole row, not one per figure, and it reads the
      // values AND where each came from — including the gain ZWO quotes the
      // read noise at, which is the clause a reader can be misled by.
      expect(
        find.bySemanticsLabel(
          'Camera sensor specs for ZWO ASI1600MM: '
          '3.8 µm · 4656 × 3520 · 1.2 e⁻ read noise · 20,000 e⁻ well · 60% QE. '
          'Pixel size: the published pixel pitch for ZWO ASI1600MM. '
          'Sensor width and sensor height: the published resolution for '
          'ZWO ASI1600MM. '
          'Read noise: the published figure for ZWO ASI1600MM, which the '
          'manufacturer quotes only at 30 dB gain. '
          'Full well: the published figure for ZWO ASI1600MM, which the '
          'manufacturer quotes with no gain stated. '
          'QE: the published peak QE for ZWO ASI1600MM. '
          'Activate to correct them.',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });
  });
}
