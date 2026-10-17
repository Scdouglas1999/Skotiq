// Source-of-record fetcher for the committed real-HiPS framing test fixtures.
//
// WHAT THIS IS
// ------------
// The framing GPU/HiPS tile layer is verified by deterministic, OFFLINE golden
// and render-verify tests. Those tests must composite *real* survey imagery (so
// a regression in the mesh warp, LOD selection, seam stitching or projection is
// caught against genuine DSS2-colour pixels — not synthetic tints), yet CI has
// no network. The resolution is a small, committed set of real HiPS bytes for
// one fixed field. THIS script is how those committed bytes were obtained: it is
// the auditable, reproducible record of provenance so the fixtures are not
// "magic" binaries of unknown origin.
//
// It is NOT run in CI and the tests do NOT depend on it. It exists so a
// maintainer can re-derive byte-identical fixtures from the public CDS HiPS
// service at any time, and so a reviewer can see exactly which sky field, which
// survey, and which HEALPix tiles were committed and why.
//
// THE FIELD
// ---------
// M31, the Andromeda Galaxy (RA 10.6847 deg, Dec +41.2687 deg). Chosen because:
//   * it is a famous, large, instantly-recognisable target whose imagery makes a
//     rendered golden easy for a human to sanity-check;
//   * at Norder6 its visible tile set falls entirely within HiPS directory
//     bucket Dir0 (npix < 10000), so every committed tile lives under the
//     standard `Norder{k}/Dir0/` path the fixture tree mirrors exactly;
//   * the whole LOD fallback chain (Norder6 primary -> Norder5 parent ->
//     Norder4 grandparent -> Norder3 Allsky) is compact and also entirely Dir0.
//
// THE SURVEY
// ----------
// CDS/P/DSS2/color (DSS2 colour), served from
//   https://alasky.cds.unistra.fr/DSS/DSSColor
// This is the colour DSS2 HiPS the framing survey-image path already uses; the
// committed `properties` file is this survey's real metadata document. The
// Allsky whole-sky preview this survey publishes lives at Norder3 (it is not
// published at Norder0..2), so the committed `Allsky.jpg` is the Norder3 map and
// is the coarsest never-blank fallback layer.
//
// THE TILE SET
// ------------
// The per-order npix lists below are NOT hand-picked: they are the exact output
// of the production tile-selection brain (`HipsTileSelection.computeVisibleTiles`
// in `packages/skotiq_core/lib/src/services/hips/hips_tile_selection.dart`)
// for the field/plate-scale recorded in [fixturePlate], at the golden zoom for
// each order. They were captured by running that code against this field; the
// committed `fixture_field.dart` carries the same lists as the canonical
// in-test description. Keeping the lists here too makes this script standalone
// (no import of the app packages) and lets a reviewer diff the two for drift.
//
// HOW TO RUN
// ----------
//   dart run tools/hips_fixtures/fetch_hips_fixtures.dart
//
// Optional flags:
//   --out=<dir>     Override the fixture output root (default: the in-repo
//                   packages/skotiq_app/test/fixtures/hips directory).
//   --dry-run       Print the URLs that would be fetched, write nothing.
//   --force         Re-download and overwrite files that already exist.
//
// Errors are a feature: any non-200 response, short read, or non-JPEG payload
// aborts with a non-zero exit code rather than committing a corrupt fixture.

import 'dart:io';
import 'dart:typed_data';

/// Canonical CDS HiPS id of the committed survey.
const String surveyHipsId = 'CDS/P/DSS2/color';

/// Direct tile-pyramid base URL for [surveyHipsId] on the public CDS mirror.
const String surveyBaseUrl = 'https://alasky.cds.unistra.fr/DSS/DSSColor';

/// The fixture field centre, right ascension in degrees (M31).
const double fieldRaDeg = 10.6847;

/// The fixture field centre, declination in degrees (M31).
const double fieldDecDeg = 41.2687;

/// Human-readable field name.
const String fieldName = 'M31 (Andromeda Galaxy)';

/// The HEALPix order the survey publishes its Allsky whole-sky preview at.
/// CDS DSS surveys publish Allsky only at order 3 (404 at 0..2), so this is the
/// coarsest never-blank fallback layer and the only Allsky committed.
const int allskyOrder = 3;

