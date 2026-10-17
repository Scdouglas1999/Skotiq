import 'package:uuid/uuid.dart';

import '../../models/imaging/imaging_models.dart' show FrameType;
import '../../models/import/canonical_sequence_node.dart';
import '../../models/import/import_result.dart';
import '../../models/sequence/sequence_models.dart';
import '../../providers/sequence/sequence_validation.dart';

/// Outcome of mapping one canonical tree to Skotiq nodes.
///
/// The mapper does not throw on encountering unsupported nodes — instead it
/// records them so the caller can decide whether to abort or force-import.
class MapResult {
  final Sequence sequence;
  final List<MappingTableRow> mappingTable;
  final List<DroppedNodeRecord> dropped;
  final List<UnsupportedNodeRecord> unsupported;
  final int totalNodes;

  /// Issues discovered while mapping that the unified structural validator
  /// can't see because the signal lives in the *source* tree rather than the
  /// assembled [Sequence]. Currently this carries the indeterminate-frame-
  /// count warning (see [CanonicalNodeMapper._mapNode]): a `TakeExposure`
  /// with no count of its own nested under a container that iterates an
  /// unknowable number of times (loop-forever / loop-until-time /
  /// loop-until-altitude). Such an exposure silently maps to a single frame,
  /// so we surface a warning the importer folds into
  /// [ImportResult.validationIssues].
  final List<ValidationIssue> validationIssues;

  MapResult({
    required this.sequence,
    required this.mappingTable,
    required this.dropped,
    required this.unsupported,
    required this.totalNodes,
    this.validationIssues = const [],
  });
}

/// Translates a [CanonicalSequenceNode] tree into Skotiq's
/// `SequenceNode` model.
///
/// In `forceUnsupported = false` mode an unsupported node is recorded in
/// [MapResult.unsupported]. The caller (the importer service) is responsible
/// for either:
///   - aborting with [UnsupportedNodeError] (strict mode), or
///   - logging the offender as dropped and continuing (force mode).
class CanonicalNodeMapper {
  static const _uuid = Uuid();

  /// Map [root] to a Skotiq [Sequence]. [sequenceName] is the name we
  /// stamp on the produced sequence. [forceUnsupported] controls whether
  /// unsupported source nodes are dropped (`true`) or left in
  /// `result.unsupported` for the caller to abort on.
  MapResult map(
    CanonicalSequenceNode root, {
    required String sequenceName,
    required bool forceUnsupported,
  }) {
    final nodes = <String, SequenceNode>{};
    final dropped = <DroppedNodeRecord>[];
    final unsupported = <UnsupportedNodeRecord>[];
    final mappingCounts = <String, _MappingCount>{};
    final validationIssues = <ValidationIssue>[];

    int totalNodes = 0;
    for (final _ in root.walk()) {
      totalNodes++;
    }

    final rootId = _mapNode(
      root,
      parentId: null,
      orderIndex: 0,
      out: nodes,
      dropped: dropped,
      unsupported: unsupported,
      mapping: mappingCounts,
      issues: validationIssues,
      forceUnsupported: forceUnsupported,
      insideIndeterminateLoop: false,
    );

    final sequence = Sequence.create(
      id: _uuid.v4(),
      name: sequenceName,
      description: 'Imported from ${root.sourceType}',
      nodes: nodes,
      rootNodeId: rootId,
    );

    final mappingTable =
        mappingCounts.values
            .map(
              (m) => MappingTableRow(
                sourceType: m.sourceType,
                skotiqType: m.skotiqType,
                count: m.count,
              ),
            )
            .toList()
          ..sort((a, b) => a.sourceType.compareTo(b.sourceType));

    return MapResult(
      sequence: sequence,
      mappingTable: mappingTable,
      dropped: dropped,
      unsupported: unsupported,
      totalNodes: totalNodes,
      validationIssues: validationIssues,
    );
  }

