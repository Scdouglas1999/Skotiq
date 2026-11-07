import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime_mirror_channel.dart';
import '../runtime_mirror_codec.dart';

/// Where a pending sequence start stands.
enum PendingStartPhase {
  /// Counting down to the automatic unpark.
  counting,

  /// The other window asked to unpark now.
  unparkNow,

  /// The unpark is in progress.
  unparking,

  /// The other window canceled the start.
  cancelled,
}

/// A sequence start waiting on the "Mount is parked, unparking in N s"
/// countdown.
///
/// The window that pressed Start owns the countdown and is the only one that
/// unparks and starts the run. The other window shows the same countdown
/// and can cancel it or unpark now; it asks by writing [phase], and the
/// owner acts on it.
@immutable
class PendingSequenceStart {
  const PendingSequenceStart({
    required this.id,
    required this.owner,
    required this.deadline,
    required this.seconds,
    this.phase = PendingStartPhase.counting,
  });

  /// One countdown; a later one gets a new id.
  final String id;

  /// The runtime-mirror origin of the window that pressed Start.
  final String owner;

  /// When the owner unparks on its own.
  final DateTime deadline;

  /// The countdown's full length, which bounds what a window with a skewed
  /// clock shows.
  final int seconds;

  final PendingStartPhase phase;

  /// Seconds left as this window counts them.
  int remainingSeconds(DateTime now) {
    final left = (deadline.difference(now).inMilliseconds / 1000).ceil();
    return left.clamp(0, seconds);
  }

  PendingSequenceStart withPhase(PendingStartPhase next) =>
      PendingSequenceStart(
        id: id,
        owner: owner,
        deadline: deadline,
        seconds: seconds,
        phase: next,
      );

  @override
  bool operator ==(Object other) =>
      other is PendingSequenceStart &&
      other.id == id &&
      other.owner == owner &&
      other.deadline == deadline &&
      other.seconds == seconds &&
      other.phase == phase;

  @override
  int get hashCode => Object.hash(id, owner, deadline, seconds, phase);
}

/// The pending start both windows show; null when there is none.
final pendingSequenceStartProvider = StateProvider<PendingSequenceStart?>(
  (ref) => null,
);

/// The pre-start unpark countdown, shown and cancelable in both windows.
/// Only the window that pressed Start used to see it, so the other one
/// showed an idle sequence while the mount was about to unpark.
class PendingStartChannel extends SharedStateChannel<PendingSequenceStart?> {
  const PendingStartChannel();

  @override
  String get key => 'pendingStart';

  @override
  get source => pendingSequenceStartProvider;

  @override
  Map<String, dynamic>? encode(PendingSequenceStart? value) => value == null
      ? null
      : {
          'id': value.id,
          'owner': value.owner,
          'deadline': value.deadline.toUtc().millisecondsSinceEpoch,
          'seconds': value.seconds,
          'phase': value.phase.name,
        };

  @override
  PendingSequenceStart? decode(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = jsonString(json['id']);
    final owner = jsonString(json['owner']);
    final deadline = jsonInstant(json['deadline']);
    if (id == null || owner == null || deadline == null) {
      throw const FormatException('Pending start without id/owner/deadline');
    }
    return PendingSequenceStart(
      id: id,
      owner: owner,
      deadline: deadline,
      seconds: requireInt(json, 'seconds'),
      phase: PendingStartPhase.values.firstWhere(
        (p) => p.name == json['phase'],
        orElse: () => PendingStartPhase.counting,
      ),
    );
  }

  @override
  void write(RuntimeApplyContext context, PendingSequenceStart? value) {
    context.read(pendingSequenceStartProvider.notifier).state = value;
  }
}
