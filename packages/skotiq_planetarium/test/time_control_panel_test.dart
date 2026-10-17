import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

void main() {
  testWidgets('compact controls fit a 360 px phone without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 200);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: TimeControlPanel(compact: true),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(TimeControlPanel), findsOneWidget);
    expect(find.byTooltip('Jump to now'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
