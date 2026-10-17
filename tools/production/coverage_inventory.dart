// Enumerates every user-reachable unit of the product into a coverage ledger.
//
// WHY THIS EXISTS
// ---------------
// Successive "exhaustive" audits of this app kept finding new defects in areas a
// previous audit had declared done. The cause was not that the auditors were
// careless — it was that coverage was EXPLORATORY. Each pass wandered a path
// through the app, found bugs along that path, and reported it as complete. The
// next pass wandered a different path and found different bugs. Nothing recorded
// which of the app's several thousand controls had actually been exercised, so
// "done" could never mean anything.
//
// This tool makes coverage MECHANICAL instead. It derives, from the source, the
// full list of units a sweep has to visit — screens, settings sections and every
// row inside them, sequence instruction types, wizards, dialogs — and the
// interactive controls inside each. A sweep then marks units in
// `reports/coverage/status.json`, and `--report` prints what is still untouched.
// An area cannot be "declared done" while the ledger shows unvisited units in it,
// and the inventory regenerates from source so new features appear as untested
// rather than silently escaping the audit.
//
// USAGE
//   dart run tools/production/coverage_inventory.dart            # regenerate inventory
//   dart run tools/production/coverage_inventory.dart --report   # coverage report
//   dart run tools/production/coverage_inventory.dart --area sequencer
import 'dart:convert';
import 'dart:io';

const _appLib = 'packages/skotiq_app/lib';
const _searchIndexPath =
    'packages/skotiq_app/lib/screens/settings/settings_search_index.g.dart';
const _sequenceModelsDir = 'packages/skotiq_core/lib/src/models/sequence';
const _outDir = 'reports/coverage';

/// Widget constructors that a user can actually operate.
///
/// Deliberately excludes purely presentational widgets (Text, Icon, Card): the
/// ledger counts things a sweep has to TOUCH, and inflating it with labels would
/// make the coverage percentage meaningless.
const _controlPatterns = <String, String>{
  'switch': r'\bSwitchListTile\b|\bSwitch\(|\bSwitch\.adaptive\b',
  'checkbox': r'\bCheckboxListTile\b|\bCheckbox\(',
  'radio': r'\bRadioListTile\b|\bRadio<',
  'dropdown':
      r'\bDropdownButton\b|\bDropdownButtonFormField\b|\bDropdownMenu\b',
  'slider': r'\bSlider\(|\bRangeSlider\(',
  'textfield': r'\bTextField\(|\bTextFormField\(',
  'segmented': r'\bSegmentedButton<|\bToggleButtons\(',
  'button':
      r'\bElevatedButton\b|\bFilledButton\b|\bOutlinedButton\b|\bTextButton\b|\bIconButton\b',
  'menu': r'\bPopupMenuButton<|\bMenuAnchor\(',
  'tab': r'\bTab\(|\bTabBar\(',
  'tile': r'\bListTile\(|\bExpansionTile\(',
  'dialog': r'showDialog<|showModalBottomSheet<|\bAlertDialog\(',
  // Added 2026-08-09. Without these the ledger could only see Material-style
  // controls, so a surface built out of gestures over a CustomPainter — which
  // is the entire planetarium — registered as having nothing to touch. The sky
  // view contributed two units to a 402-unit ledger while being one of the
  // app's three headline features.
  'gesture': r'\bGestureDetector\(|\bInkWell\(|\bonTap:\s*(?!null)',
  'drag': r'\bDraggable<|\bLongPressDraggable<|\bDragTarget<|\bDismissible\(',
  'zoom-pan': r'\bInteractiveViewer\(|\bonScaleUpdate:|\bonPanUpdate:',
  'shortcut': r'\bCallbackAction<|\bShortcuts\(|\bSingleActivator\(',
};

void main(List<String> args) {
  final root = _findRepoRoot();
  if (root == null) {
    stderr.writeln('error: could not locate repo root (no melos.yaml found)');
    exit(2);
  }

  final inventory = _buildInventory(root);

  if (args.contains('--report') || args.contains('--area')) {
    _report(root, inventory, args);
    return;
  }

  final dir = Directory('$root/$_outDir')..createSync(recursive: true);
  File(
    '${dir.path}/inventory.json',
  ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(inventory));
  final units = (inventory['units'] as List).length;
  final controls = (inventory['units'] as List).fold<int>(
    0,
    (a, u) => a + ((u['controls'] as num?)?.toInt() ?? 0),
  );
  stdout.writeln(
    'wrote $_outDir/inventory.json — $units units, $controls interactive controls',
  );
}

