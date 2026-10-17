import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  testWidgets('desktop minimums shrink to fit a phone viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BoxConstraints constraints;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            constraints = Responsive.dialogConstraints(
              context,
              preferredWidth: 560,
              preferredHeight: 480,
              minWidth: 400,
              minHeight: 500,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    // 360 * AdaptiveDialogConstraints.defaultWidthFraction: the two
    // dialog-sizing helpers share one fraction, so a Responsive-sized dialog
    // and an AdaptiveDialogConstraints-sized one match at the same design
    // width.
    const expectedWidth = 360 * AdaptiveDialogConstraints.defaultWidthFraction;
    expect(constraints.minWidth, closeTo(expectedWidth, 0.01));
    expect(constraints.maxWidth, closeTo(expectedWidth, 0.01));
    expect(constraints.minHeight, 480);
    expect(constraints.maxHeight, 480);
  });

  testWidgets('all three dialog-sizing helpers agree at the same viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late double fromDialogMaxWidth;
    late BoxConstraints fromResponsive;
    late BoxConstraints fromAdaptive;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            fromDialogMaxWidth = dialogMaxWidth(context, 900);
            fromResponsive = Responsive.dialogConstraints(
              context,
              preferredWidth: 900,
            );
            fromAdaptive = AdaptiveDialogConstraints.hybrid(
              context,
              designMaxWidth: 900,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(fromResponsive.maxWidth, closeTo(fromDialogMaxWidth, 0.01));
    expect(fromAdaptive.maxWidth, closeTo(fromDialogMaxWidth, 0.01));
  });

  testWidgets('minimums remain unchanged when the viewport has room', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late BoxConstraints constraints;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            constraints = Responsive.dialogConstraints(
              context,
              preferredWidth: 560,
              preferredHeight: 480,
              minWidth: 400,
              minHeight: 300,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(constraints.minWidth, 400);
    expect(constraints.maxWidth, 560);
    expect(constraints.minHeight, 300);
    expect(constraints.maxHeight, 480);
  });
}
