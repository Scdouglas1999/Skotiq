import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

Future<Size> _buttonSize(WidgetTester tester, TargetPlatform platform) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: SkotiqTheme.dark.copyWith(platform: platform),
      home: Scaffold(
        body: SkotiqPanel(
          head: PanelHead(
            label: 'Weather safety',
            trailing: [
              SkotiqButton(
                label: 'Change',
                variant: ButtonVariant.ghost,
                size: ButtonSize.small,
                onPressed: () {},
              ),
            ],
          ),
          child: const SizedBox(height: 40),
        ),
      ),
    ),
  );
  return tester.getSize(find.byType(SkotiqButton));
}

void main() {
  testWidgets('a control in a panel head is a 48dp target on a phone', (
    tester,
  ) async {
    final size = await _buttonSize(tester, TargetPlatform.android);
    expect(size.height, greaterThanOrEqualTo(SkotiqTokens.minTouchTarget));
  });

  testWidgets('a panel head keeps its 20px row on desktop', (tester) async {
    await _buttonSize(tester, TargetPlatform.linux);
    expect(tester.getSize(find.byType(PanelHead)).height, PanelHead.height);
  });
}