Map<String, Object?> _buildInventory(String root) {
  final units = <Map<String, Object?>>[
    ..._screenUnits(root),
    ..._settingsUnits(root),
    ..._sequenceNodeUnits(root),
    ..._dirUnits(root, '$_appLib/widgets', 'widget', 'shared-widgets'),
    ..._dirUnits(root, 'apps/mobile/lib', 'mobile', 'mobile'),
    // The trees below are what make the swept total a statement about the
    // product rather than about one package's screen tree. They use
    // PATH-QUALIFIED ids; the five sources above keep their basename ids so the
    // existing status.json history still matches.
    ..._treeUnits(root, 'apps/desktop/lib', 'desktop', 'desktop-app'),
    ..._treeUnits(
      root,
      'packages/skotiq_planetarium/lib',
      'planetarium',
      'planetarium-pkg',
    ),
    ..._treeUnits(root, 'packages/skotiq_ui/lib', 'ui', 'design-system'),
    ..._webUnits(root),
    ..._apiUnits(root),
    // Added 2026-08-14 (task #31 remainder): the hub server is a shipped
    // surface (Collaborative Sky) and was the last uncounted tree.
    ..._treeUnits(
      root,
      'server/skotiq_hub/lib',
      'hub',
      'hub-server',
      includeControlless: true,
    ),
  ];
  units.sort((a, b) => (a['id']! as String).compareTo(b['id']! as String));
  _warnOnDuplicateIds(units);
  return {
    'generated_by': 'tools/production/coverage_inventory.dart',
    'units': units,
  };
}

/// A duplicate id is a unit that can never be recorded separately: whichever
/// one a sweep visits, the ledger marks both. Three exist in the basename-keyed
/// sources (two files of the same name at different depths under one area).
/// Report them rather than renaming, because renaming orphans every status.json
/// record that already refers to the old id.
void _warnOnDuplicateIds(List<Map<String, Object?>> units) {
  final seen = <String, int>{};
  for (final u in units) {
    final id = u['id']! as String;
    seen[id] = (seen[id] ?? 0) + 1;
  }
  final dupes = seen.entries.where((e) => e.value > 1).map((e) => e.key);
  for (final id in dupes) {
    stderr.writeln(
      'warning: duplicate unit id "$id" — two files collide on this id, so '
      'only one of them can ever be recorded',
    );
  }
}

// ---------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------

/// One unit per screen-level widget, grouped by the `screens/<area>` directory.
///
/// The area grouping is what a sweep is scoped to ("audit the sequencer"), and
/// the per-file split is what stops an area sweep from silently skipping a
/// sub-screen that is only reachable two taps deep.
List<Map<String, Object?>> _screenUnits(String root) {
  final screensDir = Directory('$root/$_appLib/screens');
  if (!screensDir.existsSync()) return const [];

  final units = <Map<String, Object?>>[];
  for (final file
      in screensDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
    final rel = file.path.substring(root.length + 1);
    if (rel.endsWith('.g.dart') || rel.endsWith('.freezed.dart')) continue;
    final src = file.readAsStringSync();
    final controls = _countControls(src);
    // A file with no operable control is a layout fragment, not a unit to visit.
    if (controls.isEmpty) continue;

    final afterScreens = rel.split('screens/').last;
    final area = afterScreens.contains('/')
        ? afterScreens.split('/').first
        : 'root';
    units.add({
      'id': 'screen:$area/${afterScreens.split('/').last}',
      'kind': 'screen',
      'area': area,
      'path': rel,
      'controls': controls.values.fold<int>(0, (a, b) => a + b),
      'control_kinds': controls,
    });
  }
  return units;
}

