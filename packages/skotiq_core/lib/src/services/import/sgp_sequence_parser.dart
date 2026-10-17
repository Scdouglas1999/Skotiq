import 'dart:convert';

import '../../models/import/canonical_sequence_node.dart';
import '../../models/import/import_result.dart';

/// Parses Sequence Generator Pro `.sgf` files into a [CanonicalSequenceNode]
/// tree.
///
/// SGP's format is JSON with a target list (`TargetSet`) where each target
/// carries an `Events` array describing per-filter exposure plans plus a
/// `Reference` block holding the slew coordinates. The mapper converts each
/// target into a `targetHeader` -> `[slew, loop[exposure...]]` subtree.
class SgpSequenceParser {
  static bool sniff(String content) {
    if (!content.contains('{')) return false;
    // Strong SGP signal: TargetSet plus SGP-specific keys.
    final hasTargetSet = content.contains('"TargetSet"');
    if (hasTargetSet && content.contains('"Events"')) return true;
    if (content.contains('"SequenceTitle"') &&
        content.contains('"TargetName"')) {
      return true;
    }
    // Some older `.sgf` files use `Sequence` + `Profile` at the root.
    if (content.contains('"Sequence"') &&
        content.contains('"Profile"') &&
        content.contains('"TargetName"')) {
      return true;
    }
    return false;
  }

  CanonicalSequenceNode parse(String content) {
    Object? raw;
    try {
      raw = jsonDecode(content);
    } catch (e) {
      throw MalformedSourceError('SGP file is not valid JSON', cause: e);
    }
    if (raw is! Map<String, dynamic>) {
      throw MalformedSourceError(
        'SGP root must be a JSON object, got ${raw.runtimeType}',
      );
    }

    final title =
        raw['SequenceTitle']?.toString() ??
        raw['Name']?.toString() ??
        'SGP Sequence';

    final targets = _extractTargets(raw);
    if (targets.isEmpty) {
      throw MalformedSourceError(
        'SGP file has no targets (expected TargetSet[].Target or Targets[])',
      );
    }

    final targetNodes = <CanonicalSequenceNode>[];
    for (final t in targets) {
      targetNodes.add(_parseTarget(t));
    }

    return CanonicalSequenceNode(
      kind: CanonicalKind.sequential,
      name: title,
      sourceType: 'SgpSequence',
      attributes: {
        if (raw['Profile'] != null) 'profile': raw['Profile'].toString(),
        if (raw['Notes'] != null) 'notes': raw['Notes'].toString(),
      },
      children: targetNodes,
    );
  }

  List<Map<String, dynamic>> _extractTargets(Map<String, dynamic> root) {
    final out = <Map<String, dynamic>>[];

    // Modern SGP: `TargetSet` is a list of wrappers each holding a `Target`.
    final ts = root['TargetSet'];
    if (ts is List) {
      for (final entry in ts) {
        if (entry is Map<String, dynamic>) {
          final target = entry['Target'];
          if (target is Map<String, dynamic>) {
            out.add(target);
          } else {
            out.add(entry); // flat shape
          }
        }
      }
    }

    // Older SGP: flat `Targets`.
    if (out.isEmpty) {
      final flat = root['Targets'];
      if (flat is List) {
        for (final entry in flat) {
          if (entry is Map<String, dynamic>) out.add(entry);
        }
      }
    }

    // Single-target SGP profile sequence with target at root.
    if (out.isEmpty && root.containsKey('TargetName')) {
      out.add(root);
    }

    return out;
  }

