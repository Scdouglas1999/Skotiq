import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/calibration_library_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _MockCalibrationLibraryService extends Mock
    implements CalibrationLibraryService {}

class _FakeLightFrameContext extends Fake implements LightFrameContext {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    registerFallbackValue(const CalibrationLibraryFilter());
    registerFallbackValue(_FakeLightFrameContext());
  });

  testWidgets('invalid preview fields never reach the master matcher',
      (tester) async {
    final service = _MockCalibrationLibraryService();
    when(
      () => service.listMasters(filter: any(named: 'filter')),
    ).thenAnswer((_) async => const []);

    await pumpAppScreen(
      tester,
      const CalibrationLibrarySettings(),
      size: const Size(1400, 1000),
      settle: false,
      extraOverrides: [
        calibrationLibraryServiceProvider.overrideWithValue(service),
      ],
    );
    await tester.pump();
    await tester.pump();

    final exposureField = find.ancestor(
      of: find.text('Exposure (s)'),
      matching: find.byType(TextField),
    );
    await tester.enterText(exposureField, 'not-a-number');
    await tester
        .tap(find.widgetWithText(FilledButton, 'Preview auto-selection'));
    await tester.pump();

    expect(find.textContaining('Exposure must be a finite number'),
        findsOneWidget);
    verifyNever(() => service.match(any()));
    expect(tester.takeException(), isNull);
  });
}
