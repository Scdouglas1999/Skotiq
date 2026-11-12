part of '../sequencer_handlers.dart';

/// The little that the headless start path needs to know about the sequence
/// the native executor is holding.
///
/// The native executor takes the wire JSON and exposes no way to ask it back
/// for a name or a target, so this is parsed once at load and kept. Fields
/// mirror `_startSessionRow` in `SequenceExecutor` one for one; the point of
/// the mirror is that a headless run and an editor run open the same shape of
/// `imaging_sessions` row, so everything that reads that table afterwards —
/// image library, session review, analytics, the grader — cannot tell which
/// path started the night.
class _WireSequenceSummary {
  final String name;

  /// Set only when the sequence has exactly one `TargetHeader`, matching
  /// `_startSessionRow`: a multi-target session has no single pointing to
  /// record, and picking the first would label the row with a target the run
  /// may never reach.
  final double? singleTargetRaHours;
  final double? singleTargetDecDegrees;

  /// Planned frame count, loop multipliers applied — the denominator the
  /// session progress bar divides by.
  final int totalExposures;

  /// Hardware roles this sequence needs that the NATIVE pre-flight cannot
  /// check, keyed by role, valued by the node that asks for it.
  ///
  /// `sequencerSetDevices` carries five ids — camera, mount, focuser, filter
  /// wheel, rotator — so `collect_required_devices` in the Rust executor can
  /// refuse a run that needs one of those and was never given it. The guider,
  /// dome and cover calibrator are reached through `device_ops` with no id at
  /// all, so that walk structurally cannot see them and a `Dither`,
  /// `StartGuiding` or `CalibratorOn` node starts, then fails mid-run. The
  /// host is the one place that can refuse it — it knows which devices are
  /// actually connected.
  final Map<DeviceType, String> unassignableRoleRequirements;

  const _WireSequenceSummary({
    required this.name,
    required this.singleTargetRaHours,
    required this.singleTargetDecDegrees,
    required this.totalExposures,
    this.unassignableRoleRequirements = const {},
  });

