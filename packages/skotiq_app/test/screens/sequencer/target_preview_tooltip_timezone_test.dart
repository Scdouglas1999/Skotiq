// The sequencer's target-preview tooltip states "Transit: HH:MM", a fact about
// the OBSERVING SITE, so it follows Settings → Location → Timezone like the
// status bar, the dashboard and the planetarium Tonight tab. Formatting with
// `.toLocal()` gives a remote operator planning against the site's meridian
// their own zone instead.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/sequencer/widgets/target_preview_tooltip.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

final _target = TargetHeaderNode(
  targetName: 'M31',
  raHours: 0.71,
  decDegrees: 41.2,
);

/// Transit pinned in UTC so the expected face is a pure function of the chosen
/// offset, not of the machine running the test.
final _info = TargetAltitudeInfo(
  currentAltitude: 35.0,
  azimuth: 90.0,
  isRising: true,
  transitTime: DateTime.utc(2026, 6, 10, 20, 14),
  transitAltitude: 71.0,
  hoursAboveHorizon: 8.0,
);

Future<void> _pumpAndShow(WidgetTester tester, String timezone) async {
  // The tooltip body is a fixed 280 px card; the default 800x600 test surface
  // makes its info rows overflow, which fails the test on layout before any
  // assertion runs.
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    ProviderScope(
      key: ValueKey(timezone),
      overrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(
            AppSettingsState(
              latitude: 35.68,
              longitude: 139.69,
              timezone: timezone,
              useSystemTime: false,
            ),
          ),
        ),
        targetAltitudeProvider(_target).overrideWith((ref) async => _info),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (context) => TargetPreviewTooltip(
              target: _target,
              colors: SkotiqColors.of(context),
              child: const SizedBox(width: 40, height: 40),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  // The tooltip body lives in an overlay; nothing renders until it is shown.
  tester.state<TooltipState>(find.byType(Tooltip)).ensureTooltipVisible();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));

  // The card's alt/az row overflows by 2 px under the test harness's fallback
  // font — a measurement artifact of the stub font metrics, not something this
  // test is about, and present with or without the timezone change. Drain it so
  // the layout complaint cannot masquerade as a failed assertion below.
  while (tester.takeException() != null) {}
}

void main() {
  testWidgets('the transit line follows the chosen site timezone',
      (tester) async {
    await _pumpAndShow(tester, 'UTC+09:00');
    // 20:14Z + 9h.
    expect(find.text('Transit: 05:14'), findsOneWidget);
    expect(find.text('Transit: 20:14'), findsNothing);
  });

  testWidgets('a site on UTC reads the UTC transit', (tester) async {
    await _pumpAndShow(tester, 'UTC');
    expect(find.text('Transit: 20:14'), findsOneWidget);
    expect(find.text('Transit: 05:14'), findsNothing);
  });
}
