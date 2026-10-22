import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_app/screens/settings/widgets/host_settings_notice.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

Future<void> _pump(
  WidgetTester tester,
  HostSettingsStoreSupport? support,
) async {
  await pumpAppScreen(
    tester,
    const SettingsScreen(),
    size: const Size(1280, 800),
    extraOverrides: [
      appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
      hostSettingsStoreSupportProvider.overrideWith((ref) async => support),
    ],
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a host too old to share its settings is named in Settings', (
    tester,
  ) async {
    await _pump(tester, HostSettingsStoreSupport.legacy);

    expect(find.textContaining(HostSettingsNotice.title), findsOneWidget);
  });

  testWidgets('nothing is shown when the host shares every setting', (
    tester,
  ) async {
    await _pump(tester, HostSettingsStoreSupport.full);

    expect(find.textContaining(HostSettingsNotice.title), findsNothing);
  });

  testWidgets('nothing is shown on the machine that owns the hardware', (
    tester,
  ) async {
    await _pump(tester, null);

    expect(find.textContaining(HostSettingsNotice.title), findsNothing);
  });
}
