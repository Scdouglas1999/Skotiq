import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('a desktop names the shortcut after the label', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    expect(shortcutSuffix('Z'), ' (Ctrl+Z)');
    expect(shortcutSuffix('Z', or: true), ' (or Ctrl+Z)');
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    expect(shortcutSuffix('K'), ' (⌘K)');
  });

  test('a phone or tablet names no shortcut', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(shortcutSuffix('Z'), isEmpty);
      expect(shortcutSuffix('Z', or: true), isEmpty);
    }
  });
}
