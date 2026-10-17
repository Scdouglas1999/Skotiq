// A typed capture folder must commit on a REMOTE host too.
//
// Typing a path is the only sane route on an appliance driven over VNC, and an
// appliance is exactly the setup that runs the app in remote mode. The typed
// path therefore has to reach the draft on the remote branch as well as the
// local one — otherwise the box accepts the path, the host confirms it, and the
// wizard still holds nothing.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/onboarding/steps/capture_dir_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _PinnedBackendNotifier extends BackendNotifier {
  _PinnedBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _TestOnboardingNotifier extends OnboardingNotifier {
  _TestOnboardingNotifier(super.ref);
}

ProviderContainer _container(
  SkotiqDatabase database,
  SkotiqBackend backend,
) {
  return ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(database),
      onboardingDraftProvider.overrideWith(_TestOnboardingNotifier.new),
      backendProvider.overrideWith(
        (ref) => _PinnedBackendNotifier(ref, backend),
      ),
    ],
  );
}

Widget _surface(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: SkotiqTheme.dark,
      home: const Scaffold(body: OnboardingCaptureDirStep()),
    ),
  );
}

void main() {
  testWidgets('a typed folder the host accepts becomes the capture directory',
      (tester) async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final backend = _MockNetworkBackend();
    when(
      () => backend.validateRemoteDirectory(
        '/mnt/host/astro',
        mustExist: true,
        mustBeWritable: true,
      ),
    ).thenAnswer(
      (_) async => const {'valid': true, 'normalizedPath': '/mnt/host/astro'},
    );

    final container = _container(database, backend);
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(onboardingCaptureDirFieldKey),
      '/mnt/host/astro',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      container.read(onboardingDraftProvider).captureDirectory,
      '/mnt/host/astro',
      reason: 'the host said yes, so the wizard must be holding the folder',
    );
    expect(find.text('Folder is writable.'), findsOneWidget);
    // Exactly one round trip: the box is disabled for the duration, so the
    // focus-loss commit cannot ask the host the same question a second time.
    verify(
      () => backend.validateRemoteDirectory(
        '/mnt/host/astro',
        mustExist: true,
        mustBeWritable: true,
      ),
    ).called(1);
  });

  testWidgets('a typed folder the host rejects is not stored', (tester) async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final backend = _MockNetworkBackend();
    when(
      () => backend.validateRemoteDirectory(
        '/mnt/host/typo',
        mustExist: true,
        mustBeWritable: true,
      ),
    ).thenAnswer(
      (_) async => const {'valid': false, 'error': 'No such directory.'},
    );

    final container = _container(database, backend);
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(onboardingCaptureDirFieldKey),
      '/mnt/host/typo',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      container.read(onboardingDraftProvider).captureDirectory,
      isNull,
      reason: 'a folder the host refused must not unblock Next',
    );
    expect(find.text('No such directory.'), findsOneWidget);
  });
}
