import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  final repoRoot = Directory.current;
  final script = File(
    '${repoRoot.path}/tools/production/ui_consistency_audit.dart',
  );
  if (!script.existsSync()) {
    throw StateError('UI consistency audit not found: ${script.path}');
  }

  final temp = await Directory.systemTemp.createTemp(
    'skotiq_ui_consistency_audit_self_test_',
  );
  try {
    await _writePassingFixture(temp);
    await _runAudit(script, temp, 'reports/ui.txt');
    final passing = _readJson(
      temp,
      'docs/production-readiness/ui-consistency-audit.json',
    );
    _expect(
      passing['blockingFindingCount'] == 0,
      'intentional overlay colors should not block',
    );
    _expect(
      passing['textReportPath'] == 'reports/ui.txt',
      'custom text output path should be recorded',
    );
    final passingColors =
        passing['rawColorClassifications'] as Map? ?? const {};
    _expect(
      passingColors['intentional_image_overlay'] == 1,
      'passing fixture should classify the overlay color',
    );
    final passingGallery = passing['designSystemGallery'] as Map? ?? const {};
    _expect(
      passingGallery['ready'] == true,
      'passing fixture should include design-system gallery evidence',
    );

    await _writeFailingFixture(temp);
    final failingResult = await _runAudit(
      script,
      temp,
      '.ui_consistency_audit.txt',
      allowFailure: true,
      extraArgs: const ['--fail-on-any'],
    );
    _expect(failingResult.exitCode == 1, 'failing fixture should fail');
    final failing = _readJson(
      temp,
      'docs/production-readiness/ui-consistency-audit.json',
    );
    _expect(
      (failing['blockingFindingCount'] as int) > 5,
      'failing fixture should include style and gallery blockers',
    );
    final counts = failing['countsByRule'] as Map? ?? const {};
    _expect(
      counts['raw_button_style'] == 1 &&
          counts['large_radius'] == 1 &&
          counts['empty_callback'] == 1 &&
          counts['fake_callback'] == 1 &&
          counts['stub_callback'] == 1 &&
          counts['raw_material_color'] == 1 &&
          counts['headless_route_not_advertised'] == 1 &&
          (counts['design_system_gallery_missing'] as int) > 0,
      'failing fixture should count each blocking rule',
    );
    final failingColors =
        failing['rawColorClassifications'] as Map? ?? const {};
    _expect(
      failingColors['semantic_theme_color'] == 1,
      'failing fixture should classify semantic raw Material color',
    );

    stdout.writeln('UI consistency audit self-test passed.');
  } finally {
    await temp.delete(recursive: true);
  }
}

Future<void> _writePassingFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeFile(root, 'apps/desktop/lib/framing/overlay_color.dart', '''
void paintOverlay() {
  final color = Colors.red;
}
''');
  await _writeFile(root, 'apps/desktop/lib/headless_api_server.dart', '''
void register(router) {
  router.get('/api/status', handler);
}

List<String> _getAvailableEndpoints() {
  return [
    'GET /api/status',
  ];
}
''');
  await _writeFile(root, 'packages/skotiq_ui/lib/skotiq_ui.dart', '''
export 'src/widgets/design_system_gallery.dart';
''');
  await _writeFile(
    root,
    'packages/skotiq_ui/lib/src/widgets/design_system_gallery.dart',
    '''
class SkotiqDesignSystemGallery {
  final markers = const [
    'Panels and wells',
    'Readouts',
    'Underline tabs',
    'Segmented control',
    'Toolbar',
    'Fields and form rows',
    'Chips and status dots',
    'Banner',
    'Empty state',
    'Dialog',
    'Glass',
    'Side panel',
    'Candidate',
    'Checklist',
    'Night band',
    'Buttons and icon buttons',
    'SkotiqButton',
    'SkotiqIconButton',
    'SkotiqPanel',
    'PanelHead',
    'Readout(',
    'AdaptiveTabBar',
    'SegmentedControl',
    'SkotiqToolbar',
    'SkotiqTextField',
    'SkotiqDropdown',
    'SkotiqCheckbox',
    'SkotiqSwitch',
    'FormRow',
    'SkotiqChip',
    'StatusDot',
    'InstrumentPill',
    'SkotiqBanner',
    'EmptyState',
    'SkotiqDialog',
    'SidePanel(',
    'SectionTitle',
    'Checklist(',
    'NightBand(',
  ];
}
''',
  );
  await _writeFile(
    root,
    'packages/skotiq_ui/test/design_system_gallery_test.dart',
    '''
void galleryTestMarkers() {
  const markers = [
    'SkotiqTheme.dark',
    'SkotiqTheme.light',
    'SkotiqTheme.redNight',
    'gallery controls update representative states',
    'gallery-button-primary',
    'gallery-button-secondary',
    'gallery-dropdown',
    'gallery-switch',
    'SkotiqDropdown',
    'SkotiqCheckbox',
    'SkotiqSwitch',
  ];
  markers.length;
}
''',
  );
}

Future<void> _writeFailingFixture(Directory root) async {
  await _resetWorkspace(root);
  await _writeFile(root, 'packages/skotiq_app/lib/bad_panel.dart', '''
void buildPanel() {
  final style = ElevatedButton.styleFrom();
  final radius = BorderRadius.circular(24);
  final color = Colors.blue;
  final button = Button(onPressed: () {});
  final link = Button(onTap: () => Future.value());
  final stub = Button(onPressed: () {
    // TODO: wire real action
  });
}
''');
  await _writeFile(root, 'apps/desktop/lib/headless_api_server.dart', '''
void register(router) {
  router.post('/api/control/start', handler);
}

List<String> _getAvailableEndpoints() {
  return [
    'GET /api/status',
  ];
}
''');
}

Future<void> _resetWorkspace(Directory root) async {
  for (final path in ['apps', 'packages', 'docs', 'reports']) {
    final dir = Directory('${root.path}/$path');
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
  final textReport = File('${root.path}/.ui_consistency_audit.txt');
  if (textReport.existsSync()) {
    await textReport.delete();
  }
}

Future<ProcessResult> _runAudit(
  File script,
  Directory root,
  String outPath, {
  bool allowFailure = false,
  List<String> extraArgs = const [],
}) async {
  final result = await Process.run(
    'dart',
    [script.path, '--out', outPath, ...extraArgs],
    workingDirectory: root.path,
    runInShell: Platform.isWindows,
  );
  if (!allowFailure && result.exitCode != 0) {
    throw StateError(
      '${script.path} failed with exit ${result.exitCode}\n'
      'stdout:\n${result.stdout}\n'
      'stderr:\n${result.stderr}',
    );
  }
  return result;
}

Future<void> _writeFile(
  Directory root,
  String relativePath,
  String content,
) async {
  final file = File('${root.path}/$relativePath');
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
}

Map<String, dynamic> _readJson(Directory root, String relativePath) {
  final file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    throw StateError('Expected report was not written: ${file.path}');
  }
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}
