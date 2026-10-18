// The polar alignment screen at the owner's 1920x1080 desktop.
//
// What the tightening pass fixed, pinned:
//  * the method tabs and the device chips rode a second 60px row under the
//    header — they belong in the header row itself;
//  * the outer 120" ring's label was cut off at the right edge of its column,
//    and the Total readout's label sat lower than Azimuth's and Altitude's;
//  * the setup checklist told the operator to connect a camera and a mount
//    that were already connected;
//  * a fixed 120" target pinned every larger error to its rim, so on a mount
//    set up by eye the marker did not move while the operator turned a bolt.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/screens/polar_alignment/polar_alignment_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'package:skotiq_app/widgets/tutorial_keys/polar_alignment_keys.dart';

import '../../harness/pump_app_screen.dart';

/// The screen's share of a 1920x1080 window: the navigation rail and the top
/// bar take the rest.
const Size _desktop = Size(1646, 960);

class _SiteSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40, longitude: -75);
}

class _Camera extends CameraStateNotifier {
  _Camera(super.ref, DeviceConnectionState connection) {
    // ignore: invalid_use_of_protected_member
    state = CameraStateSnapshot(connectionState: connection);
  }
}

class _Mount extends MountStateNotifier {
  _Mount(super.ref, DeviceConnectionState connection) {
    // ignore: invalid_use_of_protected_member
    state = MountState(connectionState: connection, isParked: false);
  }
}

GoRouter _router() => GoRouter(
      initialLocation: '/polar-alignment',
      routes: [
        GoRoute(
          path: '/polar-alignment',
          builder: (_, __) => const PolarAlignmentScreen(),
        ),
      ],
    );

Future<HarnessHandle> _pump(
  WidgetTester tester, {
  Size size = _desktop,
  bool connected = true,
}) async {
  final connection = connected
      ? DeviceConnectionState.connected
      : DeviceConnectionState.disconnected;
  final handle = await pumpAppScreen(
    tester,
    MaterialApp.router(theme: SkotiqTheme.dark, routerConfig: _router()),
    size: size,
    settle: false,
    extraOverrides: [
      appSettingsProvider.overrideWith(_SiteSettings.new),
      cameraStateProvider.overrideWith((ref) => _Camera(ref, connection)),
      mountStateProvider.overrideWith((ref) => _Mount(ref, connection)),
      plateSolverDetectionProvider.overrideWith(
        (ref) async => const PlateSolverDetection(
          astapPath: '/opt/astap/astap',
          catalogPath: '/opt/astap',
        ),
      ),
      plateSolverPreferenceProvider.overrideWith(
        (ref) async =>
            const PlateSolverPreference(choice: PlateSolverChoice.astap),
      ),
    ],
  );
  await tester.pump(const Duration(milliseconds: 200));
  return handle;
}

SkotiqEvent _status(String phase, String status, int point) => SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.polarAlignment,
      eventType: 'PolarAlignmentStatus',
      data: {'phase': phase, 'status': status, 'point': point},
    );

SkotiqEvent _error(double az, double alt) => SkotiqEvent(
      timestamp: 0,
      severity: EventSeverity.info,
      category: EventCategory.polarAlignment,
      eventType: 'PolarAlignment',
      data: {
        'azimuth_error': az,
        'altitude_error': alt,
        'total_error':
            (az * az + alt * alt) == 0 ? 0.0 : Offset(az, alt).distance,
      },
    );

