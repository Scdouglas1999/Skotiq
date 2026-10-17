import 'dart:convert';

import '../../models/import/canonical_sequence_node.dart';
import '../../models/import/import_result.dart';

/// Parses NINA (Nighttime Imaging 'N' Astronomy) sequence JSON exports into a
/// [CanonicalSequenceNode] tree.
///
/// NINA uses Newtonsoft.Json with `$type` discriminators of the form
/// `"NINA.Sequencer.SequenceItem.Imaging.TakeExposure, NINA"`. Container nodes
/// (`Container`, `SequentialContainer`, `ParallelContainer`,
/// `DeepSkyObjectContainer`, etc.) carry their children in an `Items` array
/// and their watchdog triggers in a `Triggers` array.
class NinaSequenceParser {
  /// Quick format sniff: does the leading slice of [content] look like a NINA
  /// export?
  static bool sniff(String content) {
    // NINA-specific discriminator prefix is unmistakable.
    if (content.contains('NINA.Sequencer.')) return true;
    if (content.contains('NINA.Core.')) return true;
    // Some NINA exports omit assembly names; fall back to namespace hints
    // alongside Newtonsoft's `$type` key.
    if (content.contains('"\$type"') &&
        (content.contains('NINA.Sequencer') ||
            content.contains('SequenceContainer'))) {
      return true;
    }
    return false;
  }

  /// Parse [content] into a canonical tree. Throws [MalformedSourceError] if
  /// the JSON is invalid or doesn't have a recognizable root.
  CanonicalSequenceNode parse(String content) {
    Object? raw;
    try {
      raw = jsonDecode(content);
    } catch (e) {
      throw MalformedSourceError('NINA file is not valid JSON', cause: e);
    }
    if (raw is! Map<String, dynamic>) {
      throw MalformedSourceError(
        'NINA root must be a JSON object, got ${raw.runtimeType}',
      );
    }
    return _parseNode(raw);
  }

  CanonicalSequenceNode _parseNode(Map<String, dynamic> json) {
    final rawType = (json[r'$type'] ?? json['Type'] ?? '').toString();
    final shortType = _shortenType(rawType);
    final displayName = _displayName(json, shortType);

    final children = _parseChildList(json, key: 'Items');
    final triggers = _parseChildList(json, key: 'Triggers');
    final conditions = _parseChildList(json, key: 'Conditions');

    final kind = _classify(shortType, hasChildren: children.isNotEmpty);
    final attrs = _extractAttributes(json, kind);

    final enabled = _readBool(json['Enabled'] ?? json['IsEnabled']) ?? true;
    final mergedAttrs = <String, Object?>{
      ...attrs,
      if (!enabled) '_disabled': true,
      if (rawType.isNotEmpty) '_rawType': rawType,
    };

    // For container-shaped nodes, conditions provide loop semantics and
    // triggers provide watchdog children we attach in-line at the end of the
    // child list (so they execute alongside the container body).
    final mergedChildren = <CanonicalSequenceNode>[...children, ...triggers];

    // Conditions on a Container in NINA generally describe loop termination.
    // We surface the first recognizable condition's parameters on the
    // container itself; that lets the mapper turn `Container + LoopCondition`
    // into a `LoopLogic` correctly.
    final withCondition = _foldConditions(mergedAttrs, conditions);

    // Propagate an iterating container's count down to child exposures that
    // carry no own count. A plain `TakeExposure` inside a `LoopContainer`
    // (or any container with an Iterations/CountCondition) would otherwise
    // resolve to count==1 and silently undercount the planned frames.
    final propagatedChildren = _propagateLoopCount(
      kind,
      withCondition,
      mergedChildren,
    );

    return CanonicalSequenceNode(
      kind: kind,
      name: displayName,
      sourceType: shortType.isEmpty ? rawType : shortType,
      attributes: withCondition,
      children: propagatedChildren,
    );
  }

