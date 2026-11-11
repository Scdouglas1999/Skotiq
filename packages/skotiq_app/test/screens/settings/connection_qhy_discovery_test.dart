// Settings > Connection carries the QHY switch: a computer where the QHY SDK
// crashes or hangs while enumerating can leave QHY devices out of scans.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/connection_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

Future<HarnessHandle> _pump(WidgetTester tester, {required bool? sdk}) async {
  final handle = await pumpAppScreen(
    tester,
    const ConnectionSettings(),
    size: const Size(1280, 1600),
    extraOverrides: [
      appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
      qhySdkAvailableProvider.overrideWith((ref) async => sdk),
    ],
  );
  await tester.pumpAndSettle();
  return handle;
}

void main() {
  testWidgets('on by default, and turning it off is saved', (tester) async {
    final handle = await _pump(tester, sdk: true);
    final row = find.text('Look for QHY cameras');
    expect(row, findsOneWidget);
    expect(
      find.textContaining('crashes or hangs in the QHY SDK'),
      findsOneWidget,
    );
    final toggle = find.descendant(
      of: find.ancestor(of: row, matching: find.byType(SettingRow)),
      matching: find.byType(SettingsSwitch),
    );
    expect(tester.widget<SettingsSwitch>(toggle).value, isTrue);

    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pump(SettingsSwitch.writeDelay);
    await tester.pumpAndSettle();
    expect(
      handle.container.read(appSettingsProvider).requireValue
          .qhyDiscoveryEnabled,
      isFalse,
    );
  });

  testWidgets('says when the SDK is not installed here', (tester) async {
    await _pump(tester, sdk: false);
    expect(
      find.textContaining('The QHY SDK is not installed on this computer'),
      findsOneWidget,
    );
  });
}