void main() {
  testWidgets('the method tabs and device chips share the header row',
      (tester) async {
    await _pump(tester);

    final header = tester.getRect(find.byType(PageHeader));
    // The header row, plus at most its hairline on a touch platform: no
    // second row under it.
    expect(
      header.height,
      lessThanOrEqualTo(ShellChromeMetrics.pageHeaderHeight + 1),
      reason: 'no second row under the header',
    );
    for (final label in ['TPPA', 'All-sky', 'Camera', 'Mount', 'History']) {
      final rect = tester.getRect(find.text(label));
      expect(
        rect.top >= header.top && rect.bottom <= header.bottom,
        isTrue,
        reason: '$label sits in the header row ($rect, header $header)',
      );
    }
    // The way back is a labelled action, not a bare arrow beside History.
    expect(find.widgetWithText(SkotiqButton, 'Back'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the connect step is done when both devices are connected',
      (tester) async {
    await _pump(tester);

    final checklist = tester.widget<Checklist>(find.byType(Checklist));
    final connect = checklist.steps
        .singleWhere((s) => s.title == 'Connect the camera and the mount');
    expect(connect.state, ChecklistStepState.done);
    // Pointing cannot be verified from here, so those steps stay open.
    expect(
      checklist.steps.where((s) => s.state == ChecklistStepState.done),
      hasLength(1),
    );
  });

  testWidgets('the connect step stays open while a device is disconnected',
      (tester) async {
    await _pump(tester, connected: false);

    final checklist = tester.widget<Checklist>(find.byType(Checklist));
    final connect = checklist.steps
        .singleWhere((s) => s.title == 'Connect the camera and the mount');
    expect(connect.state, ChecklistStepState.todo);
  });

  testWidgets(
      'the instructions are stated once, in the settings column, and the '
      'bullseye has the rest of the width', (tester) async {
    await _pump(tester);

    expect(find.text('Three-point polar alignment'), findsOneWidget);
    expect(find.textContaining('After you start, this bullseye'), findsNothing);

    final checklist = tester.getRect(find.byType(Checklist));
    final essential = tester.getRect(find.text('Essential'));
    expect(
      (checklist.left - essential.left).abs() < 40 &&
          checklist.bottom < essential.top,
      isTrue,
      reason: 'the checklist heads the settings column',
    );
    expect(
      tester.getRect(find.byKey(PolarAlignmentTutorialKeys.errorDisplay)).width,
      greaterThan(_desktop.width / 2),
      reason: 'with nothing running the error display takes the centre too',
    );
  });

  testWidgets('the bullseye and its readouts fit at 1920x1080', (tester) async {
    await _pump(tester);
    expect(tester.takeException(), isNull);

    final display = find.byKey(PolarAlignmentTutorialKeys.errorDisplay);
    final paint = find.descendant(
      of: display,
      matching: find.byWidgetPredicate(
        (w) =>
            w is CustomPaint &&
            w.painter.runtimeType.toString() == '_PolarErrorPainter',
      ),
    );
    expect(paint, findsOneWidget);
    final area = tester.getRect(paint);
    final label = TextPainter(
      text: const TextSpan(text: '120"', style: kPolarBullseyeLabelStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final radius = polarBullseyeOuterRadius(area.size, label.width);
    expect(radius, greaterThan(150),
        reason: 'the target is not a postage stamp');
    final labelRight =
        area.center.dx + radius + kPolarBullseyeLabelGap + label.width;
    final column = tester.getRect(display);
    expect(labelRight, lessThanOrEqualTo(column.right),
        reason: 'the 120" label is inside its column');
    expect(area.center.dy + radius, lessThanOrEqualTo(area.bottom));

    final az = tester.getRect(find.text('AZIMUTH'));
    final alt = tester.getRect(find.text('ALTITUDE'));
    final total = tester.getRect(find.text('TOTAL'));
    expect(alt.bottom, az.bottom, reason: 'labels share a baseline');
    expect(total.bottom, az.bottom, reason: 'Total is not lower');
    expect(total.bottom, lessThanOrEqualTo(_desktop.height),
        reason: 'the readout row is on screen without scrolling');
  });

  testWidgets('the all-sky reticle leaves its readouts on screen too',
      (tester) async {
    await _pump(tester);
    await tester.tap(find.text('All-sky'));
    await tester.pump(const Duration(milliseconds: 200));

    // The reticle used to report its column's width as its height, which in
    // the wide idle column pushed the readout row ~500px below the screen.
    expect(tester.getRect(find.text('TOTAL')).bottom,
        lessThanOrEqualTo(_desktop.height));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a simulated run: the progress rail, the readouts and the bullseye '
      'scale follow every measurement', (tester) async {
    final handle = await _pump(tester);
    final backend = handle.backend;

    backend.emitEvent(_status('measuring', 'Capturing point 1', 1));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Capture 1'), findsOneWidget);
    expect(find.text('Capturing point 1 of 3'), findsOneWidget);
    expect(tester.takeException(), isNull);

    backend.emitEvent(_status('measuring', 'Plate solving point 3', 3));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Plate solving point 3 of 3'), findsOneWidget);

    backend.emitEvent(_status('adjusting', 'Adjusting', 0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Adjust mount'), findsOneWidget);
    // The rail's last step is on screen, not cut off at the column edge.
    final adjustStep = tester.getRect(find.text('Adjust').first);
    final display =
        tester.getRect(find.byKey(PolarAlignmentTutorialKeys.errorDisplay));
    expect(adjustStep.right, lessThanOrEqualTo(display.left));

    // A first measurement from a mount set up by eye: degrees off.
    backend.emitEvent(_error(-9000, 6000));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text("-2° 30' 00\""), findsOneWidget);
    expect(polarBullseyeOuterScaleArcsec(-9000, 6000), 14400);

    // Turning the bolts: arcminutes, then inside the finest target.
    backend.emitEvent(_error(-300, 200));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text("-5' 00\""), findsOneWidget);
    expect(polarBullseyeOuterScaleArcsec(-300, 200), 600);

    backend.emitEvent(_error(-24, 18));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('-24.0"'), findsOneWidget);
    expect(find.text('30.0"'), findsOneWidget, reason: 'the total');
    expect(polarBullseyeOuterScaleArcsec(-24, 18), 120);
    expect(tester.takeException(), isNull);
  });

  test('ring labels use the unit the operator would say', () {
    expect(polarBullseyeRingLabel(120), '120"');
    expect(polarBullseyeRingLabel(30), '30"');
    expect(polarBullseyeRingLabel(600), "10'");
    expect(polarBullseyeRingLabel(150), "2.5'");
    expect(polarBullseyeRingLabel(14400), '4°');
    expect(polarBullseyeRingLabel(3600), '1°');
  });

  test('the scale contains the marker, and an unmeasured target is 120"', () {
    expect(polarBullseyeOuterScaleArcsec(null, null), 120);
    expect(polarBullseyeOuterScaleArcsec(90, 0), 120);
    expect(polarBullseyeOuterScaleArcsec(100, 100), 240);
    expect(
        polarBullseyeOuterScaleArcsec(1e9, 0), kPolarBullseyeScalesArcsec.last);
  });
}
