// A companion that cannot reach its imaging host says which host and why,
// with Retry, instead of offering to work locally.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/connection/disconnected_backend_banner.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _DisconnectedNotifier extends BackendNotifier {
  _DisconnectedNotifier(super.ref) {
    state = DisconnectedBackend();
  }
}

class _FixedStatusNotifier extends RemoteLaunchStatusNotifier {
  _FixedStatusNotifier(super.ref, RemoteLaunchStatus status) {
    state = status;
  }

  int retries = 0;

  @override
  Future<bool> connect() async {
    retries++;
    return false;
  }
}

const _target = RemoteLaunchTarget(host: '192.168.1.100', port: 8099);

void main() {
  late _FixedStatusNotifier status;

  Future<void> pump(WidgetTester tester, RemoteLaunchStatus initial) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(_DisconnectedNotifier.new),
          remoteLaunchTargetProvider.overrideWithValue(_target),
          remoteLaunchStatusProvider.overrideWith((ref) {
            status = _FixedStatusNotifier(ref, initial);
            return status;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: DisconnectedBackendBanner()),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('an unreachable host is named, with Retry', (tester) async {
    await pump(
      tester,
      const RemoteLaunchStatus.failed(
        RemoteLaunchFailure.unreachable,
        'SocketException: Connection refused',
      ),
    );
    expect(
      find.text("Can't reach the imaging host at 192.168.1.100:8099."),
      findsOneWidget,
    );
    expect(find.text('Work locally'), findsNothing);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(status.retries, 1);
  });

  testWidgets('a rejected token says so', (tester) async {
    await pump(
      tester,
      const RemoteLaunchStatus.failed(
        RemoteLaunchFailure.tokenRejected,
        'invalid token',
      ),
    );
    expect(
      find.text(
        'The imaging host at 192.168.1.100:8099 rejected the access token.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Remote access'), findsOneWidget);
  });

  testWidgets('fits a phone-width window', (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await pump(
      tester,
      const RemoteLaunchStatus.failed(RemoteLaunchFailure.unreachable, ''),
    );
    expect(tester.takeException(), isNull);
  });
}