/// Units for any tree of Dart files that renders operable controls.
///
/// Shared widgets and dialogs live outside `screens/` but are exactly where a
/// user spends their time -- the device-connect dialog, the target picker, the
/// confirmation sheets. Leaving them out of the ledger let an area be "fully
/// swept" while the dialog the area's main button opens had never been visited.
List<Map<String, Object?>> _dirUnits(
  String root,
  String relDir,
  String kind,
  String area,
) {
  final dir = Directory('$root/$relDir');
  if (!dir.existsSync()) return const [];

  final units = <Map<String, Object?>>[];
  for (final file
      in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
    final rel = file.path.substring(root.length + 1);
    if (rel.endsWith('.g.dart') || rel.endsWith('.freezed.dart')) continue;
    final controls = _countControls(file.readAsStringSync());
    if (controls.isEmpty) continue;
    units.add({
      'id': '$kind:${rel.split('/').last}',
      'kind': kind,
      'area': area,
      'path': rel,
      'controls': controls.values.fold<int>(0, (a, b) => a + b),
      'control_kinds': controls,
    });
  }
  return units;
}

/// Like [_dirUnits] but keyed on the path below [relDir] instead of the bare
/// filename, so two `widgets/header.dart` in different subtrees stay distinct.
List<Map<String, Object?>> _treeUnits(
  String root,
  String relDir,
  String kind,
  String area, {
  // Server code has no Flutter widgets, so the control filter silently
  // dropped EVERY hub file and the tree contributed zero units while the
  // ledger claimed it was counted (hub-sweep finding H2). A server unit's
  // exercise is API-driven; it earns its ledger row with zero widget
  // controls.
  bool includeControlless = false,
}) {
  final dir = Directory('$root/$relDir');
  if (!dir.existsSync()) return const [];

  final units = <Map<String, Object?>>[];
  for (final file
      in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
    final rel = file.path.substring(root.length + 1);
    if (rel.endsWith('.g.dart') || rel.endsWith('.freezed.dart')) continue;
    final controls = _countControls(file.readAsStringSync());
    if (controls.isEmpty && !includeControlless) continue;
    units.add({
      'id': '$kind:${rel.substring(relDir.length + 1)}',
      'kind': kind,
      'area': area,
      'path': rel,
      'controls': controls.values.fold<int>(0, (a, b) => a + b),
      'control_kinds': controls,
    });
  }
  return units;
}

/// Interactive controls in a hand-written HTML page.
///
/// The web dashboard is a surface a user drives with a mouse, served by the
/// headless appliance to anyone on the LAN, and it was never in the ledger at
/// all.
const _htmlControlPatterns = <String, String>{
  'button': r'<button\b',
  'input': r'<input\b',
  'select': r'<select\b',
  'textarea': r'<textarea\b',
  'link': r'<a\s[^>]*href=',
  'handler': r'\bon(?:click|change|input|submit)\s*=',
};

/// One unit per hand-written web page served by the desktop/headless binary.
List<Map<String, Object?>> _webUnits(String root) {
  const pages = <String, String>{
    'apps/desktop/web_dashboard/index.html': 'web-dashboard',
    'apps/desktop/web_run_watch/index.html': 'web-run-watch',
    'apps/desktop/web/index.html': 'web-pairing',
  };
  final units = <Map<String, Object?>>[];
  for (final entry in pages.entries) {
    final file = File('$root/${entry.key}');
    if (!file.existsSync()) continue;
    final src = file.readAsStringSync();
    final controls = <String, int>{};
    for (final p in _htmlControlPatterns.entries) {
      final n = RegExp(p.value, caseSensitive: false).allMatches(src).length;
      if (n > 0) controls[p.key] = n;
    }
    if (controls.isEmpty) continue;
    units.add({
      'id': 'web:${entry.value}',
      'kind': 'web-page',
      'area': 'web',
      'path': entry.key,
      'controls': controls.values.fold<int>(0, (a, b) => a + b),
      'control_kinds': controls,
    });
  }
  return units;
}

/// One unit per headless HTTP/WebSocket route.
///
/// A route is exactly the kind of thing a sweep has to touch — it is the whole
/// interface the mobile app, the web dashboard and any third-party client see —
/// and 472 of them were outside the denominator. Sweeping them is a scripted
/// job, not a manual one, but they belong in the count either way.
List<Map<String, Object?>> _apiUnits(String root) {
  final dir = Directory('$root/apps/desktop/lib');
  if (!dir.existsSync()) return const [];
  final routeRe = RegExp(r"'(/api/[A-Za-z0-9/_{}<>-]+)'");
  final routes = <String>{};
  for (final file
      in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
    for (final m in routeRe.allMatches(file.readAsStringSync())) {
      routes.add(m.group(1)!);
    }
  }
  return [
    for (final route in routes.toList()..sort())
      {
        'id': 'api:$route',
        'kind': 'api-route',
        'area': 'headless-api',
        'controls': 1,
      },
  ];
}

