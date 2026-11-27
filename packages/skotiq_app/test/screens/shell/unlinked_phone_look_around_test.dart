// "Look around without a rig": a phone that is not linked browses the whole
// shell. The rig's data is refused there (the phone's database holds none of
// it), and every screen still opens.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/analytics/analytics_screen.dart';
import 'package:skotiq_app/screens/imaging/imaging_screen.dart';
import 'package:skotiq_app/screens/night_control/night_control_screen.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';
import 'package:skotiq_app/screens/sequencer/sequencer_screen.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final screens = <String, Widget Function()>{
    'Tonight': () => const NightControlScreen(),
    'Imaging': () => const ImagingScreen(),
    'Sequencer': () => const SequencerScreen(),
    'Planner': () => const PlannerScreen(),
    'History': () => const AnalyticsScreen(),
  };

  for (final MapEntry(key: name, value: screen) in screens.entries) {
    testWidgets('$name opens on a phone that is not linked', (tester) async {
      final handle = await pumpAppScreen(
        tester,
        screen(),
        size: const Size(390, 844),
        settle: false,
        extraOverrides: [
          launchRoleProvider.overrideWithValue(LaunchRole.mobile),
          backendProvider.overrideWith(
            (ref) => TestBackendNotifier(ref, DisconnectedBackend()),
          ),
        ],
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(tester.takeException(), isNull);
      expect(find.byType(ErrorWidget), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      handle.container.dispose();
      await tester.pump(const Duration(minutes: 1));
    });
  }
}
