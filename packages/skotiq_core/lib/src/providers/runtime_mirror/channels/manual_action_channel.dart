import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../runtime_mirror_channel.dart';

/// The manual action (snapshot, autofocus, centering, ...) this window is
/// running, by its action name; null when none is. Written by the window's
/// action controller.
final localManualActionProvider = StateProvider<String?>((ref) => null);

/// A manual action the window at the other end of the link is running.
@immutable
class LinkedManualAction {
  const LinkedManualAction({required this.action, required this.since});

  /// The action's name, as the other window's controller names it.
  final String action;

  /// When this window learned of it.
  final DateTime since;

  /// A window that went away mid-action never says the action ended; after
  /// this long without word it no longer counts as running.
  static const Duration staleAfter = Duration(minutes: 15);

  bool isCurrent(DateTime now) => now.difference(since) < staleAfter;
}

final linkedManualActionProvider = StateProvider<LinkedManualAction?>(
  (ref) => null,
);

/// Which manual action each end of the link is running, so the host's action
/// bar says a client's autofocus is running and the client's says the
/// host's is. Only the name travels; each window keeps its own controller.
class ManualActionChannel extends RuntimeMirrorChannel<String?> {
  const ManualActionChannel();

  @override
  String get key => 'manualAction';

  @override
  get source => localManualActionProvider;

  @override
  bool get clientReports => true;

  @override
  Map<String, dynamic>? encode(String? value) =>
      value == null ? null : {'action': value};

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final action = jsonString(value?['action']);
    context.read(linkedManualActionProvider.notifier).state = action == null
        ? null
        : LinkedManualAction(action: action, since: DateTime.now());
  }
}
