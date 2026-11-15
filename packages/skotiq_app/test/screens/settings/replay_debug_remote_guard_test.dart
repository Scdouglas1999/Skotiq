import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/replay_debug_settings.dart'
    as replay_ui;
import 'package:skotiq_core/providers.dart';

import '../../harness/harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('remote Replay settings expose host-backed controls',
      (tester) async {
    await pumpAppScreen(
      tester,
      const replay_ui.ReplayDebugSettings(),
      extraOverrides: [
        isRemoteModeProvider.overrideWithValue(true),
        replayDebugEnabledProvider.overrideWith((ref) async => false),
        replayDebugRetentionDaysProvider.overrideWith((ref) async => 30),
      ],
    );

    expect(find.text('Imaging host only'), findsNothing);
    expect(find.text('Replay decision logging'), findsOneWidget);
    expect(find.text('Clear all replay history'), findsWidgets);
  });
}
