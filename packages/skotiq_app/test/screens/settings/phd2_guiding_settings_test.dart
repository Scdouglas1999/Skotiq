import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/phd2_guiding_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

Finder get _phd2BrowseButton => find.descendant(
      of: find.byKey(const ValueKey('phd2_executable_path')),
      matching: find.byType(GestureDetector),
    );

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this._initial);

  final AppSettingsState _initial;

  @override
  Future<AppSettingsState> build() async => _initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'remote PHD2 browse collects and saves an executable path on the host',
    (tester) async {
      final handle = await pumpAppScreen(
        tester,
        const Phd2GuidingSettings(),
        extraOverrides: [
          appSettingsProvider.overrideWith(
            () => _StubAppSettingsNotifier(const AppSettingsState()),
          ),
          isRemoteModeProvider.overrideWithValue(true),
        ],
      );

      await tester.tap(_phd2BrowseButton);
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('PHD2 executable on imaging host'), findsOneWidget);
      expect(
        find.textContaining('controlling device are not visible'),
        findsOneWidget,
      );

      const hostPath = r'C:\Program Files\PHD2\PHD2.exe';
      await tester.enterText(
        find.byKey(const ValueKey('remote_host_path_input')),
        hostPath,
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('remote_host_path_submit')));
      await tester.pump(const Duration(milliseconds: 500));

      expect(
        handle.container.read(appSettingsProvider).value?.phd2Path,
        hostPath,
      );
      expect(find.text(hostPath), findsWidgets);
    },
  );

  testWidgets('remote PHD2 path can be cleared to restore auto-detection',
      (tester) async {
    const initial = AppSettingsState(phd2Path: '/opt/phd2/bin/phd2');
    final handle = await pumpAppScreen(
      tester,
      const Phd2GuidingSettings(),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(initial),
        ),
        isRemoteModeProvider.overrideWithValue(true),
      ],
    );

    await tester.tap(_phd2BrowseButton);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Use auto-detect'));
    await tester.pumpAndSettle();

    expect(
      handle.container.read(appSettingsProvider).value?.phd2Path,
      isEmpty,
    );
    expect(find.text('Auto-detect (optional)'), findsOneWidget);
  });
}