  /// Read [json] as a serialized `SequenceDefinition`.
  ///
  /// Never throws: this runs on the load path, and a summary that cannot be
  /// built must degrade to a less-labelled session row rather than refuse a
  /// sequence the executor itself accepted. `validateSequenceWireJson` has
  /// already run by here and rejects anything structurally unusable, so a
  /// failure here means the LABELLING could not be derived, not that the
  /// sequence is bad.
  ///
  /// [onError] receives that failure. The load path has the logger, so the
  /// swallow is auditable there instead of vanishing: a null summary silently
  /// costs the run its `imaging_sessions` row AND leaves the guider / dome /
  /// cover pre-flight with nothing to check.
  static _WireSequenceSummary? parse(
    String json, {
    void Function(Object error)? onError,
  }) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, Object?>) return null;

      final rawNodes = decoded['nodes'];
      final nodes = <String, Map<String, Object?>>{};
      if (rawNodes is List) {
        for (final raw in rawNodes) {
          if (raw is! Map<String, Object?>) continue;
          final id = raw['id'];
          if (id is String && id.isNotEmpty) nodes[id] = raw;
        }
      }

      final headers = nodes.values
          .where(
            (n) => _typeOf(n) == 'TargetHeader' || _typeOf(n) == 'TargetGroup',
          )
          .toList(growable: false);
      final single = headers.length == 1 ? _configOf(headers.first) : null;

      final rootId = decoded['root_node_id'];
      final total = rootId is String && nodes.containsKey(rootId)
          ? _countExposures(nodes, rootId, 1, <String>{})
          // No root: fall back to the flat sum, matching `Sequence`'s own
          // fallback rather than reporting a denominator of zero.
          : nodes.values.fold<int>(0, (sum, n) => sum + _framesIn(n));

      return _WireSequenceSummary(
        name:
            decoded['name'] is String && (decoded['name'] as String).isNotEmpty
            ? decoded['name'] as String
            : 'Headless Run',
        singleTargetRaHours: _asDouble(single?['ra_hours']),
        singleTargetDecDegrees: _asDouble(single?['dec_degrees']),
        totalExposures: total,
        unassignableRoleRequirements: _collectUnassignableRoles(nodes, rootId),
      );
    } on Object catch (error) {
      onError?.call(error);
      return null;
    }
  }

  /// Wire node types that need a device `sequencerSetDevices` cannot carry.
  ///
  /// `StopGuiding` is deliberately absent: stopping a guider that was never
  /// started is a no-op, and refusing a run over a cleanup step would be the
  /// same over-blocking the `FlatWizard` filter-change exemption avoids.
  static const _rolesByWireType = <String, DeviceType>{
    'Dither': DeviceType.guider,
    'StartGuiding': DeviceType.guider,
    'OpenDome': DeviceType.dome,
    'CloseDome': DeviceType.dome,
    'ParkDome': DeviceType.dome,
    'OpenCover': DeviceType.coverCalibrator,
    'CloseCover': DeviceType.coverCalibrator,
    'CalibratorOn': DeviceType.coverCalibrator,
    'CalibratorOff': DeviceType.coverCalibrator,
  };

  /// Walk the enabled tree collecting the roles above. Disabled nodes and
  /// their subtrees contribute nothing — the executor returns `Skipped` before
  /// it descends, so a disabled branch never reaches hardware and must never
  /// block a start. Same rule the native walk follows.
  static Map<DeviceType, String> _collectUnassignableRoles(
    Map<String, Map<String, Object?>> nodes,
    Object? rootId,
  ) {
    final found = <DeviceType, String>{};

    void visit(String nodeId, Set<String> seen) {
      if (!seen.add(nodeId)) return;
      final node = nodes[nodeId];
      if (node == null || !_isEnabled(node)) return;

      final role = _rolesByWireType[_typeOf(node)];
      if (role != null) {
        found.putIfAbsent(
          role,
          () => node['name'] is String && (node['name'] as String).isNotEmpty
              ? node['name'] as String
              : _typeOf(node),
        );
      }

      final children = node['children'];
      if (children is List) {
        for (final child in children.whereType<String>()) {
          visit(child, seen);
        }
      }
    }

    if (rootId is String && nodes.containsKey(rootId)) {
      visit(rootId, <String>{});
    } else {
      // No root: every node is reachable in principle, so treat them all as
      // enabled leaves rather than reporting no requirements at all.
      for (final entry in nodes.entries) {
        visit(entry.key, <String>{});
      }
    }
    return found;
  }

  static String _typeOf(Map<String, Object?> node) {
    final config = node['node_type'];
    if (config is Map<String, Object?> && config['type'] is String) {
      return config['type'] as String;
    }
    return '';
  }

  static Map<String, Object?> _configOf(Map<String, Object?> node) {
    final config = node['node_type'];
    return config is Map<String, Object?> ? config : const {};
  }

  /// Rust's serde defaults `enabled` to true when the key is absent, so an
  /// absent key must read as enabled here too — the same reasoning as in
  /// `validateSequenceWireJson`.
  static bool _isEnabled(Map<String, Object?> node) =>
      node['enabled'] is bool ? node['enabled'] as bool : true;

  static double? _asDouble(Object? value) =>
      value is num ? value.toDouble() : null;

  static int _asInt(Object? value) => value is num ? value.toInt() : 0;

  /// Frames this single node plans, ignoring anything below it.
  static int _framesIn(Map<String, Object?> node) {
    if (!_isEnabled(node)) return 0;
    final config = _configOf(node);
    switch (_typeOf(node)) {
      case 'TakeExposure':
      case 'SciencePhotometry':
        return _asInt(config['count']);
      case 'SmartExposure':
        // Looping until stopped, the run ignores the plan counts (as
        // `SequenceNode.framesPerPass` does for the model).
        if (config['loop_until_stopped'] == true) return 0;
        final plans = config['plans'];
        if (plans is! List) return 0;
        return plans.whereType<Map<String, Object?>>().fold<int>(
          0,
          (sum, p) => sum + _asInt(p['count']),
        );
      default:
        return 0;
    }
  }

  /// Walk from [nodeId] scaling by the accumulated loop multiplier, mirroring
  /// `plannedCaptureUnder`. Only a `Count` loop multiplies: an unbounded
  /// loop has no honest denominator, and inventing one would make the progress
  /// bar claim a total the run was never going to reach.
  ///
  /// [seen] guards against a cyclic `children` graph, which the wire format
  /// permits structurally.
  static int _countExposures(
    Map<String, Map<String, Object?>> nodes,
    String nodeId,
    int mult,
    Set<String> seen,
  ) {
    if (!seen.add(nodeId)) return 0;
    final node = nodes[nodeId];
    if (node == null || !_isEnabled(node)) return 0;

    var count = _framesIn(node) * mult;

    var childMult = mult;
    if (_typeOf(node) == 'Loop') {
      final config = _configOf(node);
      final iterations = _asInt(config['iterations']);
      if (config['condition'] == 'Count' && iterations > 0) {
        childMult = mult * iterations;
      }
    }

    final children = node['children'];
    if (children is List) {
      for (final child in children.whereType<String>()) {
        count += _countExposures(nodes, child, childMult, seen);
      }
    }
    return count;
  }
}
