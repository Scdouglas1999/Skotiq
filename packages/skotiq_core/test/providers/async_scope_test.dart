import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/providers.dart';

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

void main() {
  late DisconnectedBackend hostA;
  late DisconnectedBackend hostB;
  late _SwappableBackendNotifier notifier;
  late ProviderContainer container;

  setUp(() {
    hostA = DisconnectedBackend();
    hostB = DisconnectedBackend();
    container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => notifier = _SwappableBackendNotifier(ref, hostA),
        ),
      ],
    );
    container.read(backendProvider);
  });

  tearDown(() {
    container.dispose();
    hostA.dispose();
    hostB.dispose();
  });

  AsyncScopes<SkotiqBackend> scopes({bool Function()? alive}) =>
      AsyncScopes(container.read, backendProvider, alive: alive);

  test(
      'a provider scope goes stale on a host switch without touching the '
      'provider before it rebuilds, and when the provider is disposed',
      () async {
    final service = Provider.autoDispose<AsyncScope<SkotiqBackend>>((ref) {
      ref.watch(backendProvider);
      return ref.providerBackendScope();
    });
    final subscription = container.listen(service, (_, __) {});
    final first = subscription.read();
    expect(first.value, same(hostA));
    expect(first.isCurrent, isTrue);

    notifier.switchTo(hostB);
    // The provider has not rebuilt yet; reading through its own Ref here
    // would trip Riverpod's outdated-dependency assertion.
    expect(first.isStale, isTrue);

    final second = subscription.read();
    expect(second.value, same(hostB));
    expect(second.isCurrent, isTrue);

    subscription.close();
    await container.pump();
    expect(second.isStale, isTrue);
  });

  test('a scope captures the backend and holds while it is current', () {
    final scope = scopes().begin();
    expect(scope.value, same(hostA));
    expect(scope.isCurrent, isTrue);
    expect(scope.isStale, isFalse);
  });

  test('a backend swap makes the scope stale, and it stays stale', () {
    final scope = scopes().begin();
    notifier.switchTo(hostB);
    expect(scope.isCurrent, isFalse);

    // Another backend of the same kind is still a different authority.
    notifier.switchTo(DisconnectedBackend());
    expect(scope.isCurrent, isFalse);
  });

  test('ensureCurrent throws once stale and names what was interrupted', () {
    final scope = scopes().begin();
    expect(
      () => scope.ensureCurrent('the library was loading'),
      returnsNormally,
    );
    notifier.switchTo(hostB);
    expect(
      () => scope.ensureCurrent('the library was loading'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'The imaging host changed while the library was loading. The stale '
              'result was discarded; try again on the current host.',
        ),
      ),
    );
  });

  test('a dead owner is stale without reading the provider', () {
    var alive = true;
    var reads = 0;
    T countingRead<T>(ProviderListenable<T> provider) {
      reads++;
      return container.read(provider);
    }

    final scope = AsyncScopes(
      countingRead,
      backendProvider,
      alive: () => alive,
    ).begin();
    final readsAtCapture = reads;
    alive = false;
    expect(scope.isCurrent, isFalse);
    expect(reads, readsAtCapture);
  });

  test('independent scopes stay current together', () {
    final owner = scopes();
    final first = owner.begin();
    final second = owner.begin();
    expect(first.isCurrent, isTrue);
    expect(second.isCurrent, isTrue);
  });

  test('beginLatest supersedes the previous scope in the same slot only', () {
    final owner = scopes();
    final firstLoad = owner.beginLatest();
    final otherSlot = owner.beginLatest(#thumbnails);
    final plain = owner.begin();

    final secondLoad = owner.beginLatest();

    expect(firstLoad.isCurrent, isFalse);
    expect(secondLoad.isCurrent, isTrue);
    expect(otherSlot.isCurrent, isTrue);
    expect(plain.isCurrent, isTrue);
  });

  test('cancelAll makes every earlier scope stale and later ones current', () {
    final owner = scopes();
    final before = owner.begin();
    final latest = owner.beginLatest();

    owner.cancelAll();

    expect(before.isCurrent, isFalse);
    expect(latest.isCurrent, isFalse);
    expect(owner.begin().isCurrent, isTrue);
  });

  test('scopes can be taken over any provider, not only the backend', () {
    final store = StateProvider<Object>((ref) => Object());
    final owner = AsyncScopes<Object>(container.read, store);
    final scope = owner.begin();
    expect(scope.isCurrent, isTrue);
    container.read(store.notifier).state = Object();
    expect(scope.isCurrent, isFalse);
  });

  group('guard', () {
    test('returns the result while the scope holds', () async {
      final scope = scopes().begin();
      expect(await scope.guard((_) async => 7, ifStale: -1), 7);
    });

    test('returns ifStale when the backend changed during the await', () async {
      final scope = scopes().begin();
      final gate = Completer<int>();
      final result = scope.guard((_) => gate.future, ifStale: -1);
      notifier.switchTo(hostB);
      gate.complete(7);
      expect(await result, -1);
    });

    test('drops the error of a stale operation', () async {
      final scope = scopes().begin();
      final gate = Completer<int>();
      final result = scope.guard((_) => gate.future, ifStale: -1);
      notifier.switchTo(hostB);
      gate.completeError(StateError('host went away'));
      expect(await result, -1);
    });

    test('rethrows the error of a current operation', () {
      final scope = scopes().begin();
      expect(
        scope.guard<int>((_) async => throw StateError('real'), ifStale: -1),
        throwsStateError,
      );
    });
  });
}
