import '../../models/import/canonical_sequence_node.dart';
import '../../models/import/import_result.dart';
import 'telescopius_csv_importer.dart' show TelescopiusCsvImporter;

/// Importer for iCalendar (.ics) exports.
///
/// Many planning tools (Telescopius, Astroplanner, custom scripts) publish
/// observing schedules as `.ics` calendars. Each `VEVENT` becomes one
/// TargetHeaderNode:
///
/// * `SUMMARY` → target name.
/// * `DESCRIPTION` is mined for `RA: 05h35m17s` / `Dec: -05°23'28"` pairs
///   (case-insensitive). Free-form text outside those tokens becomes the
///   target notes.
/// * `DTSTART` → `startAfter` (when present and in the future).
/// * `LOCATION` is preserved verbatim in notes for context.
///
/// VEVENTs that don't carry parseable RA/Dec are surfaced in
/// [IcsImportResult.unresolved] — the UI can prompt the user for
/// coordinates or skip them.
class IcsCalendarImporter {
  /// Quick sniff: ICS files begin with `BEGIN:VCALENDAR` (case-sensitive in
  /// the RFC but we accept any case for robustness).
  static bool sniff(String content) {
    final trimmed = content.trimLeft();
    if (trimmed.length < 16) return false;
    return RegExp(
      r'^BEGIN:VCALENDAR',
      caseSensitive: false,
    ).hasMatch(trimmed.substring(0, 16));
  }

