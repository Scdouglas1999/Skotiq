import 'dart:convert';
import 'dart:io';

const _jsonOutputPath = 'docs/production-readiness/release-staging-audit.json';
const _markdownOutputPath =
    'docs/production-readiness/release-staging-audit.md';

const _generatedNames = {
  'frb_generated.dart',
  'frb_generated.io.dart',
  'frb_generated.web.dart',
  'bridge_generated.h',
};

const _generatedSuffixes = {'.g.dart', '.freezed.dart'};

const _binaryExtensions = {
  '.dll',
  '.exe',
  '.png',
  '.jpg',
  '.jpeg',
  '.gif',
  '.webp',
  '.ico',
  '.zip',
  '.7z',
  '.tar',
  '.gz',
  '.apk',
  '.db',
  '.sqlite',
  '.vhdx',
};

const _releaseCriticalPrefixes = {
  '.github/workflows/',
  'apps/desktop/lib/headless_api/',
  'apps/desktop/lib/headless_api_server.dart',
  'apps/desktop/linux/',
  'apps/desktop/lib/main_headless.dart',
  'apps/desktop/web_dashboard/',
  'apps/mobile/lib/',
  'native/skotiq_native/',
  'packages/skotiq_core/lib/',
  'packages/skotiq_bridge/lib/',
  'packages/skotiq_app/lib/',
  'tools/production/',
  'docs/production-readiness/',
  'docs/headless-secure-setup.md',
  'docs/migration-backup-restore.md',
  'docs/known-limitations.md',
  'docs/release-notes-template.md',
  'docs/supported-hardware-by-platform.md',
  'docs/troubleshooting/',
  'packaging/appliance/',
  'melos.yaml',
  'package.json',
};