  /// Stamp the iteration count of an iterating container onto direct-child
  /// exposures that have no count of their own. A plain `TakeExposure`
  /// inside a `LoopContainer` with `Iterations: 30` should yield 30 frames,
  /// not 1. Only applied when the loop count is resolvable; an
  /// unresolvable count leaves the child untouched (mapper defaults to 1).
  List<CanonicalSequenceNode> _propagateLoopCount(
    CanonicalKind parentKind,
    Map<String, Object?> parentAttrs,
    List<CanonicalSequenceNode> children,
  ) {
    final isIterating =
        parentKind == CanonicalKind.loop ||
        parentAttrs['iterations'] != null ||
        parentAttrs['_loopCountFromCondition'] != null;
    if (!isIterating) return children;

    final loopCount = _readInt(
      parentAttrs['iterations'] ?? parentAttrs['_loopCountFromCondition'],
    );
    if (loopCount == null || loopCount <= 1) return children;

    var changed = false;
    final out = <CanonicalSequenceNode>[];
    for (final child in children) {
      if (child.kind == CanonicalKind.exposure &&
          child.attributes['count'] == null) {
        out.add(
          child.copyWith(
            attributes: <String, Object?>{
              ...child.attributes,
              'count': loopCount,
            },
          ),
        );
        changed = true;
      } else {
        out.add(child);
      }
    }
    return changed ? out : children;
  }

  List<CanonicalSequenceNode> _parseChildList(
    Map<String, dynamic> json, {
    required String key,
  }) {
    final raw = json[key];
    if (raw is! List) return const [];
    final out = <CanonicalSequenceNode>[];
    for (final entry in raw) {
      if (entry is Map<String, dynamic>) {
        // NINA wraps lists with `$values` in some serializer modes.
        if (entry.containsKey(r'$values') && entry[r'$values'] is List) {
          for (final inner in entry[r'$values'] as List) {
            if (inner is Map<String, dynamic>) {
              out.add(_parseNode(inner));
            }
          }
        } else {
          out.add(_parseNode(entry));
        }
      }
    }
    // Wrapper-only case: list is itself `{ "$values": [...] }`.
    if (out.isEmpty && raw.length == 1) {
      final only = raw.first;
      if (only is Map<String, dynamic> && only[r'$values'] is List) {
        for (final inner in only[r'$values'] as List) {
          if (inner is Map<String, dynamic>) out.add(_parseNode(inner));
        }
      }
    }
    return out;
  }

  Map<String, Object?> _foldConditions(
    Map<String, Object?> attrs,
    List<CanonicalSequenceNode> conditions,
  ) {
    if (conditions.isEmpty) return attrs;
    final out = <String, Object?>{...attrs};
    for (final c in conditions) {
      switch (c.sourceType) {
        case 'LoopCondition':
        case 'CountCondition':
        case 'IterationsCondition':
          final iterations = _readInt(
            c.attributes['Iterations'] ?? c.attributes['Count'],
          );
          out['_loopCountFromCondition'] = iterations;
          // NINA stores the iteration count on a child LoopCondition rather
          // than on the parent LoopContainer itself. Surface it under the
          // canonical `iterations` key so downstream mapping doesn't need to
          // know which NINA shape produced it.
          if (iterations != null && out['iterations'] == null) {
            out['iterations'] = iterations;
          }
          break;
        case 'TimeCondition':
        case 'TimeSpanCondition':
          final iso = c.attributes['DateTime'] ?? c.attributes['UntilTime'];
          if (iso is String) out['_loopUntilTime'] = iso;
          break;
        case 'AltitudeCondition':
          final alt = _readDouble(
            c.attributes['Offset'] ??
                c.attributes['Altitude'] ??
                c.attributes['Threshold'],
          );
          if (alt != null) out['_loopUntilAltitude'] = alt;
          break;
        case 'LoopForeverCondition':
        case 'WhileCondition':
          out['_loopForever'] = true;
          break;
      }
    }
    return out;
  }

  String _shortenType(String rawType) {
    if (rawType.isEmpty) return '';
    // Newtonsoft format: "NINA.Sequencer.SequenceItem.Imaging.TakeExposure, NINA"
    final commaIdx = rawType.indexOf(',');
    final beforeAsm = commaIdx >= 0 ? rawType.substring(0, commaIdx) : rawType;
    final lastDot = beforeAsm.lastIndexOf('.');
    if (lastDot >= 0 && lastDot < beforeAsm.length - 1) {
      return beforeAsm.substring(lastDot + 1);
    }
    return beforeAsm;
  }

