// Window controls must survive the responsive breakpoint on desktop.
//
// Resizing the Linux window to 760x700 drops the shell below
// `ShellChromeMetrics.shellLayoutBreakpoint` and swaps the desktop ShellTopBand for
// the compact mobile bar. If that bar draws no minimize/maximize/close the
// window has no mouse-reachable way to be closed, minimized or moved, because
// the desktop runners hide the OS decorations and there are no OS decorations
// to fall back on. Window controls are a property of the platform, not of the
// width.
//
// These tests pump the real `AppShell`, so deleting the controls from the
// compact bar fails them.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_app/screens/shell/widgets/skotiq_bottom_navigation.dart';
import 'package:skotiq_app/screens/shell/widgets/window_chrome.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _QuietBackend extends DisconnectedBackend {
  @override
  Future<void> sequencerSetCheckpointDir(String path) async {}

  @override
  Future<bool> hasCheckpoint() async => false;
}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

void _mockPathProvider(String root) {
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => root);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}

Future<void> _pumpShell(WidgetTester tester, Size size) async {
  // Synchronous on purpose: `testWidgets` runs inside a fake-async zone, and
  // an awaited dart:io future never completes there.
  final root = Directory.systemTemp.createTempSync('sk-window-chrome-');
  addTearDown(() => root.deleteSync(recursive: true));
  _mockPathProvider(root.path);

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        backendProvider
            .overrideWith((ref) => _StubBackendNotifier(ref, _QuietBackend())),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const AppShell(child: SizedBox.shrink()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Unmounts inside the test body so the drift stream-close timers the
/// ProviderScope schedules on dispose can drain; otherwise the binding fails
/// the test on "a Timer is still pending".
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 10));
  await tester.pump(const Duration(milliseconds: 10));
}

void main() {
  testWidgets('a narrow desktop window keeps its minimize/maximize/close',
      (tester) async {
    await _pumpShell(tester, const Size(760, 700));

    expect(
      find.byType(SkotiqBottomNavigation),
      findsOneWidget,
      reason: '760px is below the side-nav breakpoint, so this test is only '
          'meaningful if the compact layout is actually in play',
    );
    expect(find.byType(ShellTopBand), findsNothing);
    expect(
      find.byType(WindowControls),
      findsOneWidget,
      reason: 'the OS draws no decorations — this bar is the only way to '
          'close, minimize or maximize the window',
    );
    expect(
      find.byType(WindowDragArea),
      findsWidgets,
      reason: 'a frameless window with no draggable title bar cannot be moved',
    );
    await _drain(tester);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('a wide desktop window keeps them too', (tester) async {
    await _pumpShell(tester, const Size(1400, 900));

    expect(find.byType(SkotiqBottomNavigation), findsNothing);
    expect(find.byType(ShellTopBand), findsOneWidget);
    expect(find.byType(WindowControls), findsOneWidget);
    await _drain(tester);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
