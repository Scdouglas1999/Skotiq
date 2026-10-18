// A settings page's own title block on desktop.
//
// Live at 1920x1080: under the "Settings" page header, each page stacked a
// second page-scale title ("General") and started a row lower than the search
// field beside it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/settings_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the page title is a section title level with the search field',
      (tester) async {
    await pumpAppScreen(
      tester,
      const SettingsScreen(),
      size: const Size(1648, 1080),
      extraOverrides: [
        appSettingsProvider.overrideWith(_StubAppSettingsNotifier.new),
      ],
    );

    final title = find.byWidgetPredicate(
      (widget) =>
          widget is Text &&
          widget.data == 'General' &&
          widget.style?.fontSize == SkotiqTypography.sectionTitle.fontSize &&
          widget.style?.fontWeight == SkotiqTypography.sectionTitle.fontWeight,
    );
    expect(title, findsOneWidget,
        reason: 'one page-scale title per screen: the header\'s "Settings"');

    final search = tester.getRect(find.byType(TextField).first);
    final titleRect = tester.getRect(title);
    expect(
      (titleRect.top - search.top).abs(),
      lessThan(SkotiqTokens.spaceMd),
      reason: 'the page starts on the same line as the nav beside it',
    );
  });
}
