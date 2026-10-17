// The search affordance must not advertise a key the keyboard does not have.
//
// A hardcoded '⌘K' chip on the planetarium search field and the command bar's
// Search control tells a Linux or Windows operator to press the Apple Command
// key. The handler accepts Meta OR Control; only the label can be wrong.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planetarium/widgets/redesign/command_bar.dart';
import 'package:skotiq_app/screens/planetarium/widgets/search_header.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Pumps the search header as [platform] and hands back the badge text.
  ///
  /// The override is cleared inside the test body: flutter_test asserts every
  /// foundation debug variable is unset by the time the body returns, so a
  /// tearDown would be too late.
  Future<String> badgeTextOn(WidgetTester tester, TargetPlatform platform,
      {required String expected}) async {
    debugDefaultTargetPlatformOverride = platform;
    try {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(
              body: Builder(
                builder: (context) => SearchHeader(
                  colors: SkotiqColors.of(context),
                  controller: controller,
                  onSearch: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text(expected), findsOneWidget);
      return expected;
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('desktop Linux advertises Ctrl+K, not the Command glyph',
      (tester) async {
    await badgeTextOn(tester, TargetPlatform.linux, expected: 'Ctrl+K');
    expect(find.text('⌘K'), findsNothing);
  });

  testWidgets('Windows advertises Ctrl+K', (tester) async {
    await badgeTextOn(tester, TargetPlatform.windows, expected: 'Ctrl+K');
    expect(find.text('⌘K'), findsNothing);
  });

  testWidgets('macOS keeps the Command glyph', (tester) async {
    await badgeTextOn(tester, TargetPlatform.macOS, expected: '⌘K');
    expect(find.text('Ctrl+K'), findsNothing);
  });

  // The command bar's badge is the SECOND site. Its only other pin locates the
  // control with `find.text(shortcutLabel('K'))`, which is a tautology on a
  // macOS runner: shortcutLabel would return the Command glyph and a hardcoded
  // one would still match. Pin it against an explicit platform instead.
  testWidgets('the command bar badge is platform-derived too', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    try {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1400, 800);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: SkotiqTheme.dark,
            home: Scaffold(
              body: PlanetariumCommandBar(
                compact: false,
                layersOpen: false,
                panelOpen: false,
                showFov: false,
                onToggleLayers: () {},
                onTogglePanel: () {},
                onOpenSearch: () {},
                onToggleFov: () {},
                onResetView: () {},
                onExportChart: () {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Ctrl+K'), findsOneWidget);
      expect(find.text('⌘K'), findsNothing);
      // The wider label must not push the fixed-width search chip over.
      expect(tester.takeException(), isNull);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('the label helper is a pure function of the platform', () {
    try {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      expect(shortcutLabel('K'), 'Ctrl+K');
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(shortcutLabel('K'), 'Ctrl+K');
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(shortcutLabel('K'), '⌘K');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(shortcutLabel('K'), '⌘K');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
