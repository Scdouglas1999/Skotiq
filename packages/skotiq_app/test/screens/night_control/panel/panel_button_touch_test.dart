// The panel's quiet button is dense under a pointer and a full touch target
// on a phone or tablet, where Tonight is driven by a finger.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/night_control/panel/panel_widgets.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<Size> _buttonSize(WidgetTester tester, TargetPlatform platform) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark.copyWith(platform: platform),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 120,
            child: NightPanelButton(label: 'Copy link', onPressed: () {}),
          ),
        ),
      ),
    ),
  );
  return tester.getSize(find.byType(NightPanelButton));
}

void main() {
  testWidgets('on Android the button is at least the touch minimum tall',
      (tester) async {
    final size = await _buttonSize(tester, TargetPlatform.android);
    expect(size.height, greaterThanOrEqualTo(SkotiqTokens.minTouchTarget));
  });

  testWidgets('on a desktop the button keeps its dense height', (tester) async {
    final size = await _buttonSize(tester, TargetPlatform.linux);
    expect(size.height, NightPanelButton.pointerHeight);
  });
}
