import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('hybrid caps width and height to design max on large screens', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(2000, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BoxConstraints constraints;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            constraints = AdaptiveDialogConstraints.hybrid(
              context,
              designMaxWidth: 960,
              designMaxHeight: 720,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(constraints.maxWidth, 960);
    expect(constraints.maxHeight, 720);
  });

  testWidgets('hybrid shrinks below design max on narrow viewports', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BoxConstraints constraints;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            constraints = AdaptiveDialogConstraints.hybrid(
              context,
              designMaxWidth: 960,
              designMaxHeight: 720,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(constraints.maxWidth, closeTo(800 * 0.92, 0.01));
    expect(constraints.maxHeight, closeTo(600 * 0.85, 0.01));
  });

  testWidgets('clampPanelWidth respects viewport cap', (tester) async {
    tester.view.physicalSize = const Size(600, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late double panelWidth;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            panelWidth = AdaptiveDialogConstraints.clampPanelWidth(
              context,
              designWidth: 340,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(panelWidth, 240);
  });
}
