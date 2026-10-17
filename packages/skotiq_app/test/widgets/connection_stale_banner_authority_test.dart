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
}