/// Exact visible-tile npix per HiPS order for [fieldName], as produced by
/// `HipsTileSelection.computeVisibleTiles` for [fixturePlate] at the golden zoom
/// for each order. Every npix here is < 10000, so every tile is in Dir0.
const Map<int, List<int>> tilesByOrder = <int, List<int>>{
  // Norder4 — grandparent fallback (golden zoom 1.0 grandparents of Norder6).
  4: <int>[163, 166, 169, 172],
  // Norder5 — parent fallback (golden zoom 1.0 parents of Norder6).
  5: <int>[653, 654, 655, 664, 666, 676, 677, 678, 679, 688],
  // Norder6 — primary LOD at golden zoom 1.0 over the 3.0 x 2.0 deg field.
  6: <int>[
    2614, 2615, 2617, 2619, 2620, 2621, 2622, 2623, //
    2658, 2659, 2664, 2665, 2666, 2667, //
    2704, 2705, 2706, 2707, 2708, 2709, 2710, 2711, 2713, 2716, 2717, //
    2752, 2753, 2754, //
  ],
};

/// The plate scale the tile lists were computed against, recorded for audit
/// (mirrors the values in the committed `fixture_field.dart`).
const ({
  double fovWidthDeg,
  double fovHeightDeg,
  int pixelWidth,
  int pixelHeight,
})
fixturePlate = (
  fovWidthDeg: 3.0,
  fovHeightDeg: 2.0,
  pixelWidth: 900,
  pixelHeight: 600,
);

Future<int> main(List<String> args) async {
  final flags = _parseArgs(args);
  final outRoot = flags.outDir ?? _defaultOutDir();

  stdout.writeln('HiPS fixture fetcher');
  stdout.writeln(
    '  field   : $fieldName  (RA $fieldRaDeg deg, Dec $fieldDecDeg deg)',
  );
  stdout.writeln('  survey  : $surveyHipsId');
  stdout.writeln('  base    : $surveyBaseUrl');
  stdout.writeln('  out     : ${outRoot.path}');
  if (flags.dryRun) stdout.writeln('  mode    : DRY RUN (no files written)');
  stdout.writeln('');

  final client = HttpClient()
    ..userAgent = 'skotiq-hips-fixture-fetcher/1.0'
    ..connectionTimeout = const Duration(seconds: 30);

  var fetched = 0;
  var skipped = 0;
  try {
    // 1) properties metadata document.
    fetched += await _fetchText(
      client,
      url: '$surveyBaseUrl/properties',
      dest: File('${outRoot.path}/dss2color_properties.txt'),
      flags: flags,
      onSkip: () => skipped++,
    );

    // 2) Allsky whole-sky preview (Norder3 for this survey).
    fetched += await _fetchJpeg(
      client,
      url: '$surveyBaseUrl/Norder$allskyOrder/Allsky.jpg',
      dest: File('${outRoot.path}/Allsky.jpg'),
      flags: flags,
      onSkip: () => skipped++,
    );

    // 3) Per-order tiles, each under its standard Norder{k}/Dir{bucket}/ path.
    final orders = tilesByOrder.keys.toList()..sort();
    for (final order in orders) {
      final npixList = tilesByOrder[order]!;
      for (final npix in npixList) {
        final bucket = (npix ~/ 10000) * 10000;
        final rel = 'Norder$order/Dir$bucket/Npix$npix.jpg';
        fetched += await _fetchJpeg(
          client,
          url: '$surveyBaseUrl/$rel',
          dest: File('${outRoot.path}/$rel'),
          flags: flags,
          onSkip: () => skipped++,
        );
      }
    }
  } on _FetchFailure catch (e) {
    stderr.writeln('FATAL: ${e.message}');
    return 1;
  } finally {
    client.close(force: true);
  }

  stdout.writeln('');
  stdout.writeln(
    'Done. fetched=$fetched skipped=$skipped'
    '${flags.dryRun ? ' (dry run)' : ''}',
  );
  return 0;
}

/// Parsed command-line flags.
class _Flags {
  final Directory? outDir;
  final bool dryRun;
  final bool force;
  const _Flags({this.outDir, required this.dryRun, required this.force});
}

