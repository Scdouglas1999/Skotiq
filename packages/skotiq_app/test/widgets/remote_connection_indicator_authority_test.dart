import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/remote_connection_indicator.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

/// Stands in for the local FfiBackend: any backend that is NOT a
/// [NetworkBackend] and not the disconnected stand-in.
class _MockLocalBackend extends Mock implements SkotiqBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void _stubHost(
  _MockNetworkBackend backend,
  String host, {
  BackendConnectionState state = BackendConnectionState.disconnected,
}) {
  when(() => backend.serverHost).thenReturn(host);
  when(() => backend.serverPort).thenReturn(8080);
  when(() => backend.connectionState).thenReturn(state);
  when(() => backend.connectionStateStream)
      .thenAnswer((_) => const Stream<BackendConnectionState>.empty());
  when(() => backend.lastLatency).thenReturn(null);
  when(() => backend.latencyStream)
      .thenAnswer((_) => const Stream<Duration>.empty());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('details sheet reconnect follows the active host authority',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    _stubHost(hostA, 'host-a');
    _stubHost(hostB, 'host-b');
    final hostAResult = Completer<void>();
    final hostBResult = Completer<void>();
    when(() => hostA.reconnectNow()).thenAnswer((_) => hostAResult.future);
    when(() => hostB.reconnectNow()).thenAnswer((_) => hostBResult.future);
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: RemoteConnectionIndicator()),
        ),
      ),
    );

    await tester.tap(find.byType(RemoteConnectionIndicator));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reconnect now'));
    await tester.pump();
    expect(find.text('Reconnecting...'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pump();
    expect(find.text('Reconnect now'), findsOneWidget);
    expect(find.text('host-b'), findsOneWidget);

    await tester.tap(find.text('Reconnect now'));
    await tester.pump();
    verify(() => hostA.reconnectNow()).called(1);
    verify(() => hostB.reconnectNow()).called(1);

    hostAResult.completeError(StateError('old host failure'));
    await tester.pump();
    expect(find.textContaining('Reconnect failed'), findsNothing);
    expect(find.text('Reconnecting...'), findsOneWidget);

    hostBResult.complete();
    // pumpAndSettle, not a single pump: the Observatory button animates its
    // fill between the disabled and enabled faces, so the frame that carries
    // the label back is one behind the frame that clears `_reconnecting`.
    await tester.pumpAndSettle();
    expect(find.text('Reconnect now'), findsOneWidget);
  });

  testWidgets('blocked disconnect stays open and explains the active sequence',
      (tester) async {
    final backend = _MockNetworkBackend();
    _stubHost(
      backend,
      'imaging-host',
      state: BackendConnectionState.connected,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          sequenceExecutionStateProvider.overrideWith(
            (ref) => SequenceExecutionState.running,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: RemoteConnectionIndicator()),
        ),
      ),
    );

    await tester.tap(find.byType(RemoteConnectionIndicator));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Disconnect'));
    await tester.pump();

    expect(find.text('Connection Status'), findsOneWidget);
    expect(find.textContaining('Disconnect blocked:'), findsOneWidget);
    expect(
        find.textContaining('Stop the active sequence first'), findsOneWidget);
    verifyNever(backend.dispose);
  });

  // With a DisconnectedBackend the sheet used to state "Not connected to a
  // server" and offer nothing at all — the dead end one failed "Connect to
  // Server" left on the desktop that owns the hardware. The title-bar
  // indicator is the surface the operator taps to ask about the connection,
  // so the way back has to be on it.
  testWidgets('with no backend the sheet offers the way back to local mode',
      (tester) async {
    final local = _MockLocalBackend();
    late _LocalRestoringNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            notifier = _LocalRestoringNotifier(ref, local);
            return notifier;
          }),
        ],
        child: const MaterialApp(
          home: Scaffold(body: RemoteConnectionIndicator()),
        ),
      ),
    );

    await tester.tap(find.byType(RemoteConnectionIndicator));
    await tester.pumpAndSettle();

    expect(find.text('Not connected to a server'), findsOneWidget);
    final workLocally = find.text('Work locally');
    expect(workLocally, findsOneWidget);

    await tester.tap(workLocally);
    await tester.pumpAndSettle();

    expect(notifier.useLocalCalls, 1);
    expect(identical(notifier.currentBackend, local), isTrue);
    // Once a backend is installed the offer is withdrawn — a machine already
    // in local mode must not be shown a control that would do nothing.
    expect(find.text('Work locally'), findsNothing);
  });
}

/// A notifier sitting on a DisconnectedBackend whose only recovery is
/// `useLocalBackend()`, exactly like the production one after a rolled-back
/// connect.
class _LocalRestoringNotifier extends BackendNotifier {
  _LocalRestoringNotifier(super.ref, this.local) : super() {
    state = DisconnectedBackend();
  }

  final SkotiqBackend local;
  int useLocalCalls = 0;

  @override
  Future<void> useLocalBackend() async {
    useLocalCalls++;
    state = local;
  }
}