void main(List<String> args) async {
  final failOnDirty = args.contains('--fail-on-dirty');
  final failOnUntrackedCritical = args.contains('--fail-on-untracked-critical');

  final result = await Process.run('git', [
    'status',
    '--porcelain=v1',
    '-uall',
  ], runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    stderr.writeln(result.stderr);
    exit(result.exitCode);
  }

  final entries =
      LineSplitter.split(result.stdout as String)
          .where((line) => line.trim().isNotEmpty)
          .map(_StatusEntry.parse)
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  final categories = <String, List<_StatusEntry>>{};
  for (final entry in entries) {
    categories.putIfAbsent(entry.category, () => []).add(entry);
  }

  final untrackedCritical = entries
      .where((entry) => entry.isUntracked && entry.isReleaseCritical)
      .toList();
  final binaryEntries = entries.where((entry) => entry.isBinary).toList();
  final generatedEntries = entries.where((entry) => entry.isGenerated).toList();

  final report = {
    'generatedAt': DateTime.now().toUtc().toIso8601String(),
    'currentBranch': await _gitSingleLine(['branch', '--show-current']),
    'head': await _gitSingleLine(['rev-parse', '--short', 'HEAD']),
    'entryCount': entries.length,
    'modifiedCount': entries.where((entry) => entry.isTrackedChange).length,
    'untrackedCount': entries.where((entry) => entry.isUntracked).length,
    'deletedCount': entries.where((entry) => entry.isDeleted).length,
    'binaryCount': binaryEntries.length,
    'generatedCount': generatedEntries.length,
    'untrackedReleaseCriticalCount': untrackedCritical.length,
    'categories': {
      for (final entry in categories.entries)
        entry.key: {
          'count': entry.value.length,
          'untrackedCount': entry.value
              .where((status) => status.isUntracked)
              .length,
          'paths': entry.value.map((status) => status.toJson()).toList(),
        },
    },
    'untrackedReleaseCritical': untrackedCritical
        .map((entry) => entry.toJson(includeCategory: true))
        .toList(),
    'binaryEntries': binaryEntries
        .map((entry) => entry.toJson(includeCategory: true))
        .toList(),
    'generatedEntries': generatedEntries
        .map((entry) => entry.toJson(includeCategory: true))
        .toList(),
  };

  await File(
    _jsonOutputPath,
  ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
  await File(_markdownOutputPath).writeAsString(
    _renderMarkdown(
      currentBranch: report['currentBranch'] as String,
      head: report['head'] as String,
      entries: entries,
      categories: categories,
      untrackedCritical: untrackedCritical,
      binaryEntries: binaryEntries,
      generatedEntries: generatedEntries,
    ),
  );

  stdout.writeln('Release staging audit complete.');
  stdout.writeln('Entries: ${entries.length}');
  stdout.writeln('Untracked release-critical: ${untrackedCritical.length}');
  stdout.writeln('JSON: $_jsonOutputPath');
  stdout.writeln('Markdown: $_markdownOutputPath');

  if (failOnDirty && entries.isNotEmpty) {
    exit(1);
  }
  if (failOnUntrackedCritical && untrackedCritical.isNotEmpty) {
    exit(1);
  }
}

Future<String> _gitSingleLine(List<String> args) async {
  final result = await Process.run('git', args, runInShell: Platform.isWindows);
  if (result.exitCode != 0) {
    return 'unknown';
  }
  return (result.stdout as String).trim();
}

String _renderMarkdown({
  required String currentBranch,
  required String head,
  required List<_StatusEntry> entries,
  required Map<String, List<_StatusEntry>> categories,
  required List<_StatusEntry> untrackedCritical,
  required List<_StatusEntry> binaryEntries,
  required List<_StatusEntry> generatedEntries,
}) {
  final tracked = entries.where((entry) => entry.isTrackedChange).length;
  final untracked = entries.where((entry) => entry.isUntracked).length;
  final deleted = entries.where((entry) => entry.isDeleted).length;

  final buffer = StringBuffer()
    ..writeln('# Release Staging Audit')
    ..writeln()
    ..writeln('- Branch: `$currentBranch`')
    ..writeln('- HEAD: `$head`')
    ..writeln('- Total changed/untracked entries: `${entries.length}`')
    ..writeln('- Tracked modified/added/deleted entries: `$tracked`')
    ..writeln('- Untracked entries: `$untracked`')
    ..writeln('- Deleted entries: `$deleted`')
    ..writeln('- Generated entries: `${generatedEntries.length}`')
    ..writeln(
      '- Binary/evidence/native artifact entries: `${binaryEntries.length}`',
    )
    ..writeln(
      '- Untracked release-critical entries: `${untrackedCritical.length}`',
    )
    ..writeln()
    ..writeln(
      'This is a scoping report only. It does not make the worktree clean and '
      'does not prove a release branch or PR has been created.',
    )
    ..writeln()
    ..writeln('## Category Summary')
    ..writeln()
    ..writeln('| Category | Count | Untracked |')
    ..writeln('| --- | ---: | ---: |');

  final sortedCategories = categories.keys.toList()..sort();
  for (final category in sortedCategories) {
    final items = categories[category]!;
    final untrackedCount = items.where((entry) => entry.isUntracked).length;
    buffer.writeln('| $category | ${items.length} | $untrackedCount |');
  }

  buffer
    ..writeln()
    ..writeln('## Required Split Before PR')
    ..writeln()
    ..writeln('- Review generated files separately from human-authored source.')
    ..writeln('- Review binary/native artifacts separately from source diffs.')
    ..writeln(
      '- Stage release evidence docs and production tools intentionally; many are untracked.',
    )
    ..writeln(
      '- Do not cut a public tag from this worktree until untracked release-critical entries are either staged or explicitly excluded.',
    )
    ..writeln();

  _writeSection(
    buffer,
    'Untracked Release-Critical Entries',
    untrackedCritical,
    limit: 120,
  );
  _writeSection(buffer, 'Binary / Evidence Artifact Entries', binaryEntries);
  _writeSection(buffer, 'Generated Entries', generatedEntries);

  return buffer.toString();
}

void _writeSection(
  StringBuffer buffer,
  String title,
  List<_StatusEntry> entries, {
  int limit = 80,
}) {
  buffer
    ..writeln()
    ..writeln('## $title')
    ..writeln();

  if (entries.isEmpty) {
    buffer.writeln('None.');
    return;
  }

  for (final entry in entries.take(limit)) {
    buffer.writeln('- `${entry.status}` `${entry.path}` (${entry.category})');
  }
  if (entries.length > limit) {
    buffer.writeln('- ... ${entries.length - limit} more entries omitted.');
  }
}

class _StatusEntry {
  final String indexStatus;
  final String worktreeStatus;
  final String path;

  const _StatusEntry({
    required this.indexStatus,
    required this.worktreeStatus,
    required this.path,
  });

  factory _StatusEntry.parse(String line) {
    final index = line.isNotEmpty ? line[0] : ' ';
    final worktree = line.length > 1 ? line[1] : ' ';
    var path = line.length > 3 ? line.substring(3) : '';
    final renameSeparator = path.indexOf(' -> ');
    if (renameSeparator >= 0) {
      path = path.substring(renameSeparator + 4);
    }
    return _StatusEntry(
      indexStatus: index,
      worktreeStatus: worktree,
      path: path.replaceAll('\\', '/'),
    );
  }

  String get status => '$indexStatus$worktreeStatus';

  bool get isUntracked => status == '??';

  bool get isDeleted => indexStatus == 'D' || worktreeStatus == 'D';

  bool get isTrackedChange => !isUntracked;

  bool get isGenerated {
    final name = path.split('/').last;
    return _generatedNames.contains(name) ||
        _generatedSuffixes.any(path.endsWith) ||
        path.contains('/generated/') ||
        path.endsWith('/pubspec.lock') ||
        path.endsWith('/Cargo.lock');
  }

  bool get isBinary {
    final lower = path.toLowerCase();
    return _binaryExtensions.any(lower.endsWith);
  }

  bool get isReleaseCritical {
    return _releaseCriticalPrefixes.any((prefix) => path.startsWith(prefix));
  }

  String get category {
    if (isBinary) {
      if (path.startsWith('docs/production-readiness/')) {
        return 'release-evidence-binary';
      }
      return 'binary-native-artifact';
    }
    if (isGenerated) return 'generated';
    if (path.startsWith('native/skotiq_native/')) return 'native-rust';
    if (path.startsWith('apps/desktop/lib/headless_api') ||
        path == 'apps/desktop/lib/headless_api_server.dart' ||
        path == 'apps/desktop/lib/main_headless.dart' ||
        path.startsWith('apps/desktop/web_dashboard/')) {
      return 'headless-remote';
    }
    if (path.startsWith('apps/mobile/')) return 'mobile';
    if (path.startsWith('packages/skotiq_app/lib/')) return 'app-ui';
    if (path.startsWith('packages/skotiq_core/lib/')) return 'core';
    if (path.startsWith('packages/skotiq_bridge/')) return 'bridge';
    if (path.startsWith('packages/skotiq_planetarium/'))
      return 'planetarium';
    if (path.startsWith('packages/skotiq_plugins/')) return 'plugins';
    if (path.startsWith('packages/skotiq_updater/')) return 'updater';
    if (path.startsWith('packages/skotiq_remote_protocol/'))
      return 'remote-protocol';
    if (path.startsWith('packages/skotiq_ui/')) return 'ui-system';
    if (path.startsWith('tools/production/')) return 'release-tooling';
    if (path.startsWith('tools/') || path.startsWith('scripts/')) {
      return 'tooling';
    }
    if (path.startsWith('docs/production-readiness/')) {
      return 'release-evidence-docs';
    }
    if (path.startsWith('docs/')) return 'docs';
    if (path.contains('/test/') || path.endsWith('_test.dart')) return 'tests';
    if (path.endsWith('pubspec.yaml') ||
        path.endsWith('melos.yaml') ||
        path.endsWith('Cargo.toml')) {
      return 'package-config';
    }
    return 'other';
  }

  Map<String, Object?> toJson({bool includeCategory = false}) => {
    'status': status,
    'indexStatus': indexStatus,
    'worktreeStatus': worktreeStatus,
    'path': path,
    if (includeCategory) 'category': category,
    'untracked': isUntracked,
    'deleted': isDeleted,
    'generated': isGenerated,
    'binary': isBinary,
    'releaseCritical': isReleaseCritical,
  };
}
