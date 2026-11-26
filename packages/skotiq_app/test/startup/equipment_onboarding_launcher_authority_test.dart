import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/startup/equipment_onboarding_launcher.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

/// A host the launcher can check. Nothing here calls it: the gate is
/// overridden, and the launcher only compares backends by identity.
class _HostBackend implements SkotiqBackend {
  @override
  void dispose() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('an old host onboarding result cannot route the replacement host',
      (tester) async {
    final oldBackend = _HostBackend();
    final newBackend = _HostBackend();
    final oldGate = Completer<bool>();
    var gateBuilds = 0;
    late _SwappableBackendNotifier backendNotifier;

    final router = GoRouter(
      initialLocation: '/dashboard',
      routes: [
        GoRoute(
          path: '/dashboard',
          builder: (_, __) => const Scaffold(body: Text('Dashboard')),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (_, __) => const Scaffold(body: Text('Onboarding')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith((ref) {
            backendNotifier = _SwappableBackendNotifier(ref, oldBackend);
            return backendNotifier;
          }),
          shouldRunEquipmentOnboardingProvider.overrideWith((ref) {
            gateBuilds++;
            return identical(ref.read(backendProvider), oldBackend)
                ? oldGate.future
                : Future<bool>.value(false);
          }),
          appRouterProvider.overrideWithValue(router),
        ],
        child: EquipmentOnboardingLauncher(
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(gateBuilds, 1);

    backendNotifier.switchTo(newBackend);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(gateBuilds, 2);

    oldGate.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Onboarding'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a phone with no imaging computer is not sent to rig setup',
      (tester) async {
    // "Look around without a rig" opened the 13-step setup, whose every scan
    // failed with "not connected to a Skotiq Headless Server".
    var gateBuilds = 0;
    final router = GoRouter(
      initialLocation: '/dashboard',
      routes: [
        GoRoute(
          path: '/dashboard',
          builder: (_, __) => const Scaffold(body: Text('Dashboard')),
        ),
        GoRoute(
          path: '/onboarding',
          builder: (_, __) => const Scaffold(body: Text('Onboarding')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, DisconnectedBackend()),
          ),
          shouldRunEquipmentOnboardingProvider.overrideWith((ref) {
            gateBuilds++;
            return Future<bool>.value(true);
          }),
          appRouterProvider.overrideWithValue(router),
        ],
        child: EquipmentOnboardingLauncher(
          child: MaterialApp.router(routerConfig: router),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(gateBuilds, 0);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Onboarding'), findsNothing);
  });
}
