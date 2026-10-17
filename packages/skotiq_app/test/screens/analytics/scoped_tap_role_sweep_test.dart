// No screen in the analytics family may ship a tap target that publishes no
// role.
//
// A bare `InkWell`/`GestureDetector` publishes a tap ACTION with no role and no
// enabled flag, and AT-SPI reads an absent enabled flag as "disabled". The live
// tree then reads `panel: Photometry [DISABLED]`, `panel: Field Quality
// [DISABLED]`, `panel: Anomalies [DISABLED]` for chips that work when clicked:
// a screen-reader user is told the control is unavailable, a mouse user finds
// it working.
//
// Pinning individual chips leaves the class alive, so this sweeps the whole
// surface. It is a source scan rather than a widget drive because most of these
// sites need a live database, a run, or a solved frame to render at all — the
// structural rule holds without any of that.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The directories this batch owns.
const _scoped = <String>[
  'lib/screens/analytics',
  'lib/screens/science',
  'lib/screens/session_review',
  'lib/screens/mosaic',
  'lib/screens/collaborative_sky',
  'lib/screens/suggestions',
  'lib/screens/transients',
  'lib/screens/diagnostics',
];

/// Sites that are drags, not taps: a lasso and a 3-D orbit have no button role
/// to declare and are operated by pointer only.
const _gestureOnly = <String>[
  'lib/screens/session_review/widgets/sub_cull_rail.dart',
  'lib/screens/analytics/widgets/science_surface_explorer.dart',
];

void main() {
  test('every tappable in this batch declares a role', () {
    expect(
      Directory('lib/screens').existsSync(),
      isTrue,
      reason: 'run from the skotiq_app package root',
    );

    final opener = RegExp(r'\b(InkWell|GestureDetector)\(');
    final offenders = <String>[];

    for (final dir in _scoped) {
      final root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (_gestureOnly.any(entity.path.endsWith)) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!opener.hasMatch(lines[i].split('//').first)) continue;
          // A `Semantics(` / `MergeSemantics(` within the enclosing widget
          // expression is what supplies the role. Fifteen lines back covers
          // every wrapping style in this tree (`return Semantics(` through
          // `Tooltip(message: …, child: Semantics(`).
          final window = lines.sublist(i < 15 ? 0 : i - 15, i + 1).join('\n');
          if (window.contains('Semantics(')) continue;
          offenders.add('${entity.path}:${i + 1}');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'these tap targets publish an action with no role, so assistive '
          'tech announces each as a disabled panel:\n${offenders.join('\n')}',
    );
  });
}
