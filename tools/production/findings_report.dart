// Renders every swept finding into one triage document, ordered by what hurts.
//
// WHY THIS EXISTS
// ---------------
// A sweep produces findings as a pile of per-area JSON files, which is the right
// shape for machines and useless for deciding what to fix on a Tuesday. Worse,
// a pile invites the failure this whole campaign exists to stop: skimming the
// interesting-sounding ones, fixing those, and calling the area done.
//
// So this orders strictly by severity — using the VERIFIER's corrected severity
// where one exists, not the reporter's — and prints the unverified ones in their
// own section rather than mixing them in, because "nobody has tried to reproduce
// this yet" is a materially different claim from "an adversarial reviewer failed
// to refute it".
//
// USAGE
//   dart run tools/production/findings_report.dart
//   dart run tools/production/findings_report.dart --severity P0,P1
import 'dart:convert';
import 'dart:io';

const _sweptDir = 'reports/coverage/swept';
const _out = 'reports/coverage/FINDINGS.md';
const _productOut = 'reports/coverage/PRODUCT-CRITIQUE.md';

void main(List<String> args) {
  final root = _findRepoRoot();
  if (root == null) {
    stderr.writeln('error: could not locate repo root (no melos.yaml found)');
    exit(2);
  }

  var wanted = <String>{'P0', 'P1', 'P2', 'P3', 'P4'};
  final i = args.indexOf('--severity');
  if (i >= 0 && i + 1 < args.length) wanted = args[i + 1].split(',').toSet();

  // `--kind ux,default,missing` renders the PRODUCT critique rather than the
  // defect list. Kept as a first-class mode because it answers a different
  // question — "is this good?" rather than "is this broken?" — and mixing the
  // two buries it: a wrong default that every user must change is not a bug
  // report, but it is the thing that decides whether the app is pleasant.
  var kinds = <String>{'defect', 'ux', 'default', 'missing'};
  final k = args.indexOf('--kind');
  if (k >= 0 && k + 1 < args.length) kinds = args[k + 1].split(',').toSet();
  final outPath = kinds.contains('defect') ? _out : _productOut;

  final findings = <Map<String, Object?>>[];
  final areas = <String, int>{};
  var unreached = 0;

  final dir = Directory('$root/$_sweptDir');
  if (!dir.existsSync()) {
    stderr.writeln('error: $_sweptDir not found — run a sweep first');
    exit(2);
  }

  for (final file in dir.listSync().whereType<File>().where(
    (f) => f.path.endsWith('.json'),
  )) {
    Map<String, dynamic> data;
    try {
      data = (jsonDecode(file.readAsStringSync()) as Map)
          .cast<String, dynamic>();
    } on FormatException catch (e) {
      // A truncated file is an agent that died mid-write. Say so loudly rather
      // than skipping it: silently dropping a file is how a partial sweep reads
      // as a complete one.
      stderr.writeln(
        'WARNING: ${file.uri.pathSegments.last} is not valid JSON '
        '($e) — its findings are NOT in this report',
      );
      continue;
    }
    final area = data['area'] as String? ?? file.uri.pathSegments.last;
    unreached += (data['units_unreached'] as List? ?? const []).length;
    for (final f in (data['findings'] as List? ?? const [])) {
      final m = (f as Map).cast<String, Object?>();
      m['_area'] = area;
      findings.add(m);
      areas[area] = (areas[area] ?? 0) + 1;
    }
  }

  // Deduplicate on title: several areas overlap, and the same defect found twice
  // is corroboration, not two problems.
  final byTitle = <String, Map<String, Object?>>{};
  final dupes = <String, int>{};
  for (final f in findings) {
    final t = (f['title']! as String).toLowerCase();
    if (byTitle.containsKey(t)) {
      dupes[t] = (dupes[t] ?? 1) + 1;
      continue;
    }
    byTitle[t] = f;
  }

  const order = {'P0': 0, 'P1': 1, 'P2': 2, 'P3': 3, 'P4': 4};
  String sev(Map<String, Object?> f) =>
      (f['corrected_severity'] as String?) ?? (f['severity']! as String);

  final list =
      byTitle.values
          .where((f) => wanted.contains(sev(f)))
          .where((f) => kinds.contains(f['kind']))
          // A refuted finding is not a product opinion worth acting on either.
          .where((f) => f['verdict'] != 'REFUTED')
          .toList()
        ..sort((a, b) {
          final s = (order[sev(a)] ?? 9).compareTo(order[sev(b)] ?? 9);
          if (s != 0) return s;
          // Confirmed before unverified at the same severity: a reproduced defect is
          // actionable now, an unverified one needs a step first.
          return _rank(a).compareTo(_rank(b));
        });

  final buf = StringBuffer()
    ..writeln(
      kinds.contains('defect')
          ? '# Skotiq sweep — findings'
          : '# Skotiq sweep — product critique\n\n'
                'Not defects. These are places the app works as built and the design '
                'is wrong: a default everyone must change, a flow that costs more '
                'clicks than it should, something a user reaches for and does not '
                'find. Refuted findings are excluded.',
    )
    ..writeln()
    ..writeln(
      'Generated by `tools/production/findings_report.dart` from '
      '`$_sweptDir`.',
    )
    ..writeln();

  final confirmed = list.where((f) => f['verdict'] == 'CONFIRMED').length;
  final refuted = findings.where((f) => f['verdict'] == 'REFUTED').length;
  buf
    ..writeln(
      '- **${byTitle.length}** distinct findings across '
      '**${areas.length}** areas (${findings.length} raw, '
      '${findings.length - byTitle.length} duplicates merged)',
    )
    ..writeln(
      '- **$confirmed** independently reproduced by an adversarial '
      'verifier; **$refuted** were refuted and are excluded',
    )
    ..writeln('- **$unreached** units recorded as unreached, with reasons')
    ..writeln();

  var current = '';
  for (final f in list) {
    if (sev(f) != current) {
      current = sev(f);
      buf
        ..writeln()
        ..writeln('## $current')
        ..writeln();
    }
    final corrected =
        f['corrected_severity'] != null &&
            f['corrected_severity'] != f['severity']
        ? ' _(reported ${f['severity']}, corrected by verifier)_'
        : '';
    final dupe = dupes[(f['title']! as String).toLowerCase()];
    buf
      ..writeln('### ${f['title']}')
      ..writeln()
      ..writeln(
        '`${f['kind']}` · ${f['_area']} · **${_verdict(f)}**$corrected'
        '${dupe != null ? ' · found independently by $dupe agents' : ''}',
      )
      ..writeln()
      ..writeln('**What happens:** ${f['what_happened']}')
      ..writeln()
      ..writeln('**Expected:** ${f['expected']}')
      ..writeln();
    if ((f['repro'] as String?)?.isNotEmpty ?? false) {
      buf
        ..writeln('**Repro:** ${f['repro']}')
        ..writeln();
    }
    if ((f['where'] as String?)?.isNotEmpty ?? false) {
      buf
        ..writeln('**Where:** `${f['where']}`')
        ..writeln();
    }
    if ((f['proposed_fix'] as String?)?.isNotEmpty ?? false) {
      buf
        ..writeln('**Proposed fix:** ${f['proposed_fix']}')
        ..writeln();
    }
  }

  File('$root/$outPath').writeAsStringSync(buf.toString());
  stdout.writeln(
    'wrote $outPath — ${list.length} findings '
    '(${byTitle.length} distinct, $confirmed confirmed, $refuted refuted)',
  );
}

int _rank(Map<String, Object?> f) => switch (f['verdict']) {
  'CONFIRMED' => 0,
  'UNCLEAR' => 2,
  _ => 1,
};

String _verdict(Map<String, Object?> f) =>
    (f['verdict'] as String?) ?? 'not yet verified';

String? _findRepoRoot() {
  var dir = Directory.current;
  while (true) {
    if (File('${dir.path}/melos.yaml').existsSync()) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) return null;
    dir = parent;
  }
}
