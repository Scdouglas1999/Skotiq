// A floating snackbar anchors to the bottom of the Scaffold, which on the
// Imaging screen is exactly where Snapshot / Loop live — the audit measured an
// opaque amber bar covering the lower half of both buttons. Screens that own a
// bottom bar declare its height and the snackbar helpers must honour it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/utils/snackbar_helper.dart';
import 'package:skotiq_app/utils/transient_bottom_inset.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Widget _host({required double? inset, required Widget child}) {
  final body =
      inset == null ? child : TransientBottomInset(inset: inset, child: child);
  return MaterialApp(
    theme: SkotiqTheme.dark,
    home: Scaffold(body: body),
  );
}

Future<Rect> _showAndMeasure(
  WidgetTester tester, {
  required double? inset,
}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    _host(
      inset: inset,
      child: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox.expand();
        },
      ),
    ),
  );
  // A snackbar left over from an earlier measurement in the same test stays on
  // screen with the new one merely queued, so the measurement would be of the
  // wrong card.
  ScaffoldMessenger.of(captured).clearSnackBars();
  await tester.pumpAndSettle();
  captured.showErrorSnackBar('Failed to save FITS file');
  await tester.pumpAndSettle();
  expect(find.text('Failed to save FITS file'), findsOneWidget);
  // Measure the CONTENT rect: for floating behaviour the margin is applied
  // inside the SnackBar, so the SnackBar widget's own rect always spans to the
  // screen edge and would hide the very thing under test.
  return tester.getRect(find.text('Failed to save FITS file'));
}

void main() {
  group('direction independence', _directionIndependenceTests);
  testWidgets('a declared inset lifts the snackbar clear of the bottom bar',
      (tester) async {
    final without = await _showAndMeasure(tester, inset: null);
    final with120 = await _showAndMeasure(tester, inset: 120);

    // The undeclared case is not flush with the window bottom either: every
    // snackbar clears the shell's own 36 dp status bar, so the extra lift a
    // 120 dp bar buys is the difference between the two.
    expect(
      with120.bottom,
      lessThan(without.bottom - 60),
      reason: 'a 120 dp bar must push the snackbar clear of it',
    );
    final screenBottom =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    expect(
      screenBottom - with120.bottom,
      greaterThan(120),
      reason: 'the snackbar must not overlap the declared bar at all',
    );
  });

  testWidgets('no declaration leaves the default placement untouched',
      (tester) async {
    final plain = await _showAndMeasure(tester, inset: null);
    final zero = await _showAndMeasure(tester, inset: 0);
    expect(zero.bottom, plain.bottom);
  });

  test('TransientBottomInset.of defaults to zero without an ancestor', () {
    // Guards the helper's null path: a screen that declares nothing must not
    // get a margin, or every snackbar in the app would move.
    expect(const TransientBottomInset(inset: 0, child: SizedBox()).inset, 0);
  });
}

// Direction-independence, the case a pure InheritedWidget lookup misses.
//
// `_ImagingScreenActions` is an extension on `_ImagingScreenState`, so the
// context it raises "Capture failed: …" from is the ImagingScreen ELEMENT — an
// ancestor of the TransientBottomInset its own build() creates. An
// ancestors-only lookup returns null there and places the toast with no lift at
// all: 24 px from the screen bottom (over Snapshot/Loop) versus 71 px when
// raised from a descendant. Publishing to a notifier makes the lookup work from
// either direction.
void _directionIndependenceTests() {
  tearDown(() => TransientBottomInset.currentInset.value = 0);

  testWidgets('an ANCESTOR context sees the inset a descendant declared',
      (tester) async {
    late BuildContext ancestorContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (outer) {
            // Stand-in for the screen's own State context: it sits ABOVE the
            // declaration that its build() returns.
            ancestorContext = outer;
            return const TransientBottomInsetPublisher(
              inset: 84,
              child: SizedBox.expand(),
            );
          },
        ),
      ),
    );

    expect(
      TransientBottomInset.of(ancestorContext),
      84,
      reason: 'the screen raises its own toasts from this context; an '
          'inherited-only lookup returns 0 here and the toast covers the bar',
    );
  });

  testWidgets('a nested declaration still wins for its own subtree',
      (tester) async {
    late BuildContext innerContext;
    await tester.pumpWidget(
      MaterialApp(
        home: TransientBottomInsetPublisher(
          inset: 84,
          child: TransientBottomInset(
            inset: 20,
            child: Builder(
              builder: (inner) {
                innerContext = inner;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );

    expect(
      TransientBottomInset.of(innerContext),
      20,
      reason:
          'the tree must still take precedence for descendants, or a nested '
          'bar could not override the screen-level lift',
    );
  });

  testWidgets('the lift resets when the declaring screen goes away',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: TransientBottomInsetPublisher(
          inset: 84,
          child: SizedBox.expand(),
        ),
      ),
    );
    expect(TransientBottomInset.currentInset.value, 84);

    // Navigate away: a screen with no bottom bar must not inherit the lift.
    await tester.pumpWidget(
      const MaterialApp(home: SizedBox.expand()),
    );
    await tester.pump();

    expect(
      TransientBottomInset.currentInset.value,
      0,
      reason: 'a stale lift pushes every later toast up for no reason',
    );
  });
}
