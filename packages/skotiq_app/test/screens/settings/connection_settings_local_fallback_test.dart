// Settings > Connection must not cost the operator local mode.
//
// `BackendNotifier.connect()` installs an authoritative DisconnectedBackend
// when a handshake fails. On a phone that never owned a rig that is correct, but
// on the desktop that OWNS the hardware it replaces a working FfiBackend with a
// dead one: every role provider follows `backendProvider`, so one mistyped host
// leaves a standing red "Error: not connected to server" bar on every screen,
// and with no UI caller for `useLocalBackend()` the only way back is to
// relaunch.
//
// These tests pin both halves: the connect dialog restores what it displaced,
// and a disconnected desktop is offered a way back.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_app/screens/settings/widgets/connection_settings.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

/// Stands in for the production notifier's failure path: `connect()` leaves an
/// authoritative [DisconnectedBackend] installed and rethrows, exactly as
/// `_rollbackFailedConnect` does, while `useLocalBackend()` reinstates the
/// local backend.
class _FailingConnectNotifier extends BackendNotifier {
  _FailingConnectNotifier(super.ref, this.local, {required bool startLocal}) {
    // ignore: invalid_use_of_protected_member
    state = startLocal ? local : DisconnectedBackend();
  }

  final SkotiqBackend local;
  int useLocalCalls = 0;

  @override
  Future<void> connect(
    String host,
    int port, {
    String? authToken,
    String scheme = 'http',
    String? pinnedFingerprint,
    String? collaborationViewerId,
    String? collaborationDeviceName,
    String? collaborationDisplayName,
  }) async {
    // ignore: invalid_use_of_protected_member
    state = DisconnectedBackend();
    throw StateError(
      'Connection to $scheme://$host:$port did not complete '
      '(state=disconnected).',
    );
  }

  @override
  Future<void> useLocalBackend() async {
    useLocalCalls++;
    // ignore: invalid_use_of_protected_member
    state = local;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a failed connect leaves the machine in local mode',
      (tester) async {
    final local = mockBackend();
    late _FailingConnectNotifier notifier;

    final handle = await pumpAppScreen(
      tester,
      const ConnectionSettings(),
      extraOverrides: [
        appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
        backendProvider.overrideWith(
          (ref) => notifier = _FailingConnectNotifier(
            ref,
            local,
            startLocal: true,
          ),
        ),
      ],
    );

    expect(find.text('Local Mode'), findsOneWidget);

    final openConnect = find.widgetWithText(SkotiqButton, 'Connect');
    await tester.ensureVisible(openConnect);
    await tester.tap(openConnect);
    await tester.pumpAndSettle();

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(SkotiqButton, 'Connect'),
      ),
    );
    await tester.pumpAndSettle();

    expect(notifier.useLocalCalls, 1);
    expect(
      handle.container.read(backendProvider),
      isNot(isA<DisconnectedBackend>()),
      reason: 'a failed OPTIONAL remote attempt must not uninstall the local '
          'backend that owns the hardware',
    );
    expect(identical(handle.container.read(backendProvider), local), isTrue);
    // The dialog stays open, reports the real failure, and says so plainly.
    expect(find.textContaining('Connection failed'), findsOneWidget);
    expect(find.textContaining('Still working locally'), findsOneWidget);
  });

  testWidgets('a disconnected desktop is offered a way back to local mode',
      (tester) async {
    final local = mockBackend();
    late _FailingConnectNotifier notifier;

    final handle = await pumpAppScreen(
      tester,
      const ConnectionSettings(),
      extraOverrides: [
        appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
        backendProvider.overrideWith(
          (ref) => notifier = _FailingConnectNotifier(
            ref,
            local,
            startLocal: false,
          ),
        ),
      ],
    );

    expect(find.text('Disconnected'), findsOneWidget);

    final workLocally = find.widgetWithText(SkotiqButton, 'Work locally');
    expect(workLocally, findsOneWidget);
    await tester.ensureVisible(workLocally);
    await tester.tap(workLocally);
    await tester.pumpAndSettle();

    expect(notifier.useLocalCalls, 1);
    expect(identical(handle.container.read(backendProvider), local), isTrue);
    expect(find.text('Local Mode'), findsOneWidget);
  });
}
