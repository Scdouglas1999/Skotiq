// The shell's red "not connected to server" bar must not be a dead end.
//
// Reproduced defect: on a desktop running standalone, one failed "Connect to
// Server" attempt replaced the local FfiBackend with a DisconnectedBackend.
// Every screen then grew a full-width red banner with no close button and no
// action, the title-bar popover offered nothing, and the only way back was to
// relaunch the app. The banner is what the operator is actually looking at, so
// the way back to local mode has to be reachable from it.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_app/widgets/disconnected_backend_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

/// Stands in for the production notifier after a failed connect: a
/// [DisconnectedBackend] is installed, and `useLocalBackend()` is the only way
/// to put a working backend back.
class _StrandedBackendNotifier extends BackendNotifier {
  _StrandedBackendNotifier(super.ref, this.local) {
    // ignore: invalid_use_of_protected_member
    state = DisconnectedBackend();
  }

  final SkotiqBackend local;
  int useLocalCalls = 0;

  @override
  Future<void> useLocalBackend() async {
    useLocalCalls++;
    // ignore: invalid_use_of_protected_member
    state = local;
  }
}

/// The shell touches the checkpoint API on startup; keep that quiet so the
/// test is about the banner.
class _QuietBackend extends DisconnectedBackend {
  @override
  Future<void> sequencerSetCheckpointDir(String path) async {}

  @override
  Future<bool> hasCheckpoint() async => false;
}

class _StubBackendNotifier extends BackendNotifier {
  _StubBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
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

/// Pump the real [AppShell] at a desktop width, with no backend installed.
Future<void> _pumpShell(WidgetTester tester) async {
  // Synchronous on purpose: `testWidgets` runs inside a fake-async zone, and
  // an awaited dart:io future never completes there.
  final root = Directory.systemTemp.createTempSync('sk-disconnected-banner-');
  addTearDown(() => root.deleteSync(recursive: true));
  _mockPathProvider(root.path);

  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 900);
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
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the shell renders the banner with its way out', (tester) async {
    await _pumpShell(tester);

    expect(
      find.byType(DisconnectedBackendBanner),
      findsOneWidget,
      reason: 'the shell is the production call site — the banner is only '
          'useful if it is actually mounted there',
    );
    expect(find.text('Error: not connected to server'), findsOneWidget);
    expect(find.text('Work locally'), findsOneWidget);

    await _drain(tester);
  }, timeout: const Timeout(Duration(seconds: 60)));

  testWidgets('the banner offers a way back and takes it', (tester) async {
    final local = mockBackend();
    late _StrandedBackendNotifier notifier;

    final handle = await pumpAppScreen(
      tester,
      const DisconnectedBackendBanner(),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => notifier = _StrandedBackendNotifier(ref, local),
        ),
      ],
    );

    expect(find.text('Error: not connected to server'), findsOneWidget);
    final workLocally = find.text('Work locally');
    expect(
      workLocally,
      findsOneWidget,
      reason: 'a bare strip of red text is not a way out of a backend the app '
          'installed by itself',
    );

    await tester.tap(workLocally);
    await tester.pumpAndSettle();

    expect(notifier.useLocalCalls, 1);
    expect(identical(handle.container.read(backendProvider), local), isTrue);
  });

  testWidgets('the banner clears once a backend is installed', (tester) async {
    final local = mockBackend();
    late _StrandedBackendNotifier notifier;

    await pumpAppScreen(
      tester,
      const DisconnectedBackendBanner(),
      extraOverrides: [
        backendProvider.overrideWith(
          (ref) => notifier = _StrandedBackendNotifier(ref, local),
        ),
      ],
    );

    expect(find.text('Error: not connected to server'), findsOneWidget);

    await notifier.useLocalBackend();
    await tester.pumpAndSettle();

    expect(find.text('Error: not connected to server'), findsNothing);
    expect(find.text('Work locally'), findsNothing);
  });
}
