import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/shell_chrome.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('ShellChrome', () {
    test('desktop width thresholds use shell layout breakpoint', () {
      const breakpoint = ShellChromeMetrics.shellLayoutBreakpoint;
      expect(ShellChrome.useBottomNavigation(breakpoint - 1), isTrue);
      expect(ShellChrome.useSideNavigation(breakpoint), isTrue);
      expect(ShellChrome.useBottomNavigation(breakpoint), isFalse);
    });

    test('shell layout breakpoint matches tablet token', () {
      expect(
        ShellChromeMetrics.shellLayoutBreakpoint,
        SkotiqTokens.breakpointTablet,
      );
      expect(
        ShellChromeMetrics.shellLayoutBreakpoint,
        BreakpointTokens.breakpointTablet,
      );
    });
  });
}