  /// Returns the id of the newly-created node, or `null` when the node is
  /// dropped. Children of a dropped node are still walked (so the totals
  /// account for them) but attach to the dropped node's parent.
  ///
  /// [insideIndeterminateLoop] is `true` when any ancestor of [node] is a
  /// container that iterates an unknowable number of times (loop-forever /
  /// loop-until-time / loop-until-altitude). When such a container wraps a
  /// `TakeExposure` that carries no count of its own, no frame count can be
  /// propagated down and the exposure maps to a single frame — almost never
  /// what the source author meant, so that case emits a warning into
  /// [issues].
  String? _mapNode(
    CanonicalSequenceNode node, {
    required String? parentId,
    required int orderIndex,
    required Map<String, SequenceNode> out,
    required List<DroppedNodeRecord> dropped,
    required List<UnsupportedNodeRecord> unsupported,
    required Map<String, _MappingCount> mapping,
    required List<ValidationIssue> issues,
    required bool forceUnsupported,
    required bool insideIndeterminateLoop,
  }) {
    final isDisabled = node.attributes['_disabled'] == true;
    if (isDisabled) {
      dropped.add(
        DroppedNodeRecord(
          sourceType: node.sourceType,
          name: node.name,
          reason: DropReason.disabled,
        ),
      );
      _bumpMapping(mapping, node.sourceType, null);
      // Walk children so we count them in totals; they get attached to parent.
      _mapChildren(
        node.children,
        parentId,
        out,
        dropped,
        unsupported,
        mapping,
        issues,
        forceUnsupported,
        insideIndeterminateLoop,
      );
      return null;
    }

    if (node.kind == CanonicalKind.annotation) {
      dropped.add(
        DroppedNodeRecord(
          sourceType: node.sourceType,
          name: node.name,
          reason: DropReason.decorative,
        ),
      );
      _bumpMapping(mapping, node.sourceType, null);
      return null;
    }

    if (node.kind == CanonicalKind.unsupported) {
      final record = UnsupportedNodeRecord(
        sourceType: node.sourceType,
        name: node.name,
        reason: 'No Skotiq equivalent for "${node.sourceType}"',
      );
      unsupported.add(record);
      if (forceUnsupported) {
        dropped.add(
          DroppedNodeRecord(
            sourceType: node.sourceType,
            name: node.name,
            reason: DropReason.unsupported,
          ),
        );
      }
      _bumpMapping(mapping, node.sourceType, null);
      return null;
    }

    final id = _uuid.v4();
    final mapped = _construct(
      node,
      id: id,
      parentId: parentId,
      orderIndex: orderIndex,
    );

    // Indeterminate-frame-count warning. A `TakeExposure` with no count of its
    // own, nested anywhere under a container that iterates an unknowable number
    // of times, maps to a single frame. The parser only propagates a count when
    // the loop's iteration total is resolvable; an unbounded loop leaves the
    // exposure untouched, so flag it here while we still know the source shape.
    if (insideIndeterminateLoop &&
        node.kind == CanonicalKind.exposure &&
        node.attributes['count'] == null &&
        mapped != null) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.exposures,
          title: 'Frame count could not be determined',
          description:
              'The exposure "${node.name}" sits inside a loop that repeats an '
              'unknowable number of times (loop forever / until a time or '
              'altitude) and carries no count of its own, so it was imported '
              'as a single frame.',
          resolutionHint:
              'Set an explicit frame count on this exposure, or give the '
              'enclosing loop a fixed iteration count, so the planned number '
              'of frames is unambiguous.',
          affectedNodeId: id,
          code: 'import_indeterminate_exposure_count',
        ),
      );
    }
    if (mapped == null) {
      // _construct only returns null for unsupported instruction kinds we
      // discover late (rare; logic kinds are guarded above).
      final record = UnsupportedNodeRecord(
        sourceType: node.sourceType,
        name: node.name,
        reason: 'Failed to map "${node.sourceType}" to a Skotiq node',
      );
      unsupported.add(record);
      if (forceUnsupported) {
        dropped.add(
          DroppedNodeRecord(
            sourceType: node.sourceType,
            name: node.name,
            reason: DropReason.unsupported,
          ),
        );
      }
      _bumpMapping(mapping, node.sourceType, null);
      return null;
    }

    final childInsideIndeterminateLoop =
        insideIndeterminateLoop || _isIndeterminateLoop(node);
    final childIds = <String>[];
    var nextOrder = 0;
    for (final child in node.children) {
      final childId = _mapNode(
        child,
        parentId: id,
        orderIndex: nextOrder,
        out: out,
        dropped: dropped,
        unsupported: unsupported,
        mapping: mapping,
        issues: issues,
        forceUnsupported: forceUnsupported,
        insideIndeterminateLoop: childInsideIndeterminateLoop,
      );
      if (childId != null) {
        childIds.add(childId);
        nextOrder++;
      }
    }

    final withChildren = _withChildIds(mapped, childIds);
    out[id] = withChildren;
    _bumpMapping(mapping, node.sourceType, withChildren.nodeType);
    return id;
  }

  void _mapChildren(
    List<CanonicalSequenceNode> children,
    String? parentId,
    Map<String, SequenceNode> out,
    List<DroppedNodeRecord> dropped,
    List<UnsupportedNodeRecord> unsupported,
    Map<String, _MappingCount> mapping,
    List<ValidationIssue> issues,
    bool forceUnsupported,
    bool insideIndeterminateLoop,
  ) {
    var nextOrder = 0;
    for (final child in children) {
      final id = _mapNode(
        child,
        parentId: parentId,
        orderIndex: nextOrder,
        out: out,
        dropped: dropped,
        unsupported: unsupported,
        mapping: mapping,
        issues: issues,
        forceUnsupported: forceUnsupported,
        insideIndeterminateLoop: insideIndeterminateLoop,
      );
      if (id != null) nextOrder++;
    }
  }

  /// True when [node] is a container that iterates an unknowable number of
  /// times — loop-forever, loop-until-time, or loop-until-altitude — so a
  /// frame count cannot be derived from the iteration total. A loop with a
  /// fixed `iterations` (or count condition) is determinate and returns false;
  /// in that case the parser has already stamped the resolved count onto the
  /// direct-child exposures.
  bool _isIndeterminateLoop(CanonicalSequenceNode node) {
    final a = node.attributes;
    final isIterating =
        node.kind == CanonicalKind.loop ||
        a['iterations'] != null ||
        a['_loopCountFromCondition'] != null ||
        a['_loopForever'] == true ||
        a['_loopUntilTime'] != null ||
        a['_loopUntilAltitude'] != null;
    if (!isIterating) return false;
    final resolvedCount =
        _readInt(a['iterations']) ?? _readInt(a['_loopCountFromCondition']);
    // A fixed iteration total (including a single iteration) is determinate.
    // Only loops with no resolvable count — forever / until-time /
    // until-altitude — leave the child exposure's frame count unknowable.
    return resolvedCount == null;
  }

  SequenceNode? _construct(
    CanonicalSequenceNode node, {
    required String id,
    required String? parentId,
    required int orderIndex,
  }) {
    final a = node.attributes;
    switch (node.kind) {
      case CanonicalKind.sequential:
        return InstructionSetNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
        );
      case CanonicalKind.parallel:
        return ParallelNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
        );
      case CanonicalKind.loop:
        final iterations =
            _readInt(a['iterations']) ?? _readInt(a['_loopCountFromCondition']);
        final untilIso = a['_loopUntilTime'];
        final foreverFlag = a['_loopForever'] == true;
        if (foreverFlag) {
          return LoopNode(
            id: id,
            name: node.name,
            parentId: parentId,
            orderIndex: orderIndex,
            conditionType: LoopConditionType.forever,
          );
        }
        if (untilIso is String && untilIso.isNotEmpty) {
          final dt = DateTime.tryParse(untilIso);
          if (dt != null) {
            return LoopNode(
              id: id,
              name: node.name,
              parentId: parentId,
              orderIndex: orderIndex,
              conditionType: LoopConditionType.untilTime,
              repeatUntil: dt,
              repeatCount: null,
            );
          }
        }
        return LoopNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          conditionType: LoopConditionType.count,
          repeatCount: iterations ?? 1,
        );
      case CanonicalKind.targetHeader:
        final targetName = a['targetName']?.toString() ?? node.name;
        final raHours = _readDouble(a['raHours']) ?? 0;
        final decDegrees = _readDouble(a['decDegrees']) ?? 0;
        final rotation = _readDouble(a['rotation']);
        // Telescopius mosaic panes (and similar formats) tag rows with
        // mosaic group + panel metadata; surface it as MosaicPanelInfo so
        // the rest of the app treats these as real mosaic panels (badge,
        // mosaic-group dashboard, resume).
        MosaicPanelInfo? mosaicPanel;
        final mosaicName = a['mosaicName']?.toString();
        final panelIndex = _readInt(a['mosaicPanelIndex']);
        final totalPanels = _readInt(a['mosaicTotalPanels']);
        if (mosaicName != null &&
            panelIndex != null &&
            totalPanels != null &&
            totalPanels > 0) {
          mosaicPanel = MosaicPanelInfo(
            mosaicName: mosaicName,
            panelIndex: panelIndex,
            totalPanels: totalPanels,
            row: _readInt(a['mosaicRow']) ?? 0,
            column: _readInt(a['mosaicColumn']) ?? panelIndex,
          );
        }
        return TargetHeaderNode(
          id: id,
          name: targetName,
          parentId: parentId,
          orderIndex: orderIndex,
          targetName: targetName,
          raHours: raHours,
          decDegrees: decDegrees,
          rotation: rotation,
          mosaicPanel: mosaicPanel,
        );
      case CanonicalKind.exposure:
        final duration = _readDouble(a['exposureTime']) ?? 60.0;
        final count = _readInt(a['count']) ?? 1;
        final filter = a['filterName']?.toString();
        final gain = _readInt(a['gain']);
        final offset = _readInt(a['offset']);
        final binning = _mapBinning(_readInt(a['binning']));
        final frameType = _mapFrameType(a['imageType']?.toString());
        return ExposureNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          durationSecs: duration,
          count: count,
          frameType: frameType,
          filter: filter,
          gain: gain,
          offset: offset,
          binning: binning,
        );
      case CanonicalKind.slew:
        final ra = _readDouble(a['raHours']);
        final dec = _readDouble(a['decDegrees']);
        return SlewNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          useTargetCoords: ra == null || dec == null,
          customRa: ra,
          customDec: dec,
        );
      case CanonicalKind.center:
        final ra = _readDouble(a['raHours']);
        final dec = _readDouble(a['decDegrees']);
        return CenterNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          useTargetCoords: ra == null || dec == null,
          customRa: ra,
          customDec: dec,
        );
      case CanonicalKind.autofocus:
        return AutofocusNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
        );
      case CanonicalKind.filterChange:
        final name = a['filterName']?.toString();
        if (name == null || name.isEmpty) {
          // A filter-change with no filter name is meaningless; surface as
          // unsupported (mapper caller decides what to do).
          return null;
        }
        return FilterChangeNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          filterName: name,
          filterPosition: _readInt(a['filterPosition']),
        );
      case CanonicalKind.waitForTime:
        final iso = a['waitUntilIso'];
        DateTime? until;
        if (iso is String && iso.isNotEmpty) {
          until = DateTime.tryParse(iso);
        }
        return WaitTimeNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          waitUntil: until,
        );
      case CanonicalKind.delay:
        return DelayNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          seconds: _readDouble(a['seconds']) ?? 5.0,
        );
      case CanonicalKind.dither:
        return DitherNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          pixels: _readDouble(a['pixels']) ?? 5.0,
        );
      case CanonicalKind.startGuiding:
        return StartGuidingNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
        );
      case CanonicalKind.stopGuiding:
        return StopGuidingNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
        );
      case CanonicalKind.meridianFlip:
        return MeridianFlipNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          minutesPastMeridian: _readDouble(a['minutesPastMeridian']) ?? 5.0,
          // Imported sequences (e.g. NINA) ship explicit per-node values, so
          // they are honoured rather than overlaid with Sequencer Settings.
          // Users can opt into globals later via the node panel.
          useGlobalDefaults: false,
        );
      case CanonicalKind.park:
        return ParkNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
        );
      case CanonicalKind.unpark:
        return UnparkNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
        );
      case CanonicalKind.coolCamera:
        return CoolCameraNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          targetTemp: _readDouble(a['targetTemperature']) ?? -10.0,
          durationMins: _readDouble(a['durationMinutes']) ?? 10.0,
        );
      case CanonicalKind.warmCamera:
        // SGP/NINA warm has a duration in minutes; we model as rate/min.
        final dur = _readDouble(a['durationMinutes']);
        final rate = (dur != null && dur > 0) ? (30.0 / dur) : 2.0;
        return WarmCameraNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          ratePerMin: rate,
        );
      case CanonicalKind.rotator:
        return RotatorNode(
          id: id,
          name: node.name,
          parentId: parentId,
          orderIndex: orderIndex,
          targetAngle: _readDouble(a['angle']) ?? 0.0,
        );
      case CanonicalKind.annotation:
      case CanonicalKind.unsupported:
        return null;
    }
  }

  /// Build a new node identical to [base] but with [childIds] swapped in.
  /// We have to do this through the per-subclass `copyWith` because the base
  /// class is abstract.
  SequenceNode _withChildIds(SequenceNode base, List<String> childIds) {
    if (childIds.isEmpty) return base;
    return base.copyWith(childIds: childIds);
  }

  void _bumpMapping(Map<String, _MappingCount> table, String src, String? dst) {
    final key = '$src->${dst ?? '<dropped>'}';
    final entry =
        table[key] ?? _MappingCount(sourceType: src, skotiqType: dst);
    entry.count++;
    table[key] = entry;
  }

  BinningMode _mapBinning(int? bin) {
    switch (bin) {
      case 2:
        return BinningMode.two;
      case 3:
        return BinningMode.three;
      case 4:
        return BinningMode.four;
      default:
        return BinningMode.one;
    }
  }

  FrameType _mapFrameType(String? imageType) {
    if (imageType == null) return FrameType.light;
    final t = imageType.trim().toLowerCase();
    if (t.contains('dark')) {
      if (t.contains('flat')) return FrameType.darkFlat;
      return FrameType.dark;
    }
    if (t.contains('flat')) return FrameType.flat;
    if (t.contains('bias')) return FrameType.bias;
    if (t.contains('snap')) return FrameType.snapshot;
    return FrameType.light;
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
}

class _MappingCount {
  final String sourceType;
  final String? skotiqType;
  int count = 0;
  _MappingCount({required this.sourceType, required this.skotiqType});
}