  CanonicalSequenceNode _parseTarget(Map<String, dynamic> t) {
    final name =
        t['TargetName']?.toString() ??
        t['Name']?.toString() ??
        'Untitled Target';
    final ref = (t['Reference'] is Map<String, dynamic>)
        ? t['Reference'] as Map<String, dynamic>
        : t;
    final raHours = _readDouble(ref['RAHours'] ?? ref['RA'] ?? t['RA']);
    final decDegrees = _readDouble(
      ref['Dec'] ?? ref['Declination'] ?? t['Dec'],
    );
    final rotation = _readDouble(ref['Rotation'] ?? t['Rotation']);

    // Per-event exposure children.
    final events = (t['Events'] is List) ? t['Events'] as List : const [];
    final exposureChildren = <CanonicalSequenceNode>[];

    // Optional slew at the start (only if we know the coords).
    final slewChildren = <CanonicalSequenceNode>[];
    if (raHours != null && decDegrees != null) {
      slewChildren.add(
        CanonicalSequenceNode(
          kind: CanonicalKind.slew,
          name: 'Slew to $name',
          sourceType: 'SgpSlew',
          attributes: {'raHours': raHours, 'decDegrees': decDegrees},
        ),
      );
    }

    // SGP "AutoCenter": top-level key on target.
    final autoCenter = _readBool(t['AutoCenter']) ?? false;
    if (autoCenter && raHours != null && decDegrees != null) {
      slewChildren.add(
        CanonicalSequenceNode(
          kind: CanonicalKind.center,
          name: 'Center $name',
          sourceType: 'SgpAutoCenter',
          attributes: {'raHours': raHours, 'decDegrees': decDegrees},
        ),
      );
    }

    int totalExposureCount = 0;
    for (final raw in events) {
      if (raw is! Map<String, dynamic>) continue;
      final exposureTime = _readDouble(raw['ExposureTime']);
      final count =
          _readInt(raw['NumExposures'] ?? raw['Repeat'] ?? raw['Count']) ?? 1;
      final filter = raw['Filter']?.toString();
      final binning = _readInt(raw['Binning']) ?? 1;
      final gain = _readInt(raw['Gain']);
      final offset = _readInt(raw['Offset']);
      final imageType = raw['ImageType']?.toString() ?? 'Light';

      // Disabled events still get reported as decorative drops by the mapper.
      final enabled = _readBool(raw['Enabled'] ?? raw['IsEnabled']) ?? true;
      if (!enabled) {
        exposureChildren.add(
          CanonicalSequenceNode(
            kind: CanonicalKind.annotation,
            name: 'Disabled event ($filter, ${exposureTime}s)',
            sourceType: 'SgpDisabledEvent',
            attributes: const {'reason': 'event disabled in source'},
          ),
        );
        continue;
      }

      if (filter != null && filter.isNotEmpty) {
        exposureChildren.add(
          CanonicalSequenceNode(
            kind: CanonicalKind.filterChange,
            name: 'Filter: $filter',
            sourceType: 'SgpFilterChange',
            attributes: {'filterName': filter},
          ),
        );
      }

      exposureChildren.add(
        CanonicalSequenceNode(
          kind: CanonicalKind.exposure,
          name: '${filter ?? imageType} ${exposureTime}s x $count',
          sourceType: 'SgpEvent',
          attributes: {
            'exposureTime': exposureTime,
            'count': count,
            'filterName': filter,
            'binning': binning,
            'gain': gain,
            'offset': offset,
            'imageType': imageType,
          },
        ),
      );
      totalExposureCount += count;
    }

    final body = <CanonicalSequenceNode>[
      ...slewChildren,
      if (exposureChildren.isNotEmpty)
        CanonicalSequenceNode(
          kind: CanonicalKind.loop,
          name: 'Exposures',
          sourceType: 'SgpExposurePlan',
          attributes: {'iterations': 1, '_exposureCount': totalExposureCount},
          children: exposureChildren,
        ),
    ];

    return CanonicalSequenceNode(
      kind: CanonicalKind.targetHeader,
      name: name,
      sourceType: 'SgpTarget',
      attributes: {
        if (raHours != null) 'raHours': raHours,
        if (decDegrees != null) 'decDegrees': decDegrees,
        if (rotation != null) 'rotation': rotation,
      },
      children: body,
    );
  }

  double? _readDouble(Object? v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  int? _readInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  bool? _readBool(Object? v) {
    if (v == null) return null;
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final lower = v.toLowerCase();
      if (lower == 'true' || lower == 'yes' || lower == '1') return true;
      if (lower == 'false' || lower == 'no' || lower == '0') return false;
    }
    return null;
  }
}
