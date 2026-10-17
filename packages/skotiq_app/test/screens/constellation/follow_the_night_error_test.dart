import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/constellation/constellation_screen.dart';
import 'package:skotiq_app/screens/constellation/constellation_ui_providers.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

void main() {
  testWidgets('follow-the-night failure stays visible and can be retried',
      (tester) async {
    var attempts = 0;

    await pumpAppScreen(
      tester,
      const ConstellationView(),
      extraOverrides: [
        constellationConfiguredProvider.overrideWith((ref) async => true),
        constellationHubInfoProvider.overrideWith((ref) async => null),
        constellationDisplayNameProvider.overrideWith((ref) async => ''),
        isConstellationHostActionEnabledProvider.overrideWithValue(false),
        sharedTargetsProvider.overrideWith((ref) async => const []),
        followTheNightProvider(-1).overrideWith((ref) async {
          attempts++;
          if (attempts == 1) throw Exception('handoff feed offline');
          return const [];
        }),
      ],
    );

    expect(find.textContaining("Could not check tonight's handoffs"),
        findsOneWidget);
    expect(find.text('Retry handoffs'), findsOneWidget);
    expect(attempts, 1);

    await tester.tap(find.text('Retry handoffs'));
    await tester.pumpAndSettle();

    expect(attempts, 2);
    expect(find.textContaining("Could not check tonight's handoffs"),
        findsNothing);
  });
}
