// A connected device's card lists the workarounds its driver applies, in the
// details section, folded away until asked for.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_app/screens/equipment/widgets/connected_device_card.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

const _deviceId = 'native:zwo:0';

Future<ProviderContainer> _pumpOpenDetails(
  WidgetTester tester,
  Future<List<DeviceQuirk>> Function() quirks,
) async {
  final container = ProviderContainer(
    overrides: [
      inMemoryDatabaseOverride(),
      deviceQuirksProvider.overrideWith((ref, id) => quirks()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        localizationsDelegates: SkotiqLocalizations.localizationsDelegates,
        supportedLocales: SkotiqLocalizations.supportedLocales,
        home: const Scaffold(
          body: SingleChildScrollView(
            child: ConnectedDeviceCard(type: DeviceType.safetyMonitor),
          ),
        ),
      ),
    ),
  );
  final notifier = container.read(safetyMonitorStateProvider.notifier);
  notifier.setConnecting(_deviceId, 'ZWO ASI294MC Pro');
  notifier.setConnected();
  await tester.pumpAndSettle();

  expect(find.text('Workarounds'), findsNothing,
      reason: 'the details, and the workarounds in them, start folded away');
  await tester.tap(find.byTooltip('More actions'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Show details'));
  await tester.pump();
  return container;
}

void main() {
  testWidgets('lists the workarounds behind Show', (tester) async {
    await _pumpOpenDetails(
      tester,
      () async => const [
        DeviceQuirk(
          category: 'Temperature',
          description: 'First temperature read unreliable',
        ),
        DeviceQuirk(
            category: 'Timing', description: '200ms delay after connect'),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Workarounds'), findsOneWidget);
    expect(find.text('2 applied'), findsOneWidget);
    expect(
      find.textContaining('First temperature read', findRichText: true),
      findsNothing,
    );

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('First temperature read unreliable',
          findRichText: true),
      findsOneWidget,
    );
    expect(
      find.textContaining('200ms delay after connect', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('says so while it is asking', (tester) async {
    final pending = Completer<List<DeviceQuirk>>();
    await _pumpOpenDetails(tester, () => pending.future);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Checking…'), findsOneWidget);
    pending.complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets('a model with no quirks says none', (tester) async {
    await _pumpOpenDetails(tester, () async => const []);
    await tester.pumpAndSettle();
    expect(find.text('None for this model'), findsOneWidget);
    expect(find.text('Show'), findsNothing);
  });

  testWidgets('a failed read says why', (tester) async {
    await _pumpOpenDetails(
      tester,
      () async => throw Exception('the imaging host did not answer'),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not be read: '),
      findsOneWidget,
    );
  });
}
