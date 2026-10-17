// The client ROLE, which is fixed at launch, versus the CONNECTION, which is
// not.
//
// `isRemoteModeProvider` answers "is a remote connection open right now". A
// desktop launched with `--remote-host` answers false to that for the whole of
// its pre-handshake window and again after every drop — and a surface that
// decides whose database it is editing read exactly that, so a never-connected
// client was offered the imaging host's own editor over its empty local rows.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  test('a process that declares nothing owns its own hardware', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(remoteClientLaunchProvider), isFalse);
    expect(container.read(isRemoteModeProvider), isFalse);
    expect(container.read(isRemoteClientProvider), isFalse);
  });

  test('a client that has not connected yet is still a client', () {
    final container = ProviderContainer(
      overrides: [remoteClientLaunchProvider.overrideWithValue(true)],
    );
    addTearDown(container.dispose);

    expect(
      container.read(isRemoteModeProvider),
      isFalse,
      reason: 'the backend is still the disconnected one',
    );
    expect(container.read(isRemoteClientProvider), isTrue);
  });

  test(
    'an open connection makes a client of a process that never declared it',
    () {
      final container = ProviderContainer(
        overrides: [isRemoteModeProvider.overrideWithValue(true)],
      );
      addTearDown(container.dispose);

      expect(container.read(remoteClientLaunchProvider), isFalse);
      expect(container.read(isRemoteClientProvider), isTrue);
    },
  );
}
