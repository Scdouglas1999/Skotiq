// `showMenu`'s `position` is measured against the enclosing Navigator's
// OVERLAY, not the screen. Every Skotiq screen is a route inside the nested
// Navigator go_router's `ShellRoute` hands `AppShell`, and that overlay starts
// below the title bar and right of the side nav rail — so a global coordinate
// passed straight through counts the overlay's origin twice and the menu opens
// a rail-width away from whatever was clicked.
//
// Four call sites shipped that bug (the Equipment profile card's overflow menu,
// the sequencer's node and fold-group menus, the planetarium's sky context
// menu) and five had hand-rolled the conversion correctly, so the conversion
// now lives in `menu_position.dart` and every site delegates to it. These are
// the numeric guards for that one implementation.
//
// The inset is parameterised on purpose: at inset 0 the broken and the correct
// maths agree exactly, which is why widget tests that mount a screen at the
// window origin never caught this.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// How far a menu may sit from its anchor. Not zero — a popup is allowed to be
/// nudged to stay on screen — but the defect displaced menus by the full
/// chrome inset, 43-220 px in the cases measured live.
const double _tolerance = 24.0;

/// Mounts [child] the way `AppShell` mounts a routed screen: in a NESTED
/// [Navigator] inset from the window by [chromeInset] left and top.
Future<void> _pumpShellHosted(
  WidgetTester tester,
  Widget child, {
  required double chromeInset,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 1000);
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            SizedBox(height: chromeInset),
            Expanded(
              child: Row(
                children: [
                  SizedBox(width: chromeInset),
                  Expanded(
                    child: Navigator(
                      onGenerateRoute: (_) => MaterialPageRoute<void>(
                        builder: (_) =>
                            Align(alignment: Alignment.topLeft, child: child),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Global rect of the open menu, as the union of its items.
Rect _openMenuRect(WidgetTester tester) {
  final items = find.byWidgetPredicate((w) => w is PopupMenuItem);
  expect(items, findsWidgets, reason: 'the menu should be open');
  return items
      .evaluate()
      .map((element) {
        final box = element.findRenderObject()! as RenderBox;
        return box.localToGlobal(Offset.zero) & box.size;
      })
      .reduce((a, b) => a.expandToInclude(b));
}

List<PopupMenuEntry<int>> _items() => const <PopupMenuEntry<int>>[
  PopupMenuItem<int>(value: 1, child: Text('One')),
  PopupMenuItem<int>(value: 2, child: Text('Two')),
];

/// A surface that opens a menu at the pointer, via [menuPositionFromPoint].
class _PointerMenuSurface extends StatelessWidget {
  const _PointerMenuSurface();

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (details) => showMenu<int>(
        context: context,
        position: menuPositionFromPoint(context, details.globalPosition),
        items: _items(),
      ),
      child: const SizedBox(width: 600, height: 400, child: Text('sky')),
    );
  }
}

/// A control that opens a menu over itself / below itself.
class _ButtonMenuSurface extends StatelessWidget {
  const _ButtonMenuSurface({required this.below});

  final bool below;

  @override
  Widget build(BuildContext context) {
    // Padding so the control is NOT at the route's origin either: a fix that
    // only handled the overlay offset but anchored on the wrong render object
    // would still be caught.
    return Padding(
      padding: const EdgeInsets.only(left: 120, top: 80),
      child: Builder(
        builder: (buttonContext) => GestureDetector(
          onTap: () => showMenu<int>(
            context: buttonContext,
            position: below
                ? menuPositionBelowWidget(buttonContext)
                : menuPositionFromWidget(buttonContext),
            items: _items(),
          ),
          child: const SizedBox(width: 48, height: 48, child: Text('btn')),
        ),
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('menuPositionFromPoint', () {
    for (final inset in <double>[0, 64, 220]) {
      testWidgets('opens at the cursor with the overlay inset by $inset px', (
        tester,
      ) async {
        await _pumpShellHosted(
          tester,
          const _PointerMenuSurface(),
          chromeInset: inset,
        );

        final cursor = tester.getCenter(find.text('sky'));
        await tester.tapAt(cursor, buttons: kSecondaryButton);
        await tester.pumpAndSettle();

        final menu = _openMenuRect(tester);
        expect(
          (menu.left - cursor.dx).abs(),
          lessThanOrEqualTo(_tolerance),
          reason:
              'menu $menu vs cursor $cursor: '
              '${menu.left - cursor.dx} px off horizontally',
        );
        expect(
          (menu.top - cursor.dy).abs(),
          lessThanOrEqualTo(_tolerance),
          reason:
              'menu $menu vs cursor $cursor: '
              '${menu.top - cursor.dy} px off vertically',
        );
      });
    }

    testWidgets('the cursor-to-menu offset does not track the chrome inset', (
      tester,
    ) async {
      final offsets = <Offset>[];
      for (final inset in <double>[0, 220]) {
        await _pumpShellHosted(
          tester,
          const _PointerMenuSurface(),
          chromeInset: inset,
        );
        final cursor = tester.getCenter(find.text('sky'));
        await tester.tapAt(cursor, buttons: kSecondaryButton);
        await tester.pumpAndSettle();
        final menu = _openMenuRect(tester);
        offsets.add(menu.topLeft - cursor);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
      expect(
        offsets.first.dx,
        closeTo(offsets.last.dx, 1.0),
        reason: 'got $offsets',
      );
      expect(
        offsets.first.dy,
        closeTo(offsets.last.dy, 1.0),
        reason: 'got $offsets',
      );
    });
  });

  group('menuPositionFromWidget', () {
    for (final inset in <double>[0, 220]) {
      testWidgets('opens on the control with the overlay inset by $inset px', (
        tester,
      ) async {
        await _pumpShellHosted(
          tester,
          const _ButtonMenuSurface(below: false),
          chromeInset: inset,
        );

        final button = tester.getRect(find.text('btn'));
        await tester.tap(find.text('btn'));
        await tester.pumpAndSettle();

        final menu = _openMenuRect(tester);
        expect(
          menu.left,
          closeTo(button.left, _tolerance),
          reason:
              'menu $menu should share the control\'s left edge '
              '$button',
        );
        expect(
          menu.top,
          closeTo(button.top, _tolerance),
          reason: 'menu $menu should be anchored on the control $button',
        );
      });
    }
  });

  group('menuPositionBelowWidget', () {
    for (final inset in <double>[0, 220]) {
      testWidgets(
        'drops below the control with the overlay inset by $inset px',
        (tester) async {
          await _pumpShellHosted(
            tester,
            const _ButtonMenuSurface(below: true),
            chromeInset: inset,
          );

          final button = tester.getRect(find.text('btn'));
          await tester.tap(find.text('btn'));
          await tester.pumpAndSettle();

          final menu = _openMenuRect(tester);
          expect(
            menu.left,
            closeTo(button.left, _tolerance),
            reason:
                'menu $menu should share the control\'s left edge '
                '$button',
          );
          // Below, not over: the control stays visible while its menu is open.
          expect(
            menu.top,
            closeTo(button.bottom, _tolerance),
            reason:
                'menu $menu should start at the control\'s bottom edge '
                '${button.bottom}',
          );
        },
      );
    }
  });
}
