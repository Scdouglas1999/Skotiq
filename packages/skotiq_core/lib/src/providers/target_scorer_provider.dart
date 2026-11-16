import '../backend/target_scoring.dart';
import '../services/target_scorer.dart';
import 'host_role.dart';

/// The app's target scorer: the native sequencer's in this process, the
/// linked host's on a client.
final targetScorerProvider = hostRoleProvider<TargetScorer>(
  here: (ref) => const TargetScorer(NativeTargetScoring()),
  linked: (ref, host) => TargetScorer(host.planning),
  name: 'targetScorerProvider',
);