  String _displayName(Map<String, dynamic> json, String fallback) {
    for (final key in const ['Name', 'TargetName', 'Title']) {
      final v = json[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return fallback;
  }

  CanonicalKind _classify(String shortType, {required bool hasChildren}) {
    // Containers / logic.
    switch (shortType) {
      case 'SequentialContainer':
      case 'Container':
      case 'SimpleContainer':
      case 'TemplatedSequenceContainer':
      case 'StartAreaContainer':
      case 'TargetAreaContainer':
      case 'EndAreaContainer':
      case 'ImagingTargetContainer':
      case 'SequenceRootContainer':
      case 'AreaContainer':
        return CanonicalKind.sequential;
      case 'ParallelContainer':
        return CanonicalKind.parallel;
      case 'LoopContainer':
      case 'WhileContainer':
        return CanonicalKind.loop;
      case 'DeepSkyObjectContainer':
        return CanonicalKind.targetHeader;
    }

    // Instructions.
    switch (shortType) {
      case 'TakeExposure':
      case 'TakeManyExposures':
      case 'TakeSubframeExposure':
        return CanonicalKind.exposure;
      case 'SlewScopeToCoordinates':
      case 'SlewScopeToRaDec':
      case 'SlewTelescopeToCoordinates':
        return CanonicalKind.slew;
      case 'Center':
      case 'CenterAfterDrift':
      case 'SlewAndCenter':
      case 'CenterAndRotate':
        return CanonicalKind.center;
      case 'RunAutofocus':
      case 'Autofocus':
      case 'AutoFocus':
        return CanonicalKind.autofocus;
      case 'SwitchFilter':
      case 'ChangeFilter':
        return CanonicalKind.filterChange;
      case 'WaitForTime':
      case 'WaitUntilTime':
      case 'WaitForAltitude':
        return CanonicalKind.waitForTime;
      // A time SPAN is a duration, not an instant.
      //
      // `WaitForTimeSpan` was grouped with the wait-until-an-instant items, so
      // it mapped to a `WaitTimeNode` whose `waitUntil` comes from a
      // `waitUntilIso` a timespan does not carry. The result was a Wait node
      // with no time set — which the validator correctly calls an error, so
      // every NINA sequence containing one failed to import at all rather than
      // arriving with a working delay. Its sibling `WaitForTimeSpanDelay`
      // was already classified this way.
      case 'WaitForTimeSpan':
      case 'WaitForTimeSpanDelay':
      case 'Delay':
      case 'Wait':
        return CanonicalKind.delay;
      case 'Dither':
      case 'DitherAfterExposures':
      case 'DitherAfter':
        return CanonicalKind.dither;
      case 'StartGuiding':
      case 'StartPHD2Guiding':
        return CanonicalKind.startGuiding;
      case 'StopGuiding':
      case 'StopPHD2Guiding':
        return CanonicalKind.stopGuiding;
      case 'MeridianFlip':
      case 'MeridianFlipTrigger':
        return CanonicalKind.meridianFlip;
      case 'ParkScope':
      case 'ParkMount':
      case 'Park':
        return CanonicalKind.park;
      case 'UnparkScope':
      case 'UnparkMount':
      case 'Unpark':
        return CanonicalKind.unpark;
      case 'CoolCamera':
      case 'CoolDownCamera':
        return CanonicalKind.coolCamera;
      case 'WarmCamera':
      case 'WarmUpCamera':
        return CanonicalKind.warmCamera;
      case 'MoveRotator':
      case 'RotateMechanical':
      case 'Solve':
        return CanonicalKind.rotator;
      case 'Annotation':
      case 'Comment':
      case 'Note':
        return CanonicalKind.annotation;
    }

    // Some container-ish types we don't explicitly know about but which carry
    // children we still want to walk.
    if (hasChildren) return CanonicalKind.sequential;
    return CanonicalKind.unsupported;
  }

  Map<String, Object?> _extractAttributes(
    Map<String, dynamic> json,
    CanonicalKind kind,
  ) {
    final out = <String, Object?>{};
    switch (kind) {
      case CanonicalKind.exposure:
        out['exposureTime'] = _readDouble(
          json['ExposureTime'] ?? json['Duration'],
        );
        // NINA encodes exposure count via wrapping `LoopContainer` /
        // `TakeManyExposures` -> `TotalExposureCount`. Fall back to 1.
        out['count'] = _readInt(
          json['TotalExposureCount'] ?? json['Count'] ?? json['Iterations'],
        );
        out['gain'] = _readInt(json['Gain']);
        out['offset'] = _readInt(json['Offset']);
        out['binning'] = _extractBinning(json['Binning']);
        out['filterName'] = _extractFilter(json['Filter']);
        out['imageType'] =
            json['ImageType']?.toString() ??
            json['FrameType']?.toString() ??
            'LIGHT';
        break;
      case CanonicalKind.slew:
      case CanonicalKind.center:
        // NINA stores coordinates as either `Coordinates` (composite) or
        // separate `RAHours`/`Dec` fields.
        final coord = json['Coordinates'];
        if (coord is Map<String, dynamic>) {
          out['raHours'] = _readDouble(coord['RA'] ?? coord['RAHours']);
          out['decDegrees'] = _readDouble(coord['Dec'] ?? coord['Declination']);
        }
        out['raHours'] ??= _readDouble(json['RAHours'] ?? json['RA']);
        out['decDegrees'] ??= _readDouble(
          json['Dec'] ?? json['DEC'] ?? json['Declination'],
        );
        break;
      case CanonicalKind.autofocus:
        // Nothing useful to copy from NINA — autofocus is parameterless on
        // their side (everything comes from the profile).
        break;
      case CanonicalKind.filterChange:
        out['filterName'] = _extractFilter(json['Filter']);
        out['filterPosition'] = _readInt(json['Position']);
        break;
      case CanonicalKind.waitForTime:
        out['waitUntilIso'] =
            json['WaitUntil']?.toString() ?? json['DateTime']?.toString();
        break;
      case CanonicalKind.delay:
        out['seconds'] = _readDouble(json['Seconds'] ?? json['Duration']);
        break;
      case CanonicalKind.dither:
        out['pixels'] = _readDouble(json['Pixels'] ?? json['DitherPixels']);
        break;
      case CanonicalKind.meridianFlip:
        out['minutesPastMeridian'] = _readDouble(
          json['MinutesAfterMeridian'] ?? json['PauseTimeBeforeMeridian'],
        );
        break;
      case CanonicalKind.coolCamera:
        out['targetTemperature'] = _readDouble(
          json['Temperature'] ?? json['TargetTemperature'],
        );
        out['durationMinutes'] = _readDouble(json['Duration']);
        break;
      case CanonicalKind.warmCamera:
        out['durationMinutes'] = _readDouble(json['Duration']);
        break;
      case CanonicalKind.rotator:
        out['angle'] = _readDouble(
          json['MechanicalPosition'] ?? json['PositionAngle'] ?? json['Angle'],
        );
        break;
      case CanonicalKind.loop:
        out['iterations'] = _readInt(
          json['Iterations'] ?? json['Count'] ?? json['TotalExposureCount'],
        );
        break;
      case CanonicalKind.targetHeader:
        final target = json['Target'];
        if (target is Map<String, dynamic>) {
          out['targetName'] =
              target['TargetName']?.toString() ??
              target['Name']?.toString() ??
              json['Name']?.toString();
          final coord = target['InputCoordinates'] ?? target['Coordinates'];
          if (coord is Map<String, dynamic>) {
            out['raHours'] = _readDouble(coord['RAHours'] ?? coord['RA']);
            out['decDegrees'] = _readDouble(
              coord['NegativeDec'] == true
                  ? -(_readDouble(coord['Dec'] ?? coord['Declination']) ?? 0)
                  : (coord['Dec'] ?? coord['Declination']),
            );
          }
          out['rotation'] = _readDouble(
            target['Rotation'] ?? target['PositionAngle'],
          );
        }
        // Also accept flat fields directly on the container.
        out['targetName'] ??=
            json['TargetName']?.toString() ?? json['Name']?.toString();
        break;
      case CanonicalKind.sequential:
      case CanonicalKind.parallel:
      case CanonicalKind.annotation:
      case CanonicalKind.startGuiding:
      case CanonicalKind.stopGuiding:
      case CanonicalKind.park:
      case CanonicalKind.unpark:
        break;
      case CanonicalKind.unsupported:
        // For unrecognized node types (e.g. LoopCondition, CountCondition,
        // TimeCondition), preserve scalar JSON fields verbatim so downstream
        // condition-folding (_foldConditions) can read the original values
        // like `Iterations` / `Count` / `DateTime` / `Altitude` / `Offset`.
        for (final entry in json.entries) {
          final v = entry.value;
          if (v is num || v is bool || v is String) {
            out[entry.key] = v;
          }
        }
        break;
    }
    return out;
  }

  String? _extractFilter(Object? raw) {
    if (raw == null) return null;
    if (raw is String) return raw.isEmpty ? null : raw;
    if (raw is Map<String, dynamic>) {
      final name = raw['Name'] ?? raw['_name'] ?? raw['FilterName'];
      if (name is String && name.isNotEmpty) return name;
      final pos = raw['Position'];
      if (pos is num) return 'Position $pos';
    }
    return null;
  }

  int? _extractBinning(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.toInt();
    if (raw is Map<String, dynamic>) {
      final x = raw['X'] ?? raw['BinX'] ?? raw['Horizontal'];
      if (x is num) return x.toInt();
    }
    if (raw is String) {
      final m = RegExp(r'(\d+)').firstMatch(raw);
      if (m != null) return int.tryParse(m.group(1)!);
    }
    return null;
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
