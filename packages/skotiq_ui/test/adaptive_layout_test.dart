import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('panelWidthFromFraction', () {
    test('clamps fraction of available space', () {
      expect(
        panelWidthFromFraction(1000, fraction: 0.25, min: 200, max: 400),
        250,
      );
    });

    test('respects minimum', () {
      expect(
        panelWidthFromFraction(400, fraction: 0.1, min: 200, max: 500),
        200,
      );
    });

    test('respects maximum', () {
      expect(
        panelWidthFromFraction(2000, fraction: 0.5, min: 100, max: 400),
        400,
      );
    });

    test('the deprecated clampPanelWidth alias still delegates', () {
      // ignore: deprecated_member_use_from_same_package
      expect(
        // ignore: deprecated_member_use_from_same_package
        clampPanelWidth(1000, fraction: 0.25, min: 200, max: 400),
        panelWidthFromFraction(1000, fraction: 0.25, min: 200, max: 400),
      );
    });
  });

  group('dialogMaxWidth', () {
    testWidgets('returns design max when viewport is wide enough', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late double width;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              width = dialogMaxWidth(context, 900);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(width, 900);
    });

    testWidgets('caps design max at the shared dialog width fraction', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      late double width;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              width = dialogMaxWidth(context, 900);
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      expect(
        width,
        closeTo(800 * AdaptiveDialogConstraints.defaultWidthFraction, 0.01),
      );
    });
  });

  group('ShellChromeMetrics', () {
    test('shell layout breakpoint matches tablet token', () {
      expect(
        ShellChromeMetrics.shellLayoutBreakpoint,
        SkotiqTokens.breakpointTablet,
      );
    });

    test('bottom nav height is tokenized', () {
      expect(BottomNavMetrics.barHeight, 64.0);
    });

    test('bottom nav item metrics are tokenized', () {
      expect(BottomNavMetrics.itemIconSize, 21.0);
      expect(BottomNavMetrics.itemLabelFontSize, 11.0);
      expect(
        BottomNavMetrics.itemSelectionAnimationDuration,
        const Duration(milliseconds: 180),
      );
    });

    test('shell chrome heights match the Observatory grid', () {
      expect(ShellChromeMetrics.titleBarHeight, 44.0);
      expect(ShellChromeMetrics.statusBarHeight, 32.0);
      expect(ShellChromeMetrics.pageHeaderHeight, 56.0);
      expect(ShellChromeMetrics.railWidthCollapsed, 64.0);
      expect(ShellChromeMetrics.railItemSize, 40.0);
    });

    // Below the breakpoint the instrument bar is not mounted at all, so the
    // bottom chrome is the nav alone. Adding a status-bar height there
    // reserved 40px of window for a surface that is not there.
    test('content stack bottom chrome is the nav alone when narrow', () {
      expect(
        ShellChromeMetrics.contentStackBottomChromeHeight(useBottomNav: false),
        ShellChromeMetrics.statusBarHeight,
      );
      expect(
        ShellChromeMetrics.contentStackBottomChromeHeight(useBottomNav: true),
        BottomNavMetrics.barHeight,
      );
    });
  });
}
