import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:skotiq_app/router/app_router.dart';
import 'package:skotiq_app/widgets/mount/mount_site_reconciliation_card.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

GoRouter _stubRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (_, __) => const Scaffold(body: Text('Dashboard')),
        ),
      ],
    );

/// A mount that reports a site 2 degrees from this computer's.
MountSiteReconciliation _comparison() => const MountSiteReconciliation(
      deviceId: 'ascom:NYX',
      deviceName: 'NYX-101',
      capabilities: bridge.MountSiteCapabilities(
        canReadSite: true,
        canWriteSite: true,
        canReadTime: true,
        canWriteTime: true,
      ),
      computerLatitudeDeg: 39.97,
      computerLongitudeDeg: -75.36,
      computerElevationM: 120,
      computerUtcSeconds: 1792800000,
      computerUtcOffsetHours: -4,
      mountLatitudeDeg: 41.97,
      mountLongitudeDeg: -75.36,
      mountElevationM: 120,
      mountUtcSeconds: 1792800000,
      mountUtcOffsetHours: -4,
    );

/// The listener as app.dart mounts it: inside MaterialApp.router's builder,
/// above the router's Navigator.
Future<ProviderContainer> _pumpAboveNavigator(WidgetTester tester) async {
  final router = _stubRouter();
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        inMemoryDatabaseOverride(),
        appRouterProvider.overrideWithValue(router),
      ],
      child: MaterialApp.router(
        theme: SkotiqTheme.dark,
        routerConfig: router,
        builder: (context, child) =>
            MountSiteReconciliationListener(child: child!),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.text('Dashboard')));
}

void main() {
  testWidgets('a mount connecting shows the card above the router Navigator',
      (tester) async {
    final container = await _pumpAboveNavigator(tester);

    container
        .read(pendingMountSiteReconciliationProvider.notifier)
        .raise(_comparison());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Site and time differ'), findsOneWidget);

    await tester.tap(find.text('Keep both as they are'));
    await tester.pumpAndSettle();
    expect(find.text('Site and time differ'), findsNothing);
    expect(container.read(pendingMountSiteReconciliationProvider), isNull);
  });

  testWidgets('the card shows again the next time the mount connects',
      (tester) async {
    final container = await _pumpAboveNavigator(tester);
    final pending =
        container.read(pendingMountSiteReconciliationProvider.notifier);

    pending.raise(_comparison());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep both as they are'));
    await tester.pumpAndSettle();

    pending.raise(_comparison());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Site and time differ'), findsOneWidget);
  });
}
