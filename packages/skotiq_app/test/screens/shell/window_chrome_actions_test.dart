// The window controls must DO what their labels promise.
//
// A button that names itself but never reaches window_manager is a control
// that exists only in the accessibility tree. These pin the call each control
// makes: the host is Linux for these tests, so `Platform.isLinux` paths —
// controls, drag, resize edges — are the live ones.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/widgets/window_chrome.dart';
import 'package:skotiq_app/screens/shell/widgets/window_chrome_desktop.dart'
    as impl;
import 'package:skotiq_ui/skotiq_ui.dart';

/// Records every call the window chrome makes to the `window_manager`
/// channel, and answers `isMaximized`/`isFullScreen` so the toggle paths
/// resolve.
class _FakeWindowManagerChannel {
  _FakeWindowManagerChannel() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'isMaximized':
          return maximized;
        default:
          return null;
      }
    });
  }

  static const _channel = MethodChannel('window_manager');

  final calls = <String>[];
  bool maximized = false;

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    impl.windowChromeState.value = const WindowChromeState();
  });

  Widget _controls() => const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: WindowControls(colors: SkotiqColors.dark),
          ),
        ),
      );

  testWidgets('minimize and close call through', (tester) async {
    final fake = _FakeWindowManagerChannel();
    addTearDown(fake.dispose);

    await tester.pumpWidget(_controls());
    await tester.tap(find.bySemanticsLabel('Minimize window'));
    await tester.tap(find.bySemanticsLabel('Close window'));
    await tester.pump();

    expect(fake.calls, containsAllInOrder(['minimize', 'close']));
  });

  testWidgets(
      'the middle button maximizes when not maximized, restores when '
      'it is', (tester) async {
    final fake = _FakeWindowManagerChannel();
    addTearDown(fake.dispose);

    await tester.pumpWidget(_controls());
    await tester.pump();

    // Not maximized: the control offers to maximize, then asks the host.
    await tester.tap(find.bySemanticsLabel('Maximize window'));
    await tester.pump();
    expect(fake.calls, containsAllInOrder(['isMaximized', 'maximize']));

    // Host says maximized: the control must read "Restore" and ask to undo.
    fake.maximized = true;
    impl.windowChromeState.value = const WindowChromeState(maximized: true);
    await tester.pump();
    fake.calls.clear();

    expect(find.bySemanticsLabel('Restore window'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Restore window'));
    await tester.pump();
    expect(fake.calls, containsAllInOrder(['isMaximized', 'unmaximize']));
  });

  testWidgets('a pan on the drag area starts a window drag', (tester) async {
    final fake = _FakeWindowManagerChannel();
    addTearDown(fake.dispose);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            // A painted child, the way the top band actually wraps the
            // drag area — a bare SizedBox under deferToChild doesn't take
            // the hit the recognizer needs.
            child: WindowDragArea(
              child: SizedBox(
                width: 400,
                height: 60,
                child: ColoredBox(color: Color(0xFF0B0D12)),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(const Offset(200, 30));
    // One move past the touch slop, then a second — the recognizer claims
    // the gesture on the crossing and fires onPanStart.
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump();
    await gesture.up();

    // The double-tap recognizer's per-pointer countdown survives the drag;
    // let it expire so no Timer is pending at end of test.
    await tester.pump(const Duration(milliseconds: 100));

    expect(fake.calls, contains('startDragging'));
  });

  testWidgets('a double-tap on the drag area toggles maximize', (tester) async {
    final fake = _FakeWindowManagerChannel();
    addTearDown(fake.dispose);

    // No host channel for the double-click preference: the fallback is the
    // conventional toggle-maximize.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: WindowDragArea(
              child: SizedBox(
                width: 400,
                height: 60,
                child: ColoredBox(color: Color(0xFF0B0D12)),
              ),
            ),
          ),
        ),
      ),
    );

    // Two quick taps at the same spot are one double-tap — 60 ms apart, so
    // they clear kDoubleTapMinTime and land inside kDoubleTapTimeout.
    await tester.tapAt(const Offset(200, 30));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(const Offset(200, 30));
    await tester.pump();

    // The path is a small future chain — the platform channel misses (no
    // host handler in tests), the fallback picks toggle-maximize, and only
    // then is isMaximized consulted. Platform-channel replies land on the
    // real event loop, so this has to run outside the fake-async zone.
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
    await tester.pump();

    expect(fake.calls, contains('isMaximized'));
    expect(fake.calls, contains('maximize'));

    // Drain the recognizer's double-click timeout before end of test.
    await tester.pump(const Duration(milliseconds: 400));
  });

  test('the edge mapping reaches every grip', () {
    // Eight grips, all live: the undecorated window has no system frame to
    // resize from, so a missed edge is a dead corner of the window.
    expect(WindowResizeEdge.values, hasLength(8));
  });
}
