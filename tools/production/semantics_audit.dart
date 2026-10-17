// Fails when a design-system component is operable but says nothing about itself.
//
// WHY THIS EXISTS
// ---------------
// A design-system control built from a bare `GestureDetector` — no
// `Semantics`, no `toggled` state, nothing focusable — costs far more than
// itself: measured on the running app, one such switch left the entire
// Settings screen with ZERO checkable nodes and five focusable ones, so a
// keyboard-only user could not reach any of the 664 setting rows and a screen
// reader could not report whether any of them was on or off.
//
// These are the most-used controls in the product, and most sibling components
// in the same directory DO wrap themselves in `Semantics` — so a bare one is
// an omission rather than a decision, and an omission recurs unless something
// fails.
//
// The rule: a component that handles a tap must either describe itself with
// `Semantics`, or delegate to a widget that does (Material's own widgets, or
// another Skotiq component that is itself covered).
//
// USAGE
//   dart run tools/production/semantics_audit.dart
//   dart run tools/production/semantics_audit.dart --check   # exit 1 on violation
import 'dart:io';

const _componentsDir = 'packages/skotiq_ui/lib/src/components';

/// Widgets that carry their own accessibility semantics, so a component that
/// merely wraps one is already covered and does not need its own annotation.
///
/// Matched on a WORD BOUNDARY, which is load-bearing. A plain substring test
/// excused `skotiq_switch.dart` because `SkotiqSwitch(` contains
/// `Switch(`, and `skotiq_checkbox.dart` because `SkotiqCheckbox(`
/// contains `Checkbox(` — so the first version of this audit passed the two
/// components it was written to catch.
final _semanticDelegates = RegExp(
  r'\b('
  r'Semantics|MergeSemantics|'
  r'ElevatedButton|FilledButton|OutlinedButton|TextButton|IconButton|'
  r'ListTile|SwitchListTile|CheckboxListTile|RadioListTile|'
  r'Checkbox|Switch|Radio|Tooltip|Slider|DropdownButton|'
  r'TextField|TextFormField'
  r')\s*[(<]',
);

/// Components that are legitimately decorative even though they take a callback.
///
/// Kept deliberately tiny and justified: an allowlist is how this kind of audit
/// rots into a rubber stamp.
const _allowed = <String, String>{
  'skotiq_tooltip.dart':
      'renders a hover surface for another control; the control it decorates '
      'carries the semantics.',
};

final _interactive = RegExp(r'GestureDetector|InkWell|onTap:|onPressed:');

void main(List<String> args) {
  final root = _findRepoRoot();
  if (root == null) {
    stderr.writeln('error: could not locate repo root (no melos.yaml found)');
    exit(2);
  }

  final dir = Directory('$root/$_componentsDir');
  if (!dir.existsSync()) {
    stderr.writeln('error: $_componentsDir not found');
    exit(2);
  }

  final violations = <String>[];
  var checked = 0;
  for (final file in dir.listSync().whereType<File>().where(
    (f) => f.path.endsWith('.dart'),
  )) {
    final name = file.uri.pathSegments.last;
    final src = file.readAsStringSync();
    if (!_interactive.hasMatch(src)) continue;
    checked++;
    if (_allowed.containsKey(name)) continue;
    if (_semanticDelegates.hasMatch(src)) continue;
    violations.add(name);
  }

  violations.sort();
  if (violations.isEmpty) {
    stdout.writeln(
      'semantics audit: $checked interactive components, all '
      'described',
    );
    return;
  }

  stderr.writeln(
    'error: ${violations.length} of $checked interactive components in '
    '$_componentsDir handle a tap but expose no accessibility semantics, so a '
    'keyboard or screen-reader user cannot reach or read them:',
  );
  for (final v in violations) {
    stderr.writeln('  - $v');
  }
  stderr.writeln(
    '\nFix: wrap the tappable subtree in Semantics(...) describing what the '
    'control is and its current state (button:/toggled:/checked:/enabled:), and '
    'make it focusable so keyboard traversal reaches it. See skotiq_button '
    'or nav_item for the established pattern.',
  );
  exit(args.contains('--check') ? 1 : 0);
}

String? _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/melos.yaml').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}
