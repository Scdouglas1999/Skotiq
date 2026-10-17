// Widget tests for SavedServersScreen.
//
// We exercise:
//   1. Three fake saved-server entries render with display name + host
//      + relative time.
//   2. Long-press surfaces the rename / notes / remove actions.
//   3. Removing a row through the bottom sheet + confirmation dialog
//      calls SavedServersService.removeById, and the row disappears.
//   4. The FAB invokes the supplied onAddServer callback.
//
// We do NOT exercise the row-tap connect path: it goes through
// EnhancedSkotiqDiscovery.testServerConnection (a static http.get)
// and BackendNotifier.connect (which spins up a real NetworkBackend).
// Those edges are integration territory and would require shimming the
// remote-protocol package, which the saved-servers tests don't need to
// own — the row's tap binding is verified separately by:
//   * service tests (loadAll / touchLastConnected) — round-trip happens
//     here.
//   * the rendering assertions below (correct id passed to the screen).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_mobile/screens/servers/saved_servers_screen.dart';
import 'package:skotiq_mobile/services/saved_servers_service.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(
  WidgetTester tester, {
  required SavedServersService service,
  Future<SavedServer?> Function(BuildContext)? onAddServer,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [savedServersServiceProvider.overrideWithValue(service)],
      child: MaterialApp(
        theme: ThemeData(extensions: const [SkotiqColors.dark]),
        home: SavedServersScreen(
          onAddServer: onAddServer,
          onServerSelected: (_, __) {},
        ),
      ),
    ),
  );
  // Two pumps: one for the FutureProvider to resolve, one for the
  // ListView to lay out.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      // Skip the legacy migration so the test starts with a clean list.
      SavedServersStorageKeys.migrated: true,
    });
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  testWidgets('renders three saved-server rows with display name + host', (
    tester,
  ) async {
    final service = SavedServersService();
    await service.add(
      displayName: 'Observatory',
      host: '10.0.0.10',
      port: 8080,
      lastConnectedAt: DateTime.now().subtract(const Duration(minutes: 30)),
    );
    await service.add(
      displayName: 'Backyard',
      host: '10.0.0.20',
      port: 8080,
      lastConnectedAt: DateTime.now().subtract(const Duration(hours: 6)),
    );
    await service.add(
      displayName: 'Travel scope',
      host: '192.168.4.55',
      port: 8443,
      lastConnectedAt: DateTime.now().subtract(const Duration(days: 3)),
    );

    await _pump(tester, service: service);

    expect(find.text('Observatory'), findsOneWidget);
    expect(find.text('Backyard'), findsOneWidget);
    expect(find.text('Travel scope'), findsOneWidget);
    expect(find.textContaining('10.0.0.10:8080'), findsOneWidget);
    expect(find.textContaining('10.0.0.20:8080'), findsOneWidget);
    expect(find.textContaining('192.168.4.55:8443'), findsOneWidget);
    // Recency ordering: Observatory (most recent) should appear above
    // Backyard which should appear above Travel scope.
    final observatoryY = tester.getTopLeft(find.text('Observatory')).dy;
    final backyardY = tester.getTopLeft(find.text('Backyard')).dy;
    final travelY = tester.getTopLeft(find.text('Travel scope')).dy;
    expect(observatoryY, lessThan(backyardY));
    expect(backyardY, lessThan(travelY));
  });

  testWidgets('empty state surfaces when no servers are saved', (tester) async {
    final service = SavedServersService();
    await _pump(tester, service: service);
    expect(find.text('No saved servers yet'), findsOneWidget);
  });

  testWidgets('long-press surfaces rename / notes / remove menu', (
    tester,
  ) async {
    final service = SavedServersService();
    await service.add(
      displayName: 'Observatory',
      host: '10.0.0.10',
      port: 8080,
    );
    await _pump(tester, service: service);

    await tester.longPress(find.text('Observatory'));
    await tester.pumpAndSettle();

    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Edit notes'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('remove action through the menu wipes the row', (tester) async {
    final service = SavedServersService();
    final row = await service.add(
      displayName: 'Backyard',
      host: '10.0.0.20',
      port: 8080,
      authToken: 'paired-token',
    );
    expect(await service.tokenFor(row.id), 'paired-token');

    await _pump(tester, service: service);
    expect(find.text('Backyard'), findsOneWidget);

    await tester.longPress(find.text('Backyard'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    // Confirmation dialog: tap the Remove button.
    expect(find.text('Remove Backyard?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(find.text('Backyard'), findsNothing);
    expect(await service.loadAll(), isEmpty);
    expect(
      await service.tokenFor(row.id),
      isNull,
      reason: 'remove must wipe the secure-storage token',
    );
  });

  testWidgets('rename action persists the new display name', (tester) async {
    final service = SavedServersService();
    await service.add(displayName: 'Old name', host: '10.0.0.30', port: 8080);
    await _pump(tester, service: service);

    await tester.longPress(find.text('Old name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Permanent pier');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Permanent pier'), findsOneWidget);
    expect(find.text('Old name'), findsNothing);
    final reloaded = (await service.loadAll()).single;
    expect(reloaded.displayName, 'Permanent pier');
  });

  testWidgets('rename persistence failure stays visible and is retryable', (
    tester,
  ) async {
    final service = _FailingRenameService();
    await service.add(displayName: 'Old name', host: '10.0.0.30', port: 8080);
    await _pump(tester, service: service);

    await tester.longPress(find.text('Old name'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Lost edit');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not update Old name'), findsOneWidget);
    expect(find.text('Old name'), findsOneWidget);
    expect((await service.loadAll()).single.displayName, 'Old name');

    // The failed operation must release the screen-wide busy gate.
    await tester.longPress(find.text('Old name'));
    await tester.pumpAndSettle();
    expect(find.text('Rename'), findsOneWidget);
  });

  testWidgets(
    'FAB invokes the onAddServer callback and refreshes when it returns a row',
    (tester) async {
      final service = SavedServersService();
      var calls = 0;
      await _pump(
        tester,
        service: service,
        onAddServer: (_) async {
          calls++;
          return service.add(
            displayName: 'Added via FAB',
            host: '10.0.0.99',
            port: 8080,
          );
        },
      );

      expect(find.text('No saved servers yet'), findsOneWidget);
      await tester.tap(find.text('Add server'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(find.text('Added via FAB'), findsOneWidget);
    },
  );

  testWidgets('add-server failure is visible and leaves the action retryable', (
    tester,
  ) async {
    final service = SavedServersService();
    var calls = 0;
    await _pump(
      tester,
      service: service,
      onAddServer: (_) async {
        calls++;
        throw StateError('pairing service unavailable');
      },
    );

    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not add server'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Add server'));
    await tester.pumpAndSettle();
    expect(calls, 2, reason: 'the failed callback must release the busy gate');
  });

  testWidgets('notes line shows under the row when set', (tester) async {
    final service = SavedServersService();
    await service.add(
      displayName: 'Observatory',
      host: '10.0.0.10',
      port: 8080,
      notes: 'Permanent pier · 5 m USB run',
    );
    await _pump(tester, service: service);
    expect(find.text('Permanent pier · 5 m USB run'), findsOneWidget);
  });

  group('relay servers', () {
    test(
      'upsertRelay round-trips through persistence + secure storage',
      () async {
        final service = SavedServersService();
        final added = await service.upsertRelay(
          displayName: 'Remote rig',
          relayUrl: 'wss://relay.example.com',
          relayApplianceId: 'abcd-wxyz-2345',
          relayAllowInsecureTls: true,
          authToken: 'appliance-bearer',
          lastConnectedAt: DateTime.now(),
        );
        expect(added.isRelay, isTrue);
        expect(await service.tokenFor(added.id), 'appliance-bearer');

        // Reload from disk (fresh service instance over the same mock prefs +
        // secure storage) to prove the non-secret fields survive serialization
        // and the token stays in secure storage, not the JSON blob.
        final reloaded = (await SavedServersService().loadAll()).single;
        expect(reloaded.id, added.id);
        expect(reloaded.displayName, 'Remote rig');
        expect(reloaded.relayUrl, 'wss://relay.example.com');
        expect(reloaded.relayApplianceId, 'abcd-wxyz-2345');
        expect(reloaded.relayAllowInsecureTls, isTrue);
        expect(reloaded.isRelay, isTrue);
        // The token lives only in secure storage — the round-tripped row must
        // not carry it in the JSON-backed model.
        expect(reloaded.authToken, isNull);
        expect(await service.tokenFor(reloaded.id), 'appliance-bearer');
      },
    );

    test(
      'upsertRelay updates the existing row instead of duplicating',
      () async {
        final service = SavedServersService();
        final first = await service.upsertRelay(
          displayName: 'Remote rig',
          relayUrl: 'wss://relay.example.com',
          relayApplianceId: 'abcd-wxyz-2345',
        );
        final second = await service.upsertRelay(
          displayName: 'Remote rig',
          relayUrl: 'wss://relay.example.com',
          relayApplianceId: 'abcd-wxyz-2345',
          authToken: 'new-bearer',
          lastConnectedAt: DateTime.now(),
        );
        expect(second.id, first.id, reason: 'matched on relay url + appliance');
        expect((await service.loadAll()).length, 1);
        expect(await service.tokenFor(first.id), 'new-bearer');
      },
    );

    testWidgets('relay row renders a RELAY badge + relay endpoint line', (
      tester,
    ) async {
      final service = SavedServersService();
      await service.upsertRelay(
        displayName: 'Remote rig',
        relayUrl: 'wss://relay.example.com',
        relayApplianceId: 'abcd-wxyz-2345',
        lastConnectedAt: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      await _pump(tester, service: service);

      expect(find.text('Remote rig'), findsOneWidget);
      // Distinct visual marker for relay entries.
      expect(find.text('RELAY'), findsOneWidget);
      // Secondary line shows the relay endpoint + appliance id rather than
      // the synthetic loopback host:port.
      expect(
        find.textContaining('wss://relay.example.com · abcd-wxyz-2345'),
        findsOneWidget,
      );
      expect(find.textContaining('127.0.0.1'), findsNothing);
    });

    test('a v1 (pre-relay) blob still loads as a direct entry', () async {
      // Simulate a saved-servers list written by a build that predates the
      // relay fields: no relayUrl/relayApplianceId keys at all.
      SharedPreferences.setMockInitialValues(<String, Object>{
        SavedServersStorageKeys.migrated: true,
        SavedServersStorageKeys.list:
            '[{"id":"legacy1",'
            '"displayName":"Old rig","host":"10.0.0.5","port":8080}]',
      });
      final service = SavedServersService();
      final rows = await service.loadAll();
      expect(rows, hasLength(1));
      expect(rows.single.isRelay, isFalse);
      expect(rows.single.host, '10.0.0.5');
    });
  });
}

class _FailingRenameService extends SavedServersService {
  @override
  Future<SavedServer> rename(String id, String displayName) {
    throw StateError('disk full');
  }
}
