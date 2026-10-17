// Commit-time validation + live preview for the capture file-naming pattern.
//
// The capture pipeline (`ImagingService.buildImageFilePath`) refuses unknown
// `$TOKEN`s and unsafe path segments by throwing, and that throw fails the
// exposure. Before this existed the settings field accepted and persisted any
// string, so a typo like `$TARGET_$BANANA` was only reported when the first
// frame of the night completed. This validator applies the same rules at the
// moment the field is committed.
//
// The rules below are a deliberate mirror of the private
// `ImagingService._patternVariables` / `expandNamingPattern` /
// `buildImageFilePath` logic (they are not reachable from this package:
// `_patternVariables` is private and the entry points are
// `@visibleForTesting`). `test/screens/settings/imaging_naming_pattern_test.dart`
// cross-checks every accept/reject decision AND the rendered preview against
// the real `ImagingService` implementation, so drift between the two fails a
// test rather than reaching a user at 2am.

import 'package:path/path.dart' as p;

/// Every `$VARIABLE` the capture pipeline substitutes.
///
/// Mirrors `ImagingService._patternVariables` (including the `$EXPOSURE` and
/// `$SEQ` aliases, which `NamingPattern.availableVariables` omits).
const Set<String> kNamingPatternVariables = {
  r'$TARGET',
  r'$FILTER',
  r'$EXPTIME',
  r'$EXPOSURE',
  r'$DATE',
  r'$TIME',
  r'$DATETIME',
  r'$FRAMETYPE',
  r'$FRAMENUM',
  r'$SEQ',
  r'$GAIN',
  r'$OFFSET',
  r'$TEMP',
  r'$BINNING',
  r'$CAMERA',
  r'$TELESCOPE',
  r'$SEQUENCE',
  r'$SESSION',
};

/// Mirrors `ImagingService._patternVarRegex`: uppercase letters only, so `_`
/// stays a literal separator between adjacent variables.
final RegExp _patternVarRegex = RegExp(r'\$[A-Z]+');

/// Mirrors `ImagingService._unsafePathComponentChars`.
final RegExp _unsafePathComponentChars = RegExp(r'[<>:"/\\|?*\x00-\x1F]');

/// Outcome of checking a candidate naming pattern.
class NamingPatternCheck {
  const NamingPatternCheck._(this.error, this.preview);

  /// Human-readable reason the pattern would fail at capture time, or null
  /// when the pattern is usable.
  final String? error;

  /// Example relative path (including extension) the pattern resolves to,
  /// or null when [error] is set.
  final String? preview;

  bool get isValid => error == null;
}

/// Example substitution values used for the preview.
///
/// Shaped exactly like `ImagingService.buildTimestampSubstitutions` so the
/// preview is produced by the same value conventions the pipeline uses
/// (UTC date/time, one-decimal exposure, 4-digit zero-padded frame number).
Map<String, String> namingPatternExampleSubstitutions({DateTime? now}) {
  final utcTs = (now ?? DateTime.now()).toUtc();
  final iso = utcTs.toIso8601String();
  final dateStr = iso.substring(0, 10);
  final timeStr = iso.substring(11, 19).replaceAll(':', '-');
  return {
    r'$TARGET': 'M31',
    r'$FILTER': 'L',
    r'$EXPTIME': '120.0',
    r'$EXPOSURE': '120.0',
    r'$DATE': dateStr,
    r'$TIME': timeStr,
    r'$DATETIME': '${dateStr}_$timeStr',
    r'$FRAMETYPE': 'light',
    r'$FRAMENUM': '0001',
    r'$SEQ': '0001',
    r'$GAIN': '100',
    r'$OFFSET': '10',
    r'$TEMP': '-10C',
    r'$BINNING': '1x1',
    r'$CAMERA': 'Camera',
    r'$TELESCOPE': 'Telescope',
    r'$SEQUENCE': 'M31',
    r'$SESSION': dateStr.replaceAll('-', ''),
  };
}

/// Validate [pattern] against the capture pipeline's rules and, when it is
/// usable, render the example path it would produce.
NamingPatternCheck checkNamingPattern(
  String pattern, {
  String extension = 'fits',
  DateTime? now,
}) {
  if (pattern.trim().isEmpty ||
      p.isAbsolute(pattern) ||
      pattern.startsWith('/') ||
      pattern.startsWith(r'\')) {
    return const NamingPatternCheck._(
      'The naming pattern must be a non-empty relative path.',
      null,
    );
  }

  final unknown = <String>{};
  for (final match in _patternVarRegex.allMatches(pattern)) {
    final token = match.group(0)!;
    if (!kNamingPatternVariables.contains(token)) unknown.add(token);
  }
  if (unknown.isNotEmpty) {
    final sorted = unknown.toList()..sort();
    return NamingPatternCheck._(
      'Unknown variable${sorted.length > 1 ? 's' : ''} '
      '${sorted.join(', ')}. Supported: '
      '${(kNamingPatternVariables.toList()..sort()).join(', ')}.',
      null,
    );
  }

  final substitutions = namingPatternExampleSubstitutions(now: now);
  final expanded = pattern.replaceAllMapped(
    _patternVarRegex,
    (m) => substitutions[m.group(0)!]!,
  );
  if (expanded.contains(r'$')) {
    return const NamingPatternCheck._(
      'The naming pattern contains an invalid variable. Variables are '
      r'uppercase letters after a $, e.g. $TARGET.',
      null,
    );
  }

  final segments = expanded.split('/');
  for (final segment in segments) {
    if (segment.isEmpty ||
        segment == '.' ||
        segment == '..' ||
        segment.contains(r'\') ||
        _unsafePathComponentChars.hasMatch(segment)) {
      return NamingPatternCheck._(
        'Unsafe path segment "$segment". Segments cannot be empty, "." or '
        r'"..", and cannot contain \ < > : " | ? *.',
        null,
      );
    }
  }

  final stem = segments.removeLast();
  return NamingPatternCheck._(
    null,
    [...segments, '$stem.$extension'].join('/'),
  );
}
