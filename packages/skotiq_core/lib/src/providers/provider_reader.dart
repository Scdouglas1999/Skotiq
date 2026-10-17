import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Read [provider] through a [Ref], a [ProviderContainer] or a [WidgetRef].
///
/// The remote-sync and equipment-reset paths run from all three: inside the app
/// they hold a `Ref`, a widget reading the same device table holds a
/// `WidgetRef`, and the headless server drives the same code against a bare
/// `ProviderContainer` with no widget tree. Riverpod gives those no common
/// supertype, so the reader is passed as `Object` and narrowed here.
T readProvider<T>(Object reader, ProviderListenable<T> provider) {
  if (reader is Ref) {
    return reader.read(provider);
  }
  if (reader is ProviderContainer) {
    return reader.read(provider);
  }
  if (reader is WidgetRef) {
    return reader.read(provider);
  }
  throw ArgumentError.value(
    reader,
    'reader',
    'Expected Ref, ProviderContainer or WidgetRef',
  );
}

/// Invalidate [provider] through either a [Ref] or a [ProviderContainer].
void invalidateProvider(Object reader, ProviderOrFamily provider) {
  if (reader is Ref) {
    reader.invalidate(provider);
    return;
  }
  if (reader is ProviderContainer) {
    reader.invalidate(provider);
    return;
  }
  throw ArgumentError.value(
    reader,
    'reader',
    'Expected Ref or ProviderContainer',
  );
}
