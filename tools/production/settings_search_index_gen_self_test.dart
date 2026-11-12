// Self-test for tools/production/settings_search_index_gen.dart.
//
// Run: dart run tools/production/settings_search_index_gen_self_test.dart
//
// Guards the staleness check plus the three parsing traps that each silently
// emptied part of the index while the generator still exited 0 — the failure
// mode that matters here is a generator that looks like it worked.
import 'dart:io';

int _failures = 0;

void _check(String what, bool ok, [String? detail]) {
  if (ok) {
    stdout.writeln('  ok   $what');
    return;
  }
  _failures++;
  stdout.writeln('  FAIL $what${detail == null ? '' : ' — $detail'}');
}

void main() {
  final root = _repoRoot();
  final generated = File(
    '$root/packages/skotiq_app/lib/screens/settings/settings_search_index.g.dart',
  );

  stdout.writeln('settings_search_index_gen self-test');

  // 1. The committed index must match a fresh generation, or the Settings
  //    search box silently cannot find whatever changed.
  final check = Process.runSync('dart', [
    'run',
    'tools/production/settings_search_index_gen.dart',
    '--check',
  ], workingDirectory: root);
  _check(
    'generated index is up to date',
    check.exitCode == 0,
    '${check.stdout}${check.stderr}'.trim(),
  );

  if (!generated.existsSync()) {
    stdout.writeln('  FAIL generated index is missing');
    exit(1);
  }
  final index = generated.readAsStringSync();

  // 2. The exact terms observed returning "No settings match your search" on
  //    the running app while the setting was visibly on screen.
  for (final term in const [
    'Safety fail mode',
    'Park on unsafe weather',
    'Default watermark template',
    'Default thumbnail size',
  ]) {
    _check('indexes "$term"', index.contains(term));
  }

  // 3. Nested-call lookback. `_OverrideField(key: ValueKey('x'),
  //    label: '...')` closes an inner call before the label, so a naive
  //    "nearest preceding constructor" read answers ValueKey and rejects the
  //    label. That dropped the whole Adaptive Exposure page. Checked inside
  //    that page's own list: "min s" is its per-filter override field.
  final adaptive = RegExp(
    r"'adaptive-exposure': \[(.*?)\],",
    dotAll: true,
  ).firstMatch(index)?.group(1);
  _check(
    'resolves labels past a closed nested call',
    adaptive != null && adaptive.contains("'min s'"),
  );

  // 4. Composition following. Files & Storage and Autofocus render no rows of
  //    their own; they stack other settings pages inside a shared shell.
  for (final key in const ['files-storage', 'autofocus']) {
    _check("indexes composed page '$key'", index.contains("'$key': ["));
  }

  // 4b. A page outside screens/settings/ is followed through its own feature
  //     folder. Equipment profiles is the profile manager under
  //     screens/equipment/ and its settings are the profile editor's rows;
  //     not followed, the section indexed nothing at all.
  final profiles = RegExp(
    r"'equipment-profiles': \[(.*?)\],",
    dotAll: true,
  ).firstMatch(index)?.group(1);
  for (final term in const ['Optical train', 'Camera defaults']) {
    _check(
      'indexes the profile editor\'s "$term" under Equipment profiles',
      profiles != null && profiles.contains("'$term'"),
    );
  }

  // 5. Button verbs must NOT be indexed, or "delete" matches settings pages.
  for (final verb in const [
    "    'Cancel',",
    "    'Delete',",
    "    'Rename',",
  ]) {
    _check(
      'does not index the bare verb ${verb.trim()}',
      !index.contains(verb),
    );
  }

  stdout.writeln(
    _failures == 0
        ? 'PASS'
        : 'FAIL ($_failures check${_failures == 1 ? '' : 's'})',
  );
  exit(_failures == 0 ? 0 : 1);
}

String _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    if (File('${dir.path}/melos.yaml').existsSync()) return dir.path;
    dir = dir.parent;
  }
  stderr.writeln('error: could not locate repo root');
  exit(2);
}
