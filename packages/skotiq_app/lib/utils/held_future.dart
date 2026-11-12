import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// [provider]'s value once it has loaded, with the provider listened to for
/// as long as that takes.
///
/// `await ref.read(provider.future)` leaves a provider that nothing else is
/// watching without a listener. When something it watches changes while it
/// loads (the backend, the settings or the camera, all of which move in the
/// seconds after a computer links to a rig), Riverpod drops the load in
/// flight and starts the next one only when somebody listens. Nobody does,
/// so the future never completes: one-tap Tonight sat on "Planning the
/// night…" until its timeout. Listening for the wait makes the reload happen
/// and hands back its value.
///
/// A value from before a reload is not taken; an error ends the wait with
/// that error.
Future<T> readHeld<T>(
  WidgetRef ref,
  ProviderListenable<AsyncValue<T>> provider,
) {
  final completer = Completer<T>();
  final subscription = ref.listenManual<AsyncValue<T>>(
    provider,
    (_, next) {
      if (completer.isCompleted || next.isLoading) return;
      if (next.hasError) {
        completer.completeError(next.error!, next.stackTrace);
      } else if (next.hasValue) {
        completer.complete(next.requireValue);
      }
    },
    fireImmediately: true,
  );
  return completer.future.whenComplete(subscription.close);
}
