import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/connection_stale_banner.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('host switch unlocks retry and discards the old reconnect result',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final hostAResult = Completer<void>();
    final hostBResult = Completer<void>();
    when(() => hostA.reconnectNow()).thenAnswer((_) => hostAResult.future);
    when(() => hostB.reconnectNow()).thenAnswer((_) => hostBResult.future);
    for (final host in [hostA, hostB]) {
      when(() => host.connectionState)
          .thenReturn(BackendConnectionState.connected);
      when(() => host.connectionStateStream)
          .thenAnswer((_) => const Stream.empty());
      when(() => host.serverHost).thenReturn('rig.local');
    }
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
          connectionStaleProvider.overrideWith((ref) => true),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: ConnectionStaleBanner()),
        ),
      ),
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(find.text('Retrying…'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pump();
    verify(() => hostA.reconnectNow()).called(1);
    verify(() => hostB.reconnectNow()).called(1);

    hostAResult.completeError(StateError('old host is gone'));
    await tester.pump();
    expect(find.textContaining('Reconnect failed'), findsNothing);
    expect(find.text('Retrying…'), findsOneWidget);

    hostBResult.complete();
    await tester.pump();
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets(
      'a lost link to the host names the host and says the values shown '
      'are the last known', (tester) async {
    final host = _MockNetworkBackend();
    final states = StreamController<BackendConnectionState>();
    addTearDown(states.close);
    when(() => host.connectionState)
        .thenReturn(BackendConnectionState.connected);
    when(() => host.connectionStateStream).thenAnswer((_) => states.stream);
    when(() => host.serverHost).thenReturn('rig.local');

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, host),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Column(
              children: [
                ConnectionStaleBanner(),
                Expanded(
                  child: HostLinkStaleScope(child: Text('Mount tracking')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.textContaining('Lost connection'), findsNothing);
    expect(find.byType(Opacity), findsNothing);

    states.add(BackendConnectionState.disconnected);
    await tester.pump();
    await tester.pump();

    expect(
      find.textContaining('Lost connection to rig.local, reconnecting'),
      findsOneWidget,
    );
    expect(find.textContaining('last known, not live'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Last known values, no link to rig.local')),
      findsOneWidget,
    );

    states.add(BackendConnectionState.connected);
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Lost connection'), findsNothing);
  });

  // 2026-11-03: the host stopped answering for about two minutes while the
  // socket stayed open. The title-bar chip now says "No answer for N s", but
  // the run and device values under it still looked live: no banner, no
  // dimming, "Running 5%" and "Exposing..." as if confirmed.
  testWidgets(
      'a connected host that has stopped answering marks the values shown '
      'as the last known', (tester) async {
    final host = _MockNetworkBackend();
    when(() => host.connectionState)
        .thenReturn(BackendConnectionState.connected);
    when(() => host.connectionStateStream)
        .thenAnswer((_) => const Stream.empty());
    when(() => host.serverHost).thenReturn('rig.local');
    Duration? unanswered;
    when(() => host.unansweredPingAge).thenAnswer((_) => unanswered);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, host),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: Column(
              children: [
                ConnectionStaleBanner(),
                Expanded(
                  child: HostLinkStaleScope(child: Text('Running 5%')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('last known'), findsNothing);
    expect(find.byType(Opacity), findsNothing);

    // A few seconds without a pong is ordinary lag.
    unanswered = const Duration(seconds: 4);
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('last known'), findsNothing);

    unanswered = const Duration(seconds: 25);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(
      find.textContaining('rig.local has not answered for 25 s'),
      findsOneWidget,
    );
    expect(find.textContaining('last known, not live'), findsOneWidget);
    expect(find.textContaining('reconnecting'), findsNothing);
    expect(
      find.bySemanticsLabel(
        RegExp('Last known values, rig.local is not answering'),
      ),
      findsOneWidget,
    );

    unanswered = null;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('last known'), findsNothing);
    expect(find.byType(Opacity), findsNothing);
  });
}
