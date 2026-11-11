import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_overlays.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('the target card reads typed coordinates back as typed', (
    tester,
  ) async {
    // What "02h 42m 05s / +42 47 00" parses to.
    const target = FramingTarget(
      name: 'Custom Location',
      raHours: 2 + 42 / 60 + 5 / 3600,
      decDegrees: 42 + 47 / 60,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(
          body: FramingTargetInfoOverlay(
            colors: SkotiqColors.dark,
            target: target,
          ),
        ),
      ),
    );

    expect(find.text('02h 42m 05.0s  +42° 47\' 00"'), findsOneWidget);
  });
}
