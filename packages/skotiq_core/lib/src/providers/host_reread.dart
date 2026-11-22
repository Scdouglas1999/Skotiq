import 'package:flutter_riverpod/flutter_riverpod.dart';

final _hostRereadsProvider = Provider<Set<void Function()>>((ref) => {});

extension HostReread on Ref<Object?> {
  /// Declares that this provider reads data the host stores (profiles,
  /// settings, plans, history), so a linked client reads it again on
  /// connect, on reconnect and with each periodic re-read
  /// ([rereadHostData]). Call it from the provider's body or `build`.
  ///
  /// Such data is what the host may change without telling a client that
  /// was not listening. Runtime state reaches a client through the runtime
  /// channels instead.
  void rereadsWithTheHost() {
    final rereads = read(_hostRereadsProvider);
    void reread() => invalidateSelf();
    rereads.add(reread);
    onDispose(() => rereads.remove(reread));
  }
}

/// Read again every provider that [HostReread.rereadsWithTheHost] declared
/// and that is in use now. Each then shows the host's value at once instead
/// of after its own poll.
void rereadHostData(ProviderContainer container) {
  for (final reread in [...container.read(_hostRereadsProvider)]) {
    reread();
  }
}
