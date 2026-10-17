// An unrelated settings write must not rebuild the whole app.
//
// `AppShell` is the root of every routed screen: its build produces the gear
// strip, the side/bottom navigation, the status bar, the mini-player and the
// routed child's element tree. It read one bool out of `appSettingsProvider`
// (`sidebarCollapsed`) but watched the WHOLE provider, so every settings
// toggle, every autosave and every remote settings push rebuilt all of that.
//
// The assertion is on the element's dirty flag rather than on a rendered
// pixel: a rebuild is exactly "the framework marked this element for rebuild",
// and Riverpod marks it synchronously when a watched provider notifies.

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/app_shell.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Settings that resolve immediately and can be mutated field-by-field from
/// the test body.
class _FakeSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();

  void patch(AppSettingsState next) => state = AsyncData(next);
}

/// The shell touches the checkpoint API on startup; keep that quiet so the
/// test is about the rebuild, not about startup IO.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a settings field the shell does not read leaves it clean',
      (tester) async {
    // Synchronous on purpose: `testWidgets` runs inside a fake-async zone, and
    // an awaited dart:io future never completes there.
    final root = Directory.systemTemp.createTempSync('ns-shell-rebuild-');
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

    late _FakeSettingsNotifier settings;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
              (ref) => _StubBackendNotifier(ref, _QuietBackend())),
          appSettingsProvider
              .overrideWith(() => settings = _FakeSettingsNotifier()),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const AppShell(child: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final shell = tester.element(find.byType(AppShell));
    expect(shell.dirty, isFalse,
        reason: 'the shell must settle before the run');

    // A write the shell has no interest in. `theme` is read by the app root,
    // not by the shell chrome.
    settings.patch(const AppSettingsState(theme: 'red'));
    expect(
      shell.dirty,
      isFalse,
      reason: 'the shell reads only sidebarCollapsed out of AppSettings; '
          'watching the whole object rebuilds the nav, the status bar, the '
          'mini-player and the routed child on every unrelated settings write',
    );

    // The one field it does read must still reach it. Derived from the
    // default rather than hard-coded: the rail's default collapsed state is a
    // design decision that has already moved once, and patching it to the
    // value it already holds is a write that notifies nothing — which would
    // pass this assertion for the wrong reason.
    const defaults = AppSettingsState();
    settings.patch(
      AppSettingsState(sidebarCollapsed: !defaults.sidebarCollapsed),
    );
    expect(shell.dirty, isTrue,
        reason:
            'narrowing the watch must not stop the sidebar from collapsing');

    // Unmount inside the test body so the drift stream-close timers the
    // ProviderScope schedules on dispose can drain.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(const Duration(milliseconds: 10));
  }, timeout: const Timeout(Duration(seconds: 60)));
}
