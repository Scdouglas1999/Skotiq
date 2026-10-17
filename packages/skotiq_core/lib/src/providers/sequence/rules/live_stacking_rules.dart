// Validation rules for the LiveStacking node.
//
// A LiveStacking node sitting in a sequence with no sibling exposure
// nodes is silently broken: the executor arms the broadcast, but no
// frames ever arrive to stack. Surface that as a warning so the user
// catches it before the outreach event starts. The port-clash rule
// guards against the configured broadcast port colliding with the
// running headless API server, which would manifest as either "503
// Service Unavailable" on the broadcast (best case) or "the dashboard
// suddenly returns broadcast JPEGs" (worst case). Both are user-
// visible bugs we want to fail loudly at edit time.

import '../../../models/sequence/sequence_models.dart';
import '../sequence_validation.dart';
import '../sequencer_defaults.dart';

/// LiveStacking only does something useful if there are sibling
/// exposure-producing nodes in the same subtree. A LiveStacking node
/// with no sibling exposure (across the whole sequence) is a
/// misconfiguration.
///
/// We define "sibling exposure" broadly — any ExposureNode or
/// SmartExposureNode anywhere in the same enabled sequence. The
/// broadcast service feeds on `FrameAccepted` events from anywhere in
/// the run, so as long as *some* exposure node exists the broadcast
/// has frames to consume. The "no exposure node at all" case is the
/// one we want to flag.
class LiveStackingNoExposureRule implements SequenceValidator {
  @override
  String get name => 'LiveStackingNoExposure';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];
    final liveStackingNodes = sequence.nodes.values
        .whereType<LiveStackingNode>()
        .where((n) => n.isEnabled)
        .toList(growable: false);
    if (liveStackingNodes.isEmpty) return issues;

    final hasExposureNode = sequence.nodes.values.any(
      (n) => n.isEnabled && (n is ExposureNode || n is SmartExposureNode),
    );

    if (hasExposureNode) return issues;

    for (final node in liveStackingNodes) {
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.exposures,
          title: 'Live Stacking has nothing to broadcast',
          description:
              'Live Stacking "${node.name}" is in this sequence but there are no '
              'Exposure or Smart Exposure nodes. The broadcast will arm but no '
              'frames will be stacked.',
          affectedNodeId: node.id,
          resolutionHint:
              'Add at least one Exposure or Smart Exposure node alongside Live '
              'Stacking.',
        ),
      );
    }
    return issues;
  }
}

/// Live Stacking on the same port as the main headless API server is
/// a configuration error. The shelf server cannot bind twice; the
/// broadcast would either fail to start (best case) or — more likely
/// because the headless server is already listening — the audience
/// gets the dashboard's CORS-rejected reply instead of the broadcast
/// HTML page. Either way the operator looks bad at the public event.
///
/// We compare against the documented default of 8080 because the
/// `web_server_provider` (which knows the actually-bound port) lives
/// in the desktop runtime layer, which `skotiq_core` cannot
/// import. The desktop app sets the LiveStacking palette default to
/// 8081 so the only way to hit this rule is for the user to type the
/// collision in explicitly — exactly the case we want to flag.
class LiveStackingPortClashRule implements SequenceValidator {
  /// Documented default headless API port. Match
  /// `desktop_app_bootstrap.dart`'s default; the platform-specific
  /// override (when the user changes the port in Settings) is checked
  /// at runtime by the desktop bootstrap, not at edit time.
  static const int defaultMainAppPort = 8080;

  @override
  String get name => 'LiveStackingPortClash';

