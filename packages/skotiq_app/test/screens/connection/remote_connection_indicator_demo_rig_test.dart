// A phone on the demo rig says so wherever the link indicator sits, so a
// screenshot of simulated equipment is never taken for a real rig: a flask
// badge on a phone, where the word would crowd the page title, and the word
// "Demo" beside it on anything wider.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_app/screens/connection/remote_connection_indicator.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/pump_app_screen.dart';

void main() {
  for (final (label, indicator) in [
    ('dot', const RemoteConnectionIndicator(dot: true)),
    ('compact', const RemoteConnectionIndicator(compact: true)),
  ]) {
    testWidgets('the $label indicator reads Demo on the demo rig', (
      tester,
    ) async {
      final demo = DemoBackend(latitudeDeg: 40, longitudeDeg: -105);
      addTearDown(demo.dispose);
      await pumpAppScreen(
        tester,
        Align(alignment: Alignment.topRight, child: indicator),
        size: const Size(400, 800),
        settle: false,
        extraOverrides: [
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, demo),
          ),
        ],
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(LucideIcons.flaskConical), findsOneWidget);
      expect(find.text('Demo'), findsNothing);
      expect(find.bySemanticsLabel(RegExp('Demo rig')), findsOneWidget);

      await tester.tap(find.byType(RemoteConnectionIndicator));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.textContaining('This phone is running the demo rig'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Settings > Replay & debug > Testing'),
        findsOneWidget,
      );
    });
  }

  testWidgets('no backend still shows the plain dot', (tester) async {
    await pumpAppScreen(
      tester,
      const Align(
        alignment: Alignment.topRight,
        child: RemoteConnectionIndicator(dot: true),
      ),
      size: const Size(400, 800),
      settle: false,
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Demo'), findsNothing);
  });

  testWidgets('wider than a phone, the badge also says Demo', (tester) async {
    final demo = DemoBackend(latitudeDeg: 40, longitudeDeg: -105);
    addTearDown(demo.dispose);
    await pumpAppScreen(
      tester,
      const Align(
        alignment: Alignment.topRight,
        child: RemoteConnectionIndicator(compact: true),
      ),
      size: const Size(900, 800),
      settle: false,
      extraOverrides: [
        backendProvider.overrideWith((ref) => TestBackendNotifier(ref, demo)),
      ],
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Demo'), findsOneWidget);
  });
}
