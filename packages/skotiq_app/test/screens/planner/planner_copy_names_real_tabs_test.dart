// Any user-visible copy under screens/planner that sends the reader to a NAMED
// tab must name a tab PlannerTab actually renders.
//
// Both directions are easy to get wrong: "Plan Tonight tells you to use Plan
// Tonight" is circular, and "build one in the Target Queue tab" names a tab that
// does not exist — Target Queue lives inside Schedule
// (planner_screen_parts/_schedule_tab.dart), leaving `plannerTabTargetQueue` as
// an orphan string with no live UI referent. This test is the check against the
// tab list.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/planner/planner_screen.dart';

/// The tab names this build renders, as `PlannerTab` + the English labels in
/// `translations.dart` (`plannerTab*`).
const _renderedTabLabels = <String>{
  'Tonight',
  'Projects',
  'Schedule',
  'Framing',
  'Planetarium',
  'Your sky',
};

/// Lines that are pure comments carry design history, not directions to the
/// operator, so they are exempt.
bool _isComment(String line) {
  final t = line.trimLeft();
  return t.startsWith('//') || t.startsWith('*') || t.startsWith('/*');
}

void main() {
  test('the tab-label set matches PlannerTab', () {
    // If a tab is added or renamed, this fails first and points at the list
    // above rather than letting the copy check silently go stale.
    expect(PlannerTab.values, hasLength(_renderedTabLabels.length));
  });

  test('no planner copy sends the reader to a tab that does not exist', () {
    final dir = Directory('lib/screens/planner');
    expect(dir.existsSync(), isTrue, reason: 'run from packages/skotiq_app');

    // "Foo tab" / "Foo Bar tab" — a capitalised proper name immediately before
    // the word "tab" is a direction to a specific tab.
    final namedTab = RegExp(r'\b([A-Z][A-Za-z]*(?: [A-Z][A-Za-z]*)*) tab\b');
    // Words that read as "this tab"/"each tab" rather than a tab's name, plus
    // "Planner tab", which appears only in an `assert` message addressed to a
    // developer editing the enum — never to an operator.
    const generic = {
      'Each',
      'The',
      'This',
      'That',
      'A',
      'Its',
      'One',
      'Planner',
    };

    final offenders = <String>[];
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (_isComment(line)) continue;
        for (final match in namedTab.allMatches(line)) {
          final name = match.group(1)!;
          if (generic.contains(name)) continue;
          // Allow a trailing generic word ("The Discover tab" -> Discover).
          final trimmed = name.split(' ').last;
          if (_renderedTabLabels.contains(name) ||
              _renderedTabLabels.contains(trimmed)) {
            continue;
          }
          offenders.add('${entity.path}:${i + 1}: "$name tab"');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'these strings direct the operator to a tab Plan Tonight does '
          'not render (tabs: ${_renderedTabLabels.join(", ")})',
    );
  });

  // Naming a REAL surface is not enough if the copy also points a direction:
  // "build one in the Scheduler queue below" is true only at a stacked width,
  // while at 1600x900 the Scheduler queue panel occupies the right-hand column,
  // starting at the same y as the card. These layouts are responsive by design,
  // so no string in them can own a direction.
  test('no planner copy points the reader in a physical direction', () {
    final dir = Directory('lib/screens/planner');
    expect(dir.existsSync(), isTrue, reason: 'run from packages/skotiq_app');

    // A direction word immediately after a named surface: "… queue below",
    // "… panel above", "… list on the right".
    final direction = RegExp(
      r'\b(below|above|beneath|underneath|to the (?:left|right)|'
      r'on the (?:left|right))\b',
      caseSensitive: false,
    );

    final offenders = <String>[];
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (_isComment(line)) continue;
        // Only user-visible copy: a quoted string. Identifiers and parameter
        // names that happen to contain "above" are not directions.
        if (!line.contains("'") && !line.contains('"')) continue;
        for (final match in direction.allMatches(line)) {
          // "above/below the horizon|meridian" is astronomy, not layout.
          // Copy strings wrap across concatenated literals, so the words
          // may continue on the next source line ("…above the ' + 'horizon");
          // join one line ahead and strip the quotes before exempting.
          var rest = line.substring(match.end);
          if (i + 1 < lines.length) {
            rest = '$rest ${lines[i + 1]}';
          }
          final restText = rest.replaceAll(RegExp('["\']'), '');
          if (RegExp(r'^\s*the\s+(?:horizon|meridian)').hasMatch(restText)) {
            continue;
          }
          offenders.add('${entity.path}:${i + 1}: "${match.group(0)}"');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'a responsive layout cannot promise where another panel sits; '
          'name the surface and the tab instead',
    );
  });
}
