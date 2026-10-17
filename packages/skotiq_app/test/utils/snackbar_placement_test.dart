// Snackbars must not paint over the global status bar.
//
// The floating snackbar anchors to the shell Scaffold, and unless something
// lifts it off the 36 dp status bar the shell pins inside that same Scaffold, a
// toast at 1600x900 goes full-bleed across all 1600 px at the window bottom,
// covering the connection chips, save path and clock for its whole lifetime.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/snackbar_helper.dart';
import 'package:skotiq_app/utils/transient_bottom_inset.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// The painted bar, not the SnackBar element: a floating snackbar's outermost
/// render box is the [Padding] that carries its margin, so measuring the
/// SnackBar itself always reports the full window width.
Rect _barRect(WidgetTester tester) => tester.getRect(
      find
          .descendant(
            of: find.byType(SnackBar),
            matching: find.byType(Material),
          )
          .first,
    );

Future<BuildContext> _pumpHost(WidgetTester tester, {Widget? body}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark,
      home: Scaffold(
        body: Builder(
          builder: (context) {
            captured = context;
            return body ?? const SizedBox.expand();
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  setUp(() => TransientBottomInset.currentInset.value = 0);

  testWidgets(
      'baseline: an unmargined floating snackbar is the reported defect',
      (tester) async {
    // What every helper produced at HEAD (margin was null unless the screen
    // declared an inset). Kept as the measured statement of the defect: 1570 px
    // wide, bottom 10 px off the window edge, i.e. straight over the 36 dp
    // status bar.
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final context = await _pumpHost(tester);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Glance mode on')));
    await tester.pumpAndSettle();

    final bar = _barRect(tester);
    expect(bar.width, greaterThan(1500));
    expect(bar.bottom, greaterThan(900 - ShellChromeMetrics.statusBarHeight));
  });

  testWidgets('a desktop snackbar clears the status bar and is not full-bleed',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final context = await _pumpHost(tester);
    context
        .showInfoSnackBar('Glance mode on — session readouts use large type.');
    await tester.pumpAndSettle();

    final bar = _barRect(tester);
    // Was 1600 px wide, bottom flush with the window.
    expect(bar.width, lessThan(600),
        reason: 'a routine toast must not span the whole window');
    expect(
      bar.bottom,
      lessThanOrEqualTo(900 - ShellChromeMetrics.statusBarHeight),
      reason: 'the global status bar must stay readable while a toast is up',
    );
  });

  testWidgets('a screen-declared bottom bar still wins over the shell chrome',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // The Imaging screen declares the distance from its capture strip's top
    // edge to the window bottom; that already includes the status bar.
    TransientBottomInset.currentInset.value = 140;
    final context = await _pumpHost(tester);
    context.showErrorSnackBar('Capture failed');
    await tester.pumpAndSettle();

    final bar = _barRect(tester);
    expect(bar.bottom, lessThanOrEqualTo(900 - 140));
  });

  testWidgets('a narrow window keeps the near-full-width bar', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final context = await _pumpHost(tester);
    context.showInfoSnackBar('Saved');
    await tester.pumpAndSettle();

    final bar = _barRect(tester);
    expect(bar.left, closeTo(15, 0.5));
    expect(bar.right, closeTo(405, 0.5));
  });
}
