import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/shell/shell_chrome.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  group('ShellChrome', () {
    test('system decorations only on Linux with the variable set to 1', () {
      bool on({required bool linux, Map<String, String> env = const {}}) =>
          ShellChrome.usesSystemDecorationsFor(
            isLinux: linux,
            environment: env,
          );
      expect(on(linux: true), isFalse);
      expect(on(linux: true, env: {'SKOTIQ_SYSTEM_DECORATIONS': '1'}), isTrue);
      expect(on(linux: true, env: {'SKOTIQ_SYSTEM_DECORATIONS': '0'}), isFalse);
      expect(
        on(linux: false, env: {'SKOTIQ_SYSTEM_DECORATIONS': '1'}),
        isFalse,
      );
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