  @override
  List<ValidationIssue> validate(Sequence sequence) {
    final issues = <ValidationIssue>[];

    // Track per-port LiveStacking occurrences so we can flag two nodes
    // colliding with each other as well as the main app server.
    final byPort = <int, List<LiveStackingNode>>{};
    for (final node in sequence.nodes.values) {
      if (node is! LiveStackingNode) continue;
      if (!node.isEnabled) continue;
      byPort.putIfAbsent(node.broadcastPort, () => []).add(node);
    }

    for (final entry in byPort.entries) {
      final port = entry.key;
      final nodes = entry.value;
      if (port <= 0 || port > 65535) {
        for (final n in nodes) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.exposures,
              title: 'Live Stacking port out of range',
              description:
                  'Live Stacking "${n.name}" has broadcast port $port which is '
                  'outside the valid TCP range (1–65535).',
              affectedNodeId: n.id,
              resolutionHint: 'Pick a port between 1024 and 65535.',
            ),
          );
        }
        continue;
      }
      if (port == defaultMainAppPort) {
        for (final n in nodes) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.error,
              category: ValidationCategory.exposures,
              title: 'Live Stacking port clashes with main server',
              description:
                  'Live Stacking "${n.name}" broadcasts on port $port, which is '
                  'the Skotiq headless API server\'s default port. The '
                  'broadcast will fail to bind.',
              affectedNodeId: n.id,
              resolutionHint:
                  'Choose a different broadcast port — 8081 is the recommended '
                  'default for the broadcast.',
            ),
          );
        }
      }
      if (nodes.length > 1) {
        // Two LiveStacking nodes on the same port. Last one wins at
        // runtime (the Rust singleton replaces the active session)
        // but the editor should warn the user that the older node's
        // broadcast will be torn down when the newer one runs.
        for (final n in nodes) {
          issues.add(
            ValidationIssue(
              severity: ValidationSeverity.warning,
              category: ValidationCategory.exposures,
              title: 'Multiple Live Stacking nodes share a port',
              description:
                  'Live Stacking "${n.name}" shares broadcast port $port with '
                  '${nodes.length - 1} other Live Stacking '
                  'node${(nodes.length - 1) == 1 ? '' : 's'}. Only the '
                  'most recently entered node\'s broadcast will be live.',
              affectedNodeId: n.id,
              resolutionHint:
                  'Either remove the duplicate nodes or assign each a distinct '
                  'broadcast port.',
            ),
          );
        }
      }
    }
    return issues;
  }
}

/// Warns when the global "disable Live Stacking everywhere" kill switch is
/// on but the sequence still contains an enabled [LiveStackingNode].
///
/// `SequencerDefaults.livestackingDisableEverywhere` is a master override
/// consulted at sequence-start: when true, every LiveStackingNode has its
/// broadcast forced off (the stack still builds in memory but the broadcast
/// endpoint returns 404). A user who dropped a Live Stacking node and then
/// flipped the global switch in Settings would otherwise get no feedback
/// that the node will arm nothing at runtime — surface it at edit time so
/// they re-enable broadcasts (or remove the node) before the outreach event.
class LiveStackingGloballyDisabledRule implements RefAwareSequenceValidator {
  @override
  String get name => 'LiveStackingGloballyDisabled';

  @override
  List<ValidationIssue> validate(Sequence sequence, ValidationContext ctx) {
    final defaults = ctx.ref.read(sequencerDefaultsProvider);
    if (!defaults.livestackingDisableEverywhere) return const [];

    final issues = <ValidationIssue>[];
    for (final node in sequence.nodes.values) {
      if (node is! LiveStackingNode) continue;
      if (!node.isEnabled) continue;
      issues.add(
        ValidationIssue(
          severity: ValidationSeverity.warning,
          category: ValidationCategory.exposures,
          title: 'Live Stacking is globally disabled',
          description:
              'Live Stacking "${node.name}" is enabled, but Live Stacking is '
              'globally disabled in Settings; this node will arm nothing and '
              'the broadcast endpoint will return 404.',
          affectedNodeId: node.id,
          resolutionHint:
              'Turn off "Disable Live Stacking everywhere" in Sequencer '
              'Settings, or remove this Live Stacking node.',
        ),
      );
    }
    return issues;
  }
}
