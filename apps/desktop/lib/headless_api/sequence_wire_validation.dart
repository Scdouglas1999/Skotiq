/// Blocking pre-flight validation for the NATIVE sequence wire JSON.
///
/// Why this exists at all, given `SequenceValidatorService` in
/// `skotiq_core`: the headless appliance's canonical run flow is
/// `POST /api/sequencer/load` -> `POST /api/sequencer/start`, and neither call
/// ever builds a Dart [Sequence]. `load` hands the caller's raw JSON straight
/// to `sequencerLoadJson` and the bare `start` branch calls
/// `backend.sequencerStart()` directly, so without this pass the whole Dart
/// validator stack — `TargetCoordinatesUnsetRule` included — is skipped for
/// exactly the rig nobody is standing next to. A target left on the RA 0h /
/// Dec +0° sentinel then slews an unattended remote mount into Pisces and
/// files every frame under its default name.
///
/// Validating the wire artifact rather than a reconstructed Dart model is
/// deliberate: this string is precisely the tree the Rust executor will run,
/// so there is no serialization gap between what is checked and what executes.
///
/// The rules mirror the Dart ones they stand in for (see
/// `sequence_validation.dart` `TargetCoordinatesUnsetRule` and
/// `rules/target_rules.dart` `TargetCoordinatesRule` / `SlewCoordinatesRule`)
/// including their severity split: an unset target that nothing enabled
/// consumes is a warning, not a block, so an unrelated run is not held hostage
/// by a half-built target.
library;

import 'dart:convert';

/// Wire `node_type.type` values that own a child list. Anything else is a leaf
/// instruction — the distinction decides whether a target's coordinates are
/// actually consumed on this run. `InstructionSet` is absent because the
/// serializer emits it as a `Loop`.
const _containerWireTypes = <String>{
  'TargetHeader',
  'Loop',
  'Parallel',
  'Conditional',
  'Recovery',
  'TargetScheduler',
};

/// Wire types that can inherit their pointing from a TargetHeader.
const _pointingWireTypes = <String>{'SlewToTarget', 'CenterTarget'};

enum WireIssueSeverity { error, warning }

/// One finding against a wire sequence. Serializes into the same body shape as
/// `SequenceValidationException.toJsonBody`'s `issues` entries so a remote
/// dashboard renders headless rejections with the pre-flight panel it already
/// has for desktop-initiated starts.
class SequenceWireIssue {
  final WireIssueSeverity severity;
  final String title;
  final String description;
  final String code;
  final String? affectedNodeId;
  final String? resolutionHint;

  const SequenceWireIssue({
    required this.severity,
    required this.title,
    required this.description,
    required this.code,
    this.affectedNodeId,
    this.resolutionHint,
  });

  bool get isError => severity == WireIssueSeverity.error;

  Map<String, Object?> toJson() => {
    'severity': severity.name,
    'category': 'targets',
    'title': title,
    'description': description,
    'code': code,
    if (affectedNodeId != null) 'affectedNodeId': affectedNodeId,
    if (resolutionHint != null) 'resolutionHint': resolutionHint,
  };
}

/// The 400 body for a rejected sequence. Shape-compatible with
/// `SequenceValidationException.toJsonBody()` so both start paths answer alike.
Map<String, Object?> sequenceWireValidationBody(
  List<SequenceWireIssue> issues,
) {
  final errors = issues.where((i) => i.isError).toList(growable: false);
  return {
    'error': 'sequence_validation_failed',
    'code': 'sequence_validation_failed',
    'message':
        'Cannot run sequence: ${errors.length} validation '
        '${errors.length == 1 ? 'error' : 'errors'}: '
        '${errors.map((e) => e.title).join('; ')}',
    'errorCount': errors.length,
    'warningCount': issues.length - errors.length,
    'issues': issues.map((i) => i.toJson()).toList(growable: false),
  };
}

class _WireNode {
  final String id;
  final String name;
  final String type;
  final Map<String, Object?> config;
  final bool enabled;
  final List<String> children;

  _WireNode({
    required this.id,
    required this.name,
    required this.type,
    required this.config,
    required this.enabled,
    required this.children,
  });
}

