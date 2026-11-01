// A companion that cannot open its session says which host and why, keeps
// retrying an unreachable host, never retries a rejected token, and is never
// sent into the first-run equipment wizard.

import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../harness/in_memory_database.dart';

class _FailingBackendNotifier extends BackendNotifier {
  _FailingBackendNotifier(super.ref, this.error, {this.tokenRejected = false});

  final Object error;
  final bool tokenRejected;
  int connects = 0;

  @override
  bool get lastConnectTokenRejected => tokenRejected;

  @override
  Future<void> connect(
    String host,
    int port, {
    String? authToken,
    String scheme = 'http',
    String? pinnedFingerprint,
    String? collaborationViewerId,
    String? collaborationDeviceName,
    String? collaborationDisplayName,
  }) async {
    connects++;
    throw error;
  }
}

const _target = RemoteLaunchTarget(
  host: '192.168.1.100',
  port: 8099,
  token: 'wrong',
);

void main() {
  late _FailingBackendNotifier notifier;

  ProviderContainer containerFor(Object error, {bool tokenRejected = false}) {
    return ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        remoteLaunchTargetProvider.overrideWithValue(_target),
        remoteClientLaunchProvider.overrideWithValue(true),
        backendProvider.overrideWith((ref) {
          notifier = _FailingBackendNotifier(
            ref,
            error,
            tokenRejected: tokenRejected,
          );
          return notifier;
        }),
      ],
    );
  }

  test('an unreachable host is named and retried on its own', () {
    fakeAsync((async) {
      final container = containerFor(
        const SocketException('Connection refused'),
      );
      container.read(remoteLaunchStatusProvider.notifier).connect();
      async.flushMicrotasks();

      final status = container.read(remoteLaunchStatusProvider);
      expect(status.failure, RemoteLaunchFailure.unreachable);
      expect(
        remoteLaunchFailureMessage(_target, status.failure!),
        "Can't reach the imaging host at 192.168.1.100:8099.",
      );
      expect(notifier.connects, 1);

      async.elapse(RemoteLaunchStatusNotifier.autoRetryInterval);
      async.flushMicrotasks();
      expect(notifier.connects, 2);
      container.dispose();
    });
  });

  test('a rejected token is reported as such and not retried', () {
    fakeAsync((async) {
      final container = containerFor(
        StateError('Connection did not complete (state=error).'),
        tokenRejected: true,
      );
      container.read(remoteLaunchStatusProvider.notifier).connect();
      async.flushMicrotasks();

      final status = container.read(remoteLaunchStatusProvider);
      expect(status.failure, RemoteLaunchFailure.tokenRejected);
      expect(
        remoteLaunchFailureMessage(_target, status.failure!),
        'The imaging host at 192.168.1.100:8099 rejected the access token.',
      );
      async.elapse(const Duration(minutes: 5));
      expect(notifier.connects, 1);
      container.dispose();
    });
  });

  test('a companion launch never runs the equipment onboarding', () async {
    final container = containerFor(const SocketException('refused'));
    addTearDown(container.dispose);
    expect(
      await container.read(shouldRunEquipmentOnboardingProvider.future),
      isFalse,
    );
  });

  test('a host with no profiles still gets onboarding', () async {
    final container = ProviderContainer(
      overrides: [inMemoryDatabaseOverride()],
    );
    addTearDown(container.dispose);
    expect(
      await container.read(shouldRunEquipmentOnboardingProvider.future),
      isTrue,
    );
  });
}