Map<String, int> _countControls(String src) {
  final out = <String, int>{};
  for (final entry in _controlPatterns.entries) {
    final n = RegExp(entry.value).allMatches(src).length;
    if (n > 0) out[entry.key] = n;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// One unit per settings section, carrying every row title that section renders.
///
/// Row titles come from the generated search index rather than being re-parsed
/// here, so the ledger and the Settings search box can never disagree about what
/// a section contains.
List<Map<String, Object?>> _settingsUnits(String root) {
  final file = File('$root/$_searchIndexPath');
  if (!file.existsSync()) return const [];
  final src = file.readAsStringSync();

  final units = <Map<String, Object?>>[];
  final sectionRe = RegExp(r"^  '([a-z0-9-]+)': \[([^\]]*)\]", multiLine: true);
  for (final m in sectionRe.allMatches(src)) {
    final rows = RegExp(r"^    '(.*)',$", multiLine: true)
        .allMatches(m.group(2)!)
        .map((r) => r.group(1)!.replaceAll(r"\'", "'"))
        .toList();
    units.add({
      'id': 'settings:${m.group(1)}',
      'kind': 'settings-section',
      'area': 'settings',
      'controls': rows.length,
      'rows': rows,
    });
  }
  return units;
}

// ---------------------------------------------------------------------------
// Sequencer instructions
// ---------------------------------------------------------------------------

/// One unit per concrete sequence instruction a user can drop into a sequence.
///
/// Sourced from the sealed `SequenceNode` hierarchy, so an instruction added to
/// the model shows up in the ledger as untested even if nobody wires it into the
/// builder palette — which is itself a defect worth surfacing.
List<Map<String, Object?>> _sequenceNodeUnits(String root) {
  final dir = Directory('$root/$_sequenceModelsDir');
  if (!dir.existsSync()) return const [];

  final names = <String>{};
  for (final file
      in dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
    for (final m in RegExp(
      r'^class ([A-Za-z0-9_]+) extends SequenceNode\b',
      multiLine: true,
    ).allMatches(file.readAsStringSync())) {
      names.add(m.group(1)!);
    }
  }

  return names
      .map(
        (n) => <String, Object?>{
          'id': 'seq-node:$n',
          'kind': 'sequence-instruction',
          'area': 'sequencer',
          'controls': 1,
        },
      )
      .toList();
}

// ---------------------------------------------------------------------------
// Reporting
// ---------------------------------------------------------------------------

void _report(String root, Map<String, Object?> inventory, List<String> args) {
  final statusFile = File('$root/$_outDir/status.json');
  final status = statusFile.existsSync()
      ? (jsonDecode(statusFile.readAsStringSync()) as Map)
            .cast<String, dynamic>()
      : <String, dynamic>{};

  var areaFilter = <String>{};
  final i = args.indexOf('--area');
  if (i >= 0 && i + 1 < args.length) areaFilter = {args[i + 1]};

  final units = (inventory['units']! as List).cast<Map<String, Object?>>();
  final byArea = <String, List<Map<String, Object?>>>{};
  for (final u in units) {
    if (areaFilter.isNotEmpty && !areaFilter.contains(u['area'])) continue;
    byArea.putIfAbsent(u['area']! as String, () => []).add(u);
  }

  var totalDone = 0, total = 0;
  final areas = byArea.keys.toList()..sort();
  for (final area in areas) {
    final list = byArea[area]!;
    final done = list.where((u) => status.containsKey(u['id'])).length;
    totalDone += done;
    total += list.length;
    final pending = list
        .where((u) => !status.containsKey(u['id']))
        .map((u) => u['id']);
    stdout.writeln(
      '${done == list.length ? "OK  " : "TODO"} '
      '${area.padRight(20)} $done/${list.length}',
    );
    if (areaFilter.isNotEmpty) {
      for (final p in pending) {
        stdout.writeln('       - $p');
      }
    }
  }
  stdout.writeln('\nTOTAL $totalDone/$total units swept');
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