/// Validate the serialized `SequenceDefinition` in [json].
///
/// Returns every finding, errors and warnings alike; callers block on
/// `any((i) => i.isError)`. Never throws — a payload this function cannot even
/// parse comes back as a single structural error, because a sequence the host
/// cannot read is a sequence the host must not run.
List<SequenceWireIssue> validateSequenceWireJson(String json) {
  final issues = <SequenceWireIssue>[];

  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException catch (e) {
    return [
      SequenceWireIssue(
        severity: WireIssueSeverity.error,
        title: 'Sequence Is Not Valid JSON',
        description: 'The sequence payload could not be parsed: ${e.message}',
        code: 'sequence_wire_malformed',
        resolutionHint:
            'Send the sequence as the JSON the desktop editor serializes.',
      ),
    ];
  }
  if (decoded is! Map<String, Object?>) {
    return [
      SequenceWireIssue(
        severity: WireIssueSeverity.error,
        title: 'Sequence Is Not an Object',
        description:
            'The sequence payload decoded to ${decoded.runtimeType}, not a '
            'JSON object with `nodes` and `root_node_id`.',
        code: 'sequence_wire_malformed',
      ),
    ];
  }

  final rawNodes = decoded['nodes'];
  if (rawNodes is! List) {
    return [
      SequenceWireIssue(
        severity: WireIssueSeverity.error,
        title: 'Sequence Has No Nodes',
        description:
            'The sequence payload carries no `nodes` array, so there is '
            'nothing to execute.',
        code: 'sequence_wire_malformed',
      ),
    ];
  }

  final nodes = <String, _WireNode>{};
  for (final raw in rawNodes) {
    if (raw is! Map<String, Object?>) {
      issues.add(
        const SequenceWireIssue(
          severity: WireIssueSeverity.error,
          title: 'Malformed Node',
          description: 'A `nodes` entry is not a JSON object.',
          code: 'sequence_wire_malformed',
        ),
      );
      continue;
    }
    final id = raw['id'];
    if (id is! String || id.isEmpty) {
      issues.add(
        const SequenceWireIssue(
          severity: WireIssueSeverity.error,
          title: 'Node Without an Id',
          description:
              'A node carries no `id`. Node ids are the sequence\'s identity: '
              'without one the executor cannot attribute its frames or resume '
              'it from a checkpoint.',
          code: 'sequence_wire_malformed',
        ),
      );
      continue;
    }
    if (nodes.containsKey(id)) {
      // Node id is identity everywhere downstream (checkpoint marking, frame
      // attribution, skip-to-node). Two nodes sharing one is not a cosmetic
      // problem — the executor silently addresses the wrong one.
      issues.add(
        SequenceWireIssue(
          severity: WireIssueSeverity.error,
          title: 'Duplicate Node Id',
          description:
              'More than one node uses the id "$id". Frame attribution, '
              'checkpoint resume and skip-to-node all address nodes by id.',
          code: 'sequence_wire_duplicate_node_id',
          affectedNodeId: id,
        ),
      );
      continue;
    }
    final config = raw['node_type'];
    nodes[id] = _WireNode(
      id: id,
      name: raw['name'] is String ? raw['name'] as String : id,
      type: config is Map<String, Object?> && config['type'] is String
          ? config['type'] as String
          : '',
      config: config is Map<String, Object?> ? config : const {},
      // Rust's serde defaults `enabled` to true when the key is absent, so the
      // host must read an absent key the same way or it would let a node the
      // executor WILL run pass as "disabled and therefore harmless".
      enabled: raw['enabled'] is bool ? raw['enabled'] as bool : true,
      children: raw['children'] is List
          ? (raw['children'] as List).whereType<String>().toList()
          : const <String>[],
    );
  }

  final rootId = decoded['root_node_id'];
  if (rootId is! String || !nodes.containsKey(rootId)) {
    issues.add(
      SequenceWireIssue(
        severity: WireIssueSeverity.error,
        title: 'Sequence Has No Root',
        description: rootId is String
            ? 'The sequence names "$rootId" as its root, but no node has that '
                  'id.'
            : 'The sequence carries no `root_node_id`.',
        code: 'sequence_wire_malformed',
      ),
    );
  }

  final parentOf = <String, String>{};
  for (final node in nodes.values) {
    for (final childId in node.children) {
      if (!nodes.containsKey(childId)) {
        issues.add(
          SequenceWireIssue(
            severity: WireIssueSeverity.error,
            title: 'Dangling Child Reference',
            description:
                'Node "${node.name}" lists a child "$childId" that is not in '
                'the sequence.',
            code: 'sequence_wire_dangling_child',
            affectedNodeId: node.id,
          ),
        );
        continue;
      }
      parentOf.putIfAbsent(childId, () => node.id);
    }
  }

  // True when [node] and every ancestor are enabled — i.e. it is reachable on
  // this run. A disabled container silences its whole subtree.
  bool isLive(_WireNode node) {
    final seen = <String>{};
    _WireNode? cursor = node;
    while (cursor != null && seen.add(cursor.id)) {
      if (!cursor.enabled) return false;
      final parentId = parentOf[cursor.id];
      cursor = parentId == null ? null : nodes[parentId];
    }
    return true;
  }

  bool hasEnabledInstruction(_WireNode parent, [Set<String>? seen]) {
    final visited = seen ?? <String>{parent.id};
    for (final childId in parent.children) {
      final child = nodes[childId];
      if (child == null || !child.enabled) continue;
      if (!visited.add(child.id)) continue;
      if (!_containerWireTypes.contains(child.type)) return true;
      if (hasEnabledInstruction(child, visited)) return true;
    }
    return false;
  }

  final targets = nodes.values
      .where((n) => n.type == 'TargetHeader')
      .toList(growable: false);

  /// The TargetHeader a pointing-inheriting node reads from: the nearest
  /// TargetHeader ancestor, else the first target in the sequence — the same
  /// fallback the Slew editor shows the operator.
  _WireNode? pointingSource(_WireNode node) {
    final seen = <String>{};
    _WireNode? cursor = node;
    while (cursor != null && seen.add(cursor.id)) {
      if (cursor.type == 'TargetHeader') return cursor;
      final parentId = parentOf[cursor.id];
      cursor = parentId == null ? null : nodes[parentId];
    }
    return targets.isEmpty ? null : targets.first;
  }

  bool hasExternalPointingConsumer(_WireNode target) {
    for (final node in nodes.values) {
      if (!_pointingWireTypes.contains(node.type)) continue;
      if (node.config['use_target_coords'] != true) continue;
      if (!isLive(node)) continue;
      if (pointingSource(node)?.id != target.id) continue;
      return true;
    }
    return false;
  }

  double? asDouble(Object? value) => value is num ? value.toDouble() : null;

  for (final target in targets) {
    final name = target.config['target_name'] is String
        ? target.config['target_name'] as String
        : target.name;
    final ra = asDouble(target.config['ra_hours']);
    final dec = asDouble(target.config['dec_degrees']);

    // `!(x >= lo && x < hi)` rather than `x < lo || x >= hi` so a NaN — which
    // compares false against every bound — is rejected instead of sailing
    // through both range tests.
    if (ra == null || !(ra >= 0 && ra < 24)) {
      issues.add(
        SequenceWireIssue(
          severity: WireIssueSeverity.error,
          title: 'Invalid RA',
          description: 'Target "$name" has invalid RA: ${ra ?? 'missing'}h',
          code: 'target_coordinates_invalid',
          affectedNodeId: target.id,
          resolutionHint: 'RA must be between 0 and 24 hours.',
        ),
      );
    }
    if (dec == null || !(dec >= -90 && dec <= 90)) {
      issues.add(
        SequenceWireIssue(
          severity: WireIssueSeverity.error,
          title: 'Invalid Dec',
          description: 'Target "$name" has invalid Dec: ${dec ?? 'missing'}°',
          code: 'target_coordinates_invalid',
          affectedNodeId: target.id,
          resolutionHint: 'Declination must be between -90 and +90 degrees.',
        ),
      );
    }
    if (ra != 0 || dec != 0) continue;

    // Block only when the placeholder actually reaches hardware or frame
    // metadata on this run; otherwise warn, exactly as the Dart rule does.
    final consumed =
        isLive(target) &&
        (hasEnabledInstruction(target) || hasExternalPointingConsumer(target));
    issues.add(
      SequenceWireIssue(
        severity: consumed
            ? WireIssueSeverity.error
            : WireIssueSeverity.warning,
        title: 'Target Coordinates Not Set',
        description: consumed
            ? 'Target "$name" is still at the RA 0h / Dec +0° placeholder. '
                  'Running this sequence would point the mount at that spot in '
                  'Pisces and record every frame under it as "$name".'
            : 'Target "$name" is still at the RA 0h / Dec +0° placeholder. '
                  'Nothing enabled under it points there yet, so the run is '
                  'not affected — but the target does not know where it is.',
        code: 'target_coordinates_unset',
        affectedNodeId: target.id,
        resolutionHint:
            'Set "$name"\'s RA/Dec before sending the sequence to the rig.',
      ),
    );
  }

  // A SmartExposure plan may bind a DepthLock goal, and the binding is what
  // decides whether the plan can end early. Rust's `FilterPlan::depth_goal` is
  // `#[serde(default)]`, so a malformed binding does not fail the parse — it
  // silently deserializes to "unbound" and the plan runs its full frame count
  // with nobody told the goal was dropped. Check it here, where the host can
  // still refuse the run and say which plan is wrong.
  for (final node in nodes.values) {
    if (node.type != 'SmartExposure') continue;
    final plans = node.config['plans'];
    if (plans is! List) continue;
    for (var index = 0; index < plans.length; index++) {
      final plan = plans[index];
      if (plan is! Map<String, Object?>) continue;
      final binding = plan['depth_goal'];
      if (binding == null) continue;
      final filterName = plan['filter_name'] is String
          ? plan['filter_name'] as String
          : 'plan ${index + 1}';
      if (binding is! Map<String, Object?>) {
        issues.add(
          SequenceWireIssue(
            severity: WireIssueSeverity.error,
            title: 'Invalid Depth Goal Binding',
            description:
                'Smart Exposure "${node.name}" binds $filterName to a '
                '`depth_goal` that is not an object.',
            code: 'depth_goal_binding_invalid',
            affectedNodeId: node.id,
            resolutionHint:
                'A depth goal binding is {"goal_id": "<id>", "revision": <n>}.',
          ),
        );
        continue;
      }
      final goalId = binding['goal_id'];
      if (goalId is! String || goalId.isEmpty) {
        issues.add(
          SequenceWireIssue(
            severity: WireIssueSeverity.error,
            title: 'Depth Goal Without an Id',
            description:
                'Smart Exposure "${node.name}" binds $filterName to a depth '
                'goal with no `goal_id`, so the executor cannot find the goal '
                'the plan is supposed to stop on.',
            code: 'depth_goal_binding_invalid',
            affectedNodeId: node.id,
            resolutionHint: '`goal_id` must be a non-empty string.',
          ),
        );
      }
      final revision = binding['revision'];
      if (revision is! int || revision < 0) {
        issues.add(
          SequenceWireIssue(
            severity: WireIssueSeverity.error,
            title: 'Invalid Depth Goal Revision',
            description:
                'Smart Exposure "${node.name}" binds $filterName to depth goal '
                'revision ${revision ?? 'missing'}. The revision is how the '
                'executor tells the goal it was bound to from one that has '
                'since been redefined.',
            code: 'depth_goal_binding_invalid',
            affectedNodeId: node.id,
            resolutionHint: '`revision` must be a non-negative integer.',
          ),
        );
      }
    }
  }

  for (final node in nodes.values) {
    if (!_pointingWireTypes.contains(node.type)) continue;
    if (node.config['use_target_coords'] == true) continue;
    // A detached Slew/Center that neither inherits a target nor carries its own
    // coordinates aims at whatever the mount happens to be doing.
    final ra = asDouble(node.config['custom_ra']);
    final dec = asDouble(node.config['custom_dec']);
    if (ra != null && !(ra >= 0 && ra < 24)) {
      issues.add(
        SequenceWireIssue(
          severity: WireIssueSeverity.error,
          title: 'Invalid Slew RA',
          description: 'Slew "${node.name}" has invalid RA: ${ra}h',
          code: 'slew_coordinates_invalid',
          affectedNodeId: node.id,
          resolutionHint: 'RA must be between 0 and 24 hours.',
        ),
      );
    }
    if (dec != null && !(dec >= -90 && dec <= 90)) {
      issues.add(
        SequenceWireIssue(
          severity: WireIssueSeverity.error,
          title: 'Invalid Slew Dec',
          description: 'Slew "${node.name}" has invalid Dec: $dec°',
          code: 'slew_coordinates_invalid',
          affectedNodeId: node.id,
          resolutionHint: 'Declination must be between -90 and +90 degrees.',
        ),
      );
    }
  }

  return issues;
}
