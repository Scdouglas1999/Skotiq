import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// The run warnings the operator hid, identified so both ends of a link
/// recognize the same list: the run (when it started, as
/// `runStartedAtProvider` holds it on both ends), how many warnings it had
/// and a fingerprint of their text.
@immutable
class RunWarningsAck {
  const RunWarningsAck({
    required this.run,
    required this.count,
    required this.fingerprint,
  });

  factory RunWarningsAck.of(DateTime? run, List<String> warnings) =>
      RunWarningsAck(
        run: run?.toUtc().millisecondsSinceEpoch,
        count: warnings.length,
        fingerprint: warningsFingerprint(warnings),
      );

  /// When the run started, in UTC milliseconds; null when unknown.
  final int? run;
  final int count;
  final int fingerprint;

  /// Whether [warnings] of the run started at [runStart] is the list this
  /// hid. A new warning, or another run, is not.
  bool covers(DateTime? runStart, List<String> warnings) =>
      runStart?.toUtc().millisecondsSinceEpoch == run &&
      warnings.length == count &&
      warningsFingerprint(warnings) == fingerprint;

  @override
  bool operator ==(Object other) =>
      other is RunWarningsAck &&
      other.run == run &&
      other.count == count &&
      other.fingerprint == fingerprint;

  @override
  int get hashCode => Object.hash(run, count, fingerprint);
}

/// A 32-bit FNV-1a hash of [warnings], stable across processes and builds
/// (unlike `String.hashCode`), so two apps compute the same value.
int warningsFingerprint(List<String> warnings) {
  var hash = 0x811c9dc5;
  void add(int unit) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }

  for (final warning in warnings) {
    for (final unit in warning.codeUnits) {
      add(unit);
    }
    // A separator, so ["ab", "c"] and ["a", "bc"] differ.
    add(0);
  }
  return hash;
}

/// Tip id of the DepthLock introduction ("Chasing something faint?").
const String depthLockHintTipId = 'depthLockHint';

/// The notices the operator has answered: the run-warnings banner they hid
/// and the one-time tips they dismissed.
@immutable
class NoticeAcknowledgments {
  const NoticeAcknowledgments({
    this.runWarnings,
    this.dismissedTips = const <String>{},
  });

  /// The warnings the banner was hidden at; null when it was not hidden.
  final RunWarningsAck? runWarnings;

  /// Ids of the dismissed tips, such as [depthLockHintTipId].
  final Set<String> dismissedTips;

  bool tipDismissed(String id) => dismissedTips.contains(id);

  NoticeAcknowledgments hidingRunWarnings(
    DateTime? runStart,
    List<String> warnings,
  ) => NoticeAcknowledgments(
    runWarnings: RunWarningsAck.of(runStart, warnings),
    dismissedTips: dismissedTips,
  );

  NoticeAcknowledgments dismissingTip(String id) => tipDismissed(id)
      ? this
      : NoticeAcknowledgments(
          runWarnings: runWarnings,
          dismissedTips: {...dismissedTips, id},
        );

  @override
  bool operator ==(Object other) =>
      other is NoticeAcknowledgments &&
      other.runWarnings == runWarnings &&
      setEquals(other.dismissedTips, dismissedTips);

  @override
  int get hashCode =>
      Object.hash(runWarnings, Object.hashAllUnordered(dismissedTips));
}

/// What this window shows as answered; the same on both ends of a link.
final noticeAcknowledgmentsProvider = StateProvider<NoticeAcknowledgments>(
  (ref) => const NoticeAcknowledgments(),
);

/// Banner and tip acknowledgments, shared both ways. Each window kept its
/// own, so hiding "4 run warnings" on the host left it on every linked
/// client (a client that connected later showed it too), and a tip
/// dismissed in one window stayed up in the other.
class NoticeAcknowledgmentsChannel
    extends SharedStateChannel<NoticeAcknowledgments> {
  const NoticeAcknowledgmentsChannel();

  @override
  String get key => 'noticeAcks';

  @override
  get source => noticeAcknowledgmentsProvider;

  @override
  Map<String, dynamic>? encode(NoticeAcknowledgments value) {
    final warnings = value.runWarnings;
    return {
      'runWarnings': warnings == null
          ? null
          : {
              'run': warnings.run,
              'count': warnings.count,
              'fingerprint': warnings.fingerprint,
            },
      'dismissedTips': (value.dismissedTips.toList()..sort()),
    };
  }

  @override
  NoticeAcknowledgments decode(Map<String, dynamic>? json) {
    if (json == null) return const NoticeAcknowledgments();
    final rawWarnings = json['runWarnings'];
    final rawTips = json['dismissedTips'];
    return NoticeAcknowledgments(
      runWarnings: rawWarnings is Map
          ? RunWarningsAck(
              run: jsonInt(rawWarnings['run']),
              count: requireInt(rawWarnings, 'count'),
              fingerprint: requireInt(rawWarnings, 'fingerprint'),
            )
          : null,
      dismissedTips: rawTips is List
          ? rawTips.whereType<String>().toSet()
          : const <String>{},
    );
  }

  @override
  void write(RuntimeApplyContext context, NoticeAcknowledgments value) {
    context.read(noticeAcknowledgmentsProvider.notifier).state = value;
  }
}
