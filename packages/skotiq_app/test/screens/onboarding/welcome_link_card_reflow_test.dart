// The Welcome step's "link to another computer" card at a phone's width: the
// button took the row and left the heading a letter or two per line.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/welcome_step.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _Relauncher implements AppRelauncher {
  @override
  Future<bool> relaunch({required String reason}) async => false;
}

Future<void> _pump(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appRelauncherProvider.overrideWithValue(_Relauncher()),
        allProfilesProvider.overrideWith((ref) => Stream.value(const [])),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: OnboardingWelcomeStep()),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  for (final width in [360.0, 390.0, 1200.0]) {
    testWidgets('at $width px the heading keeps its words on a line',
        (tester) async {
      await _pump(tester, width);
      expect(find.byKey(const ValueKey('onboarding.linkRig')), findsOneWidget);

      final heading = find.text('Is your rig plugged into another computer?');
      final lineHeight = tester
          .renderObject<RenderParagraph>(heading)
          .getFullHeightForCaret(TextPosition(offset: 0));
      final lines = (tester.getSize(heading).height / lineHeight).round();
      expect(lines, lessThanOrEqualTo(2), reason: '$lines lines at $width');
      expect(find.text('Connect to an imaging computer'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