_Flags _parseArgs(List<String> args) {
  Directory? out;
  var dryRun = false;
  var force = false;
  for (final arg in args) {
    if (arg == '--dry-run') {
      dryRun = true;
    } else if (arg == '--force') {
      force = true;
    } else if (arg.startsWith('--out=')) {
      out = Directory(arg.substring('--out='.length));
    } else {
      stderr.writeln('Unknown argument: $arg');
      stderr.writeln(
        'Usage: dart run tools/hips_fixtures/fetch_hips_fixtures.dart '
        '[--out=<dir>] [--dry-run] [--force]',
      );
      exit(64); // EX_USAGE
    }
  }
  return _Flags(outDir: out, dryRun: dryRun, force: force);
}

/// Resolves the in-repo fixture root relative to this script's location so the
/// tool works regardless of the current working directory.
Directory _defaultOutDir() {
  // Script lives at <repo>/tools/hips_fixtures/fetch_hips_fixtures.dart.
  final scriptFile = File.fromUri(Platform.script);
  final toolDir = scriptFile.parent; // tools/hips_fixtures
  final repoRoot = toolDir.parent.parent; // <repo>
  return Directory(
    '${repoRoot.path}/packages/skotiq_app/test/fixtures/hips',
  );
}

/// Thrown for any non-recoverable fetch problem (surfaced, never swallowed).
class _FetchFailure implements Exception {
  final String message;
  const _FetchFailure(this.message);
  @override
  String toString() => message;
}

/// Fetches a text document (the properties file). Returns 1 if written, 0 if
/// skipped.
Future<int> _fetchText(
  HttpClient client, {
  required String url,
  required File dest,
  required _Flags flags,
  required void Function() onSkip,
}) async {
  if (!flags.force && dest.existsSync()) {
    stdout.writeln('skip  ${dest.path}  (exists; use --force to refetch)');
    onSkip();
    return 0;
  }
  if (flags.dryRun) {
    stdout.writeln('GET   $url  ->  ${dest.path}');
    return 1;
  }
  final bytes = await _get(client, url);
  if (bytes.isEmpty) {
    throw _FetchFailure('empty body for $url');
  }
  dest.parent.createSync(recursive: true);
  dest.writeAsBytesSync(bytes);
  stdout.writeln('GET   $url  ->  ${dest.path}  (${bytes.length} bytes)');
  return 1;
}

/// Fetches a JPEG tile/Allsky and validates the magic bytes before writing.
/// Returns 1 if written, 0 if skipped.
Future<int> _fetchJpeg(
  HttpClient client, {
  required String url,
  required File dest,
  required _Flags flags,
  required void Function() onSkip,
}) async {
  if (!flags.force && dest.existsSync()) {
    stdout.writeln('skip  ${dest.path}  (exists; use --force to refetch)');
    onSkip();
    return 0;
  }
  if (flags.dryRun) {
    stdout.writeln('GET   $url  ->  ${dest.path}');
    return 1;
  }
  final bytes = await _get(client, url);
  // JPEG SOI marker is 0xFF 0xD8; EOI is 0xFF 0xD9. Validate so a captive-portal
  // HTML error page or a truncated download never lands as a "tile".
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) {
    throw _FetchFailure(
      'response for $url is not a JPEG (first bytes '
      '${bytes.take(4).map((b) => b.toRadixString(16)).join(' ')})',
    );
  }
  if (bytes[bytes.length - 2] != 0xFF || bytes[bytes.length - 1] != 0xD9) {
    throw _FetchFailure('JPEG for $url is truncated (missing EOI marker)');
  }
  dest.parent.createSync(recursive: true);
  dest.writeAsBytesSync(bytes);
  stdout.writeln('GET   $url  ->  ${dest.path}  (${bytes.length} bytes)');
  return 1;
}

/// Performs a GET, following redirects, surfacing any non-200 as a failure.
Future<Uint8List> _get(HttpClient client, String url) async {
  final request = await client.getUrl(Uri.parse(url));
  request.followRedirects = true;
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    // Drain so the socket can be reused/closed cleanly before throwing.
    await response.drain<void>();
    throw _FetchFailure('HTTP ${response.statusCode} for $url');
  }
  final chunks = <int>[];
  await for (final chunk in response) {
    chunks.addAll(chunk);
  }
  return Uint8List.fromList(chunks);
}
