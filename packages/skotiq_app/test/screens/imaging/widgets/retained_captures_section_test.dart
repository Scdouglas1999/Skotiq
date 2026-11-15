// The camera panel's "Kept on the camera" section: absent with nothing kept,
// one row per kept capture, and Retrieve reads it off the camera.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/imaging/widgets/retained_captures_section.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../../harness/harness.dart';

RetainedCapture _kept({bool inMemory = false}) => RetainedCapture(
      deviceId: 'native:gphoto2:0',
      cameraName: 'X-T5',
      location: '/store_10000001/DCIM/100_FUJI/DSCF0042.RAF',
      inCameraMemory: inMemory,
      reason: 'the download failed',
      retainedAt: DateTime.utc(2026, 11, 15, 3),
    );

Future<void> _pump(WidgetTester tester, MockBackend backend) async {
  await pumpAppScreen(
    tester,
    const Scaffold(
      body: RetainedCapturesSection(colors: SkotiqColors.dark),
    ),
    backend: backend,
    settle: false,
  );
  for (var i = 0; i < 4; i++) {
    await tester.pump();
  }
}

void main() {
  testWidgets('nothing is shown while no capture is kept', (tester) async {
    await _pump(tester, mockBackend());
    expect(find.text('Kept on the camera'), findsNothing);
  });

  testWidgets('a kept capture is listed with where it is and retrieved on tap',
      (tester) async {
    final backend = mockBackend();
    var kept = [_kept()];
    when(() => backend.cameraRetainedCaptures()).thenAnswer((_) async => kept);
    when(
      () => backend.cameraRetrieveRetainedCapture(any(), any()),
    ).thenAnswer((_) async {
      kept = [];
      return '/data/retained_captures/20261115-030000_DSCF0042.RAF';
    });
    await _pump(tester, backend);

    expect(find.text('Kept on the camera'), findsOneWidget);
    expect(find.text('DSCF0042.RAF'), findsOneWidget);
    expect(
      find.text(
        "On the camera's card: /store_10000001/DCIM/100_FUJI/DSCF0042.RAF",
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Retrieve'));
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
    verify(
      () => backend.cameraRetrieveRetainedCapture(
        'native:gphoto2:0',
        '/store_10000001/DCIM/100_FUJI/DSCF0042.RAF',
      ),
    ).called(1);
    expect(
      find.textContaining('20261115-030000_DSCF0042.RAF'),
      findsOneWidget,
      reason: 'the user is told where the file was saved',
    );
    expect(find.text('Kept on the camera'), findsNothing);
  });

  testWidgets('a capture in the camera\'s memory says it can be replaced',
      (tester) async {
    final backend = mockBackend();
    when(
      () => backend.cameraRetainedCaptures(),
    ).thenAnswer((_) async => [_kept(inMemory: true)]);
    await _pump(tester, backend);
    expect(find.textContaining("In the camera's memory"), findsOneWidget);
  });
}