  IcsImportResult parse(String content, {String? sequenceName}) {
    final unfolded = _unfold(content);
    final lines = unfolded.split('\n');

    final events = <_VEvent>[];
    _VEvent? current;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.toUpperCase() == 'BEGIN:VEVENT') {
        current = _VEvent();
        continue;
      }
      if (line.toUpperCase() == 'END:VEVENT') {
        if (current != null) events.add(current);
        current = null;
        continue;
      }
      if (current == null) continue;
      final sep = line.indexOf(':');
      if (sep < 0) continue;
      // Strip parameters off the property name: `DTSTART;TZID=America/Denver:`.
      final propRaw = line.substring(0, sep);
      final value = line.substring(sep + 1);
      final semi = propRaw.indexOf(';');
      final prop = (semi < 0 ? propRaw : propRaw.substring(0, semi))
          .toUpperCase()
          .trim();
      final unescaped = _unescapeIcs(value);
      switch (prop) {
        case 'SUMMARY':
          current.summary = unescaped;
          break;
        case 'DESCRIPTION':
          current.description = unescaped;
          break;
        case 'LOCATION':
          current.location = unescaped;
          break;
        case 'DTSTART':
          current.dtStart = _parseIcsDateTime(unescaped);
          break;
        case 'DTEND':
          current.dtEnd = _parseIcsDateTime(unescaped);
          break;
      }
    }

    if (events.isEmpty) {
      throw MalformedSourceError('iCalendar file has no VEVENT entries');
    }

    final children = <CanonicalSequenceNode>[];
    final unresolved = <UnresolvedIcsEvent>[];
    var resolvedCount = 0;

    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      final summary = e.summary?.trim();
      if (summary == null || summary.isEmpty) {
        unresolved.add(
          UnresolvedIcsEvent(
            index: i,
            summary: '<no summary>',
            reason: 'VEVENT has no SUMMARY',
          ),
        );
        continue;
      }
      final coords =
          _extractCoords(e.description ?? '') ?? _extractCoords(summary);
      if (coords == null) {
        unresolved.add(
          UnresolvedIcsEvent(
            index: i,
            summary: summary,
            reason: 'No RA/Dec found in SUMMARY or DESCRIPTION',
          ),
        );
        continue;
      }
      resolvedCount++;
      final notes = _buildNotes(e);
      final attrs = <String, Object?>{
        'targetName': summary,
        'raHours': coords.raHours,
        'decDegrees': coords.decDegrees,
        if (notes != null) 'notes': notes,
        if (e.dtStart != null) 'startAfter': e.dtStart!.toIso8601String(),
        if (e.dtEnd != null) 'endBefore': e.dtEnd!.toIso8601String(),
      };
      children.add(
        CanonicalSequenceNode(
          kind: CanonicalKind.targetHeader,
          name: summary,
          sourceType: 'IcsVEvent',
          attributes: attrs,
        ),
      );
    }

    final root = CanonicalSequenceNode(
      kind: CanonicalKind.sequential,
      name: sequenceName ?? 'Calendar Import',
      sourceType: 'IcsCalendar',
      attributes: {
        'totalEvents': events.length,
        'resolvedEvents': resolvedCount,
        'unresolvedEvents': unresolved.length,
      },
      children: children,
    );

    return IcsImportResult(
      root: root,
      unresolved: unresolved,
      totalEvents: events.length,
    );
  }

  /// RFC-5545 line unfolding: continuation lines start with a space or tab.
  String _unfold(String content) {
    final lines = content.split('\n');
    final buf = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      if (i > 0 && line.startsWith(' ') || (i > 0 && line.startsWith('\t'))) {
        buf.write(line.substring(1));
      } else {
        if (i > 0) buf.write('\n');
        buf.write(line);
      }
    }
    return buf.toString();
  }

  String _unescapeIcs(String s) {
    return s
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\N', '\n')
        .replaceAll(r'\,', ',')
        .replaceAll(r'\;', ';')
        .replaceAll(r'\\', '\\');
  }

  /// Extract a `RA: ... Dec: ...` pair from free-form text. Both `RA` /
  /// `R.A.` and `Dec` / `Declination` are accepted as labels.
  _Coord? _extractCoords(String text) {
    final raMatch = RegExp(
      r'(?:R\.?A\.?|RIGHT\s+ASCENSION)\s*[:=]\s*([^\n,;]+)',
      caseSensitive: false,
    ).firstMatch(text);
    final decMatch = RegExp(
      r'(?:DEC(?:LINATION)?)\s*[:=]\s*([^\n,;]+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (raMatch == null || decMatch == null) return null;
    final ra = TelescopiusCsvImporter.parseRaToHours(raMatch.group(1)!);
    final dec = TelescopiusCsvImporter.parseDecToDegrees(decMatch.group(1)!);
    if (ra == null || dec == null) return null;
    return _Coord(ra, dec);
  }

  String? _buildNotes(_VEvent e) {
    final parts = <String>[];
    if (e.description != null && e.description!.trim().isNotEmpty) {
      parts.add(e.description!.trim());
    }
    if (e.location != null && e.location!.trim().isNotEmpty) {
      parts.add('Location: ${e.location!.trim()}');
    }
    return parts.isEmpty ? null : parts.join('\n\n');
  }

  /// Parse an ICS date-time value into a UTC [DateTime].
  /// Accepts `YYYYMMDDTHHMMSSZ`, `YYYYMMDDTHHMMSS` (floating), and
  /// `YYYYMMDD` (date-only — interpreted as 00:00 UTC).
  static DateTime? _parseIcsDateTime(String raw) {
    final text = raw.trim();
    if (text.length < 8) return null;
    try {
      final isUtc = text.endsWith('Z');
      final body = isUtc ? text.substring(0, text.length - 1) : text;
      if (body.length >= 15 && body[8] == 'T') {
        final y = int.parse(body.substring(0, 4));
        final mo = int.parse(body.substring(4, 6));
        final d = int.parse(body.substring(6, 8));
        final h = int.parse(body.substring(9, 11));
        final mi = int.parse(body.substring(11, 13));
        final s = body.length >= 15 ? int.parse(body.substring(13, 15)) : 0;
        return isUtc
            ? DateTime.utc(y, mo, d, h, mi, s)
            : DateTime(y, mo, d, h, mi, s);
      }
      if (body.length >= 8) {
        final y = int.parse(body.substring(0, 4));
        final mo = int.parse(body.substring(4, 6));
        final d = int.parse(body.substring(6, 8));
        return DateTime.utc(y, mo, d);
      }
    } catch (_) {
      // Malformed timestamp — caller treats as null.
    }
    return null;
  }
}

class IcsImportResult {
  final CanonicalSequenceNode root;
  final List<UnresolvedIcsEvent> unresolved;
  final int totalEvents;

  IcsImportResult({
    required this.root,
    required this.unresolved,
    required this.totalEvents,
  });
}

class UnresolvedIcsEvent {
  final int index;
  final String summary;
  final String reason;
  const UnresolvedIcsEvent({
    required this.index,
    required this.summary,
    required this.reason,
  });
}

class _VEvent {
  String? summary;
  String? description;
  String? location;
  DateTime? dtStart;
  DateTime? dtEnd;
}

class _Coord {
  final double raHours;
  final double decDegrees;
  _Coord(this.raHours, this.decDegrees);
}
