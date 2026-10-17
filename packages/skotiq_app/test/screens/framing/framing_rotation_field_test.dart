// Framing rotation must be settable EXACTLY.
//
// It was a bare ~117 px slider spanning -180..+180 (about 3.1° per pixel) with a
// read-only degree label: no numeric entry, the label was not an input, and
// arrow keys did nothing because the continuous slider's keyboard step is
// (max-min)/10 = 36°. Rotation is the number an imager dials into a rotator PA,
// so "roughly 86°" is not good enough.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/framing/widgets/framing_controls.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  /// Pumps the control and returns a mutable holder of the last emitted value,
  /// re-rendering on each change the way the provider-backed sidebar does.
  Future<List<double>> pumpField(
    WidgetTester tester, {
    double initial = 0,
    bool enabled = true,
  }) async {
    final emitted = <double>[];
    var value = initial;
    await tester.pumpWidget(
      MaterialApp(
        theme: SkotiqTheme.dark,
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: Builder(
            builder: (context) => StatefulBuilder(
              builder: (context, setState) => SizedBox(
                width: 320,
                child: FramingRotationField(
                  value: value,
                  colors: SkotiqColors.of(context),
                  onChanged: enabled
                      ? (next) {
                          emitted.add(next);
                          // Mirror FramingNotifier.setRotation's [-180, 180) fold.
                          var normalized = next % 360;
                          if (normalized >= 180) {
                            normalized -= 360;
                          } else if (normalized < -180) {
                            normalized += 360;
                          }
                          setState(() => value = normalized);
                        }
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return emitted;
  }

  testWidgets('typing an exact angle applies it', (tester) async {
    final emitted = await pumpField(tester);

    await tester.enterText(
        find.byKey(const Key('framing_rotation_input')), '90');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(emitted, contains(90.0));
  });

  testWidgets('a typed out-of-range angle is folded, not rejected',
      (tester) async {
    final emitted = await pumpField(tester);

    await tester.enterText(
        find.byKey(const Key('framing_rotation_input')), '270');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(emitted, contains(270.0));
    // The field shows the canonical value the app actually holds.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '-90');
  });

  testWidgets('unparseable text reverts instead of applying a wrong rotation',
      (tester) async {
    final emitted = await pumpField(tester, initial: 42);

    await tester.enterText(
        find.byKey(const Key('framing_rotation_input')), 'abc');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(emitted, isEmpty, reason: 'no rotation should have been applied');
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '42');
  });

  testWidgets('the +/- step buttons nudge by exactly 1 and 90 degrees',
      (tester) async {
    final emitted = await pumpField(tester, initial: 10);

    await tester.tap(find.text('+1'));
    await tester.pump();
    expect(emitted.last, closeTo(11, 1e-9));

    await tester.tap(find.text('-1'));
    await tester.pump();
    expect(emitted.last, closeTo(10, 1e-9));

    await tester.tap(find.text('+90'));
    await tester.pump();
    expect(emitted.last, closeTo(100, 1e-9));

    await tester.tap(find.text('-90'));
    await tester.pump();
    expect(emitted.last, closeTo(10, 1e-9));
  });

  testWidgets('the slider snaps to whole degrees (1 deg keyboard step)',
      (tester) async {
    await pumpField(tester);

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(
      slider.divisions,
      360,
      reason: 'without divisions the arrow-key step is (max-min)/10 = 36 deg '
          'and a drag lands on an arbitrary fraction of a degree',
    );
    expect(slider.min, -180);
    expect(slider.max, 180);
  });

  testWidgets('clicking the track focuses the slider so arrow keys nudge it',
      (tester) async {
    final emitted = await pumpField(tester, initial: 0);

    // Click the track — the reported gap was that arrows did nothing AFTER a
    // click, because the slider never took keyboard focus.
    await tester.tap(find.byType(Slider));
    await tester.pumpAndSettle();
    final node = tester.widget<Slider>(find.byType(Slider)).focusNode;
    expect(node, isNotNull,
        reason: 'the slider needs an addressable focus node');
    expect(
      node!.hasFocus,
      isTrue,
      reason: 'a track click must take keyboard focus',
    );

    final before = emitted.isEmpty ? 0.0 : emitted.last;
    emitted.clear();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();

    expect(emitted, isNotEmpty, reason: 'arrow keys did nothing');
    expect(
      emitted.last - before,
      closeTo(1, 1e-6),
      reason: 'a 360-division slider must step exactly 1 deg per arrow press',
    );
  });

  testWidgets('no equipment disables every affordance', (tester) async {
    await pumpField(tester, enabled: false);

    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
  });
}
