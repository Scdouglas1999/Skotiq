// A settings dropdown must be able to show the value it currently holds.
//
// Live: Settings > Appearance > UI scale reads "Extra Lar..." whenever Extra
// Large (1.4x) is selected, because SettingsDropdown pinned the control to a
// 140 px design width regardless of how wide the label it has to render is.
// The one control whose whole job is to report a choice could not report it.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/appearance_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../../harness/harness.dart';

class _StubAppSettingsNotifier extends AppSettingsNotifier {
  _StubAppSettingsNotifier(this.initial);

  final AppSettingsState initial;

  @override
  Future<AppSettingsState> build() async => initial;
}

/// The width [finder]'s text needs, and the width it was actually given.
(double needed, double given) _fit(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  return (
    paragraph.getMaxIntrinsicWidth(double.infinity),
    paragraph.size.width
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the UI scale dropdown shows its selected value in full',
      (tester) async {
    await pumpAppScreen(
      tester,
      const AppearanceSettings(),
      size: const Size(1280, 900),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(
            const AppSettingsState(uiScale: 'Extra Large (1.4x)'),
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();

    final selected = find.descendant(
      of: find.byType(SkotiqDropdown),
      matching: find.text('Extra large 1.4×'),
    );
    expect(selected, findsWidgets);
    final (needed, given) = _fit(tester, selected.first);
    expect(
      given,
      greaterThanOrEqualTo(needed - 0.5),
      reason: 'the selected value is ellipsized: needs $needed, has $given',
    );
  });

  // The reported case: "UI scale" is applied as a TEXT scaler, so the label the
  // control has to render is 40% wider at Extra Large while a constant design
  // width is not. A fix that only measures at 1.0x would still read
  // "Extra Lar..." on the very machine that selected Extra Large.
  testWidgets('...and still shows it when the UI scale it names is in force',
      (tester) async {
    await pumpAppScreen(
      tester,
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(1.4)),
        child: AppearanceSettings(),
      ),
      size: const Size(1280, 900),
      extraOverrides: [
        appSettingsProvider.overrideWith(
          () => _StubAppSettingsNotifier(
            const AppSettingsState(uiScale: 'Extra Large (1.4x)'),
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();

    final selected = find.descendant(
      of: find.byType(SkotiqDropdown),
      matching: find.text('Extra large 1.4×'),
    );
    expect(selected, findsWidgets);
    final (needed, given) = _fit(tester, selected.first);
    expect(
      given,
      greaterThanOrEqualTo(needed - 0.5),
      reason: 'the selected value is ellipsized at 1.4x: '
          'needs $needed, has $given',
    );
    // Growing the control must not have traded the ellipsis for an overflow.
    expect(tester.takeException(), isNull);
  });
}
