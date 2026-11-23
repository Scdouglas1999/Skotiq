import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../backend/skotiq_backend.dart';
import '../utils/async_scope.dart';
import 'backend_provider.dart';

/// `ref.read` of a [Ref], a [WidgetRef] or a [ProviderContainer].
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Hands out [AsyncScope]s for one owner (a `State`, a notifier, a service).
///
/// * [begin] scopes are independent: any number can be current at once.
/// * [beginLatest] scopes supersede each other per [slot]: starting a new one
///   makes the previous one stale ("only the newest load may apply").
/// * [cancelAll] makes every scope handed out so far stale.
final class AsyncScopes<T> {
  /// Scopes over the value of [authority], read through [read]. [alive] is the
  /// owner's own liveness (`() => mounted`); it is consulted first, so [read]
  /// is never called on a disposed owner.
  AsyncScopes(
    ProviderReader read,
    ProviderListenable<T> authority, {
    bool Function()? alive,
  }) : _read = read,
       _authority = authority,
       _alive = alive;

  final ProviderReader _read;
  final ProviderListenable<T> _authority;
  final bool Function()? _alive;

  int _epoch = 0;
  final _latest = <Object, int>{};

  AsyncScope<T> begin() => over(_read(_authority));

  /// A scope over [value], for work that was handed its authority (the
  /// backend an event came from) instead of reading the current one. It is
  /// stale from the start when [value] is not the current authority.
  AsyncScope<T> over(T value) {
    final epoch = _epoch;
    return AsyncScope(value, () => _holds(value, epoch));
  }

  AsyncScope<T> beginLatest([Object slot = #load]) {
    final value = _read(_authority);
    final epoch = _epoch;
    final turn = (_latest[slot] ?? 0) + 1;
    _latest[slot] = turn;
    return AsyncScope(
      value,
      () => _latest[slot] == turn && _holds(value, epoch),
    );
  }

  void cancelAll() => _epoch++;

  bool _holds(T value, int epoch) {
    if (!(_alive?.call() ?? true) || epoch != _epoch) return false;
    try {
      return identical(_read(_authority), value);
    } on StateError {
      // The container the reader belongs to was disposed.
      return false;
    }
  }
}

/// Scopes tied to the current backend, for owners that hold a [Ref].
extension BackendScopeRef on Ref {
  /// A scope over [value], which the caller was handed as [authority]'s
  /// value when its work began.
  AsyncScope<T> scopeOver<T>(ProviderListenable<T> authority, T value) =>
      AsyncScopes(read, authority).over(value);

  AsyncScope<SkotiqBackend> backendScopeOver(SkotiqBackend backend) =>
      scopeOver(backendProvider, backend);

  AsyncScopes<SkotiqBackend> backendScopes({bool Function()? alive}) =>
      AsyncScopes(read, backendProvider, alive: alive);

  /// One scope over the backend that is current now.
  AsyncScope<SkotiqBackend> backendScope({bool Function()? alive}) =>
      backendScopes(alive: alive).begin();

  /// One scope over the backend that is current now, for a service this
  /// provider builds for that backend. It goes stale when the backend changes
  /// and when this provider is disposed or rebuilt.
  ///
  /// The backend is read through the container, not this [Ref]: a provider's
  /// own `Ref` must not be used between a dependency change and the rebuild,
  /// which is exactly when a service checks whether its work is still wanted.
  AsyncScope<SkotiqBackend> providerBackendScope() {
    var built = true;
    onDispose(() => built = false);
    return AsyncScopes(
      container.read,
      backendProvider,
      alive: () => built,
    ).begin();
  }
}

/// Scopes tied to the current backend, for widgets.
extension BackendScopeWidgetRef on WidgetRef {
  AsyncScope<T> scopeOver<T>(ProviderListenable<T> authority, T value) =>
      AsyncScopes(read, authority).over(value);

  AsyncScope<SkotiqBackend> backendScopeOver(SkotiqBackend backend) =>
      scopeOver(backendProvider, backend);

  AsyncScopes<SkotiqBackend> backendScopes({bool Function()? alive}) =>
      AsyncScopes(read, backendProvider, alive: alive);

  /// One scope over the backend that is current now. Pass
  /// `alive: () => mounted` (or `() => context.mounted`).
  AsyncScope<SkotiqBackend> backendScope({bool Function()? alive}) =>
      backendScopes(alive: alive).begin();
}

/// Scopes tied to the current backend, for code that holds the container.
extension BackendScopeContainer on ProviderContainer {
  AsyncScopes<SkotiqBackend> backendScopes() =>
      AsyncScopes(read, backendProvider);

  /// A scope over [backend], which the caller was handed. Stale once the
  /// backend is replaced or this container is disposed.
  AsyncScope<SkotiqBackend> backendScopeOver(SkotiqBackend backend) =>
      backendScopes().over(backend);
}
