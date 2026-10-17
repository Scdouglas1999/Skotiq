import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart'
    show standaloneImagesProvider;
import 'package:skotiq_app/screens/analytics/widgets/science_session_summary.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'science source failure stays visible and retryable beside partial metrics',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      var calibrationAttempts = 0;

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionlessCalibrationsProvider.overrideWith((ref) {
              calibrationAttempts++;
              return Stream<List<FramePhotometricCalibrationRow>>.error(
                StateError('calibration store unavailable'),
              );
            }),
            sessionlessTransparencySamplesProvider.overrideWith(
              (ref) => Stream.value(const <TransparencySampleRow>[]),
            ),
            sessionlessFrameQualityMetricsProvider.overrideWith(
              (ref) => Stream.value(
                const <ScienceFrameQualityMetricsRow>[],
              ),
            ),
            standaloneImagesProvider.overrideWith(
              (ref) => Stream.value(const <DbCapturedImage>[]),
            ),
          ],
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: const Scaffold(body: ScienceSessionSummary()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Science summary incomplete'), findsOneWidget);
      expect(
        find.textContaining('Bad state: calibration store unavailable'),
        findsOneWidget,
      );
      expect(find.text('PLATE SOLVES'), findsOneWidget);
      expect(find.text('ZERO POINT'), findsOneWidget);
      expect(find.text('TRANSPARENCY'), findsOneWidget);
      expect(find.text('UNIFORMITY CV'), findsOneWidget);
      expect(calibrationAttempts, 1);

      await tester.tap(find.widgetWithText(TextButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(calibrationAttempts, 2);
    },
  );
}
