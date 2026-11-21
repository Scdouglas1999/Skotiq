import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../event_provider.dart';
import '../runtime_mirror_channel.dart';

/// Process identity, distinct from a persisted imaging-session id.
///
/// Stable for the life of this process: the provider is created once.
/// A linked client watches it and drops night caches when it changes.
final runtimeHostSessionProvider = StateProvider<String>(
  (_) => DateTime.now().microsecondsSinceEpoch.toString(),
);

/// The host process's id, as `{id}`. A client that sees a new id clears its
/// event history before the id is stored, so the empty-log seed can replace
/// the previous process's events. The same id does nothing.
class HostSessionChannel extends RuntimeMirrorChannel<String> {
  const HostSessionChannel();

  @override
  String get key => 'hostSession';

  @override
  get source => runtimeHostSessionProvider;

  @override
  Map<String, dynamic> encode(String value) => {'id': value};

  @override
  void apply(RuntimeApplyContext context, Map<String, dynamic>? value) {
    final id = value?['id'];
    if (id is! String || id.isEmpty) return;
    if (context.read(runtimeHostSessionProvider) == id) return;
    context.read(eventHistoryProvider.notifier).clear();
    context.read(runtimeHostSessionProvider.notifier).state = id;
  }
}
