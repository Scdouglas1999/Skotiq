part of '../mosaic_project_service.dart';

/// Choose the single per-panel master the stitcher will consume from the
/// per-filter [outcomes] of one panel's integration.
///
/// A panel is one sky region but may have been captured across several
/// filters; the stitcher takes exactly one master per panel. The pick is
/// deliberate (NOT iteration order, which is just the first-accepted-sub order
/// of the filter groups): prefer luminance ('L', case-insensitive) when
/// present — it is the broadest-band, highest-SNR frame and the natural
/// stitch base — else the outcome with the most integrated frames (deepest,
/// most reliable registration), tie-broken by the first such outcome.
///
/// [outcomes] is always non-empty here: [PostSessionIntegrationService.integrate]
/// throws on empty subs and yields one outcome per non-empty filter group.
int _representativeMasterId(List<PostSessionIntegrationOutcome> outcomes) {
  for (final outcome in outcomes) {
    if (outcome.filter?.trim().toUpperCase() == 'L') {
      return outcome.masterId;
    }
  }
  var best = outcomes.first;
  for (final outcome in outcomes.skip(1)) {
    if (outcome.result.framesIntegrated > best.result.framesIntegrated) {
      best = outcome;
    }
  }
  return best.masterId;
}

/// A filesystem-safe slug of a project name for the output file stem.
String _slug(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return 'mosaic';
  return trimmed.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
}

/// Insert [suffix] before the path's extension (`panel_0.fits` →
/// `panel_0_R.fits`). If the file segment has no `.`, the suffix is appended.
/// Mirrors `PostSessionIntegrationService`'s own derivation so the per-filter
/// master base path lines up with the preview/.png + rejection-map siblings
/// the integration service derives from it.
String _suffixBeforeExtension(String path, String suffix) {
  final slash = path.lastIndexOf(RegExp(r'[\\/]'));
  final dot = path.lastIndexOf('.');
  if (dot <= slash) return '$path$suffix';
  return '${path.substring(0, dot)}$suffix${path.substring(dot)}';
}

/// Join a directory and a file stem with a single separator, tolerating a
/// trailing slash on the directory.
String _join(String dir, String name) {
  if (dir.isEmpty) return name;
  final trimmed = dir.endsWith('/') || dir.endsWith('\\')
      ? dir.substring(0, dir.length - 1)
      : dir;
  return '$trimmed/$name';
}
