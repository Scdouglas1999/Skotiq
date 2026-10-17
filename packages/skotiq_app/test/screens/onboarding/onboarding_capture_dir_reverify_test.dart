// The capture-folder step must never claim writability it has not checked.
//
// "Folder is writable." must not be rendered from `draft.captureDirectory !=
// null` alone: the draft outlives the app run and the host connection, so a
// resumed wizard with the external drive unplugged — or a host path shown after
// falling back to the local backend — would get a green tick for a folder
// nothing had looked at.
//
// These tests pin the three honest outcomes: re-checked and good, re-checked
// and rejected, and could-not-check.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/onboarding/steps/capture_dir_step.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _PinnedBackendNotifier extends BackendNotifier {
  _PinnedBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

class _SwitchingBackendNotifier extends BackendNotifier {
  _SwitchingBackendNotifier(super.ref, SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }

  void replaceWith(SkotiqBackend backend) {
    // ignore: invalid_use_of_protected_member
    state = backend;
  }
}

/// Onboarding notifier seeded with a remembered capture folder, standing in for
/// a draft restored from `app_settings` on a later launch.
class _SeededOnboardingNotifier extends OnboardingNotifier {
  _SeededOnboardingNotifier(super.ref, String path) {
    // ignore: invalid_use_of_protected_member
    state = OnboardingDraft(
      currentStep: OnboardingStep.captureDir,
      captureDirectory: path,
    );
  }
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
  testWidgets('a remembered local folder is re-probed on entry and confirmed',
      (tester) async {
    final probed = <String>[];
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _PinnedBackendNotifier(ref, FfiBackend()),
        ),
        onboardingDraftProvider.overrideWith(
          (ref) => _SeededOnboardingNotifier(ref, '/data/captures'),
        ),
        onboardingCaptureDirectoryValidatorProvider.overrideWithValue(
          (path) async {
            probed.add(path);
            return null;
          },
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    expect(probed, ['/data/captures'],
        reason: 'entering the step re-checks the remembered folder');
    expect(find.text('Folder is writable.'), findsOneWidget);
  });

  testWidgets(
      'a remembered folder that has gone away reports the failure, '
      'not a green tick', (tester) async {
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _PinnedBackendNotifier(ref, FfiBackend()),
        ),
        onboardingDraftProvider.overrideWith(
          (ref) => _SeededOnboardingNotifier(ref, '/mnt/unplugged'),
        ),
        onboardingCaptureDirectoryValidatorProvider.overrideWithValue(
          (path) async => 'That folder does not exist.',
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    expect(find.text('Folder is writable.'), findsNothing);
    expect(find.text('That folder does not exist.'), findsOneWidget);
  });

  testWidgets('while the check is in flight nothing is claimed either way',
      (tester) async {
    final gate = Completer<String?>();
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _PinnedBackendNotifier(ref, FfiBackend()),
        ),
        onboardingDraftProvider.overrideWith(
          (ref) => _SeededOnboardingNotifier(ref, '/data/captures'),
        ),
        onboardingCaptureDirectoryValidatorProvider.overrideWithValue(
          (path) => gate.future,
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pump();
    await tester.pump();

    expect(find.text('Checking write permissions…'), findsOneWidget);
    expect(find.text('Folder is writable.'), findsNothing);

    gate.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('Folder is writable.'), findsOneWidget);
  });

  testWidgets('a host folder is re-validated by the host on entry',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.validateRemoteDirectory(
          any(),
          mustExist: any(named: 'mustExist'),
          mustBeWritable: any(named: 'mustBeWritable'),
        )).thenAnswer(
      (_) async => const {'valid': false, 'error': 'Read-only filesystem'},
    );
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => _PinnedBackendNotifier(ref, backend),
        ),
        onboardingDraftProvider.overrideWith(
          (ref) => _SeededOnboardingNotifier(ref, '/srv/captures'),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    verify(() => backend.validateRemoteDirectory(
          '/srv/captures',
          mustExist: true,
          mustBeWritable: true,
        )).called(1);
    expect(find.text('Folder is writable.'), findsNothing);
    expect(find.text('Read-only filesystem'), findsOneWidget);
  });

  testWidgets(
      'dropping the host connection retracts the claim instead of keeping it',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(() => backend.validateRemoteDirectory(
          any(),
          mustExist: any(named: 'mustExist'),
          mustBeWritable: any(named: 'mustBeWritable'),
        )).thenAnswer(
      (_) async => const {'valid': true, 'normalizedPath': '/srv/captures'},
    );
    late _SwitchingBackendNotifier notifier;
    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        backendProvider.overrideWith(
          (ref) => notifier = _SwitchingBackendNotifier(ref, backend),
        ),
        onboardingDraftProvider.overrideWith(
          (ref) => _SeededOnboardingNotifier(ref, '/srv/captures'),
        ),
        // The local probe must never be consulted for a host path — if the step
        // fell through to it, this would fail the test loudly.
        onboardingCaptureDirectoryValidatorProvider.overrideWithValue(
          (path) async => throw StateError('local probe ran for a host path'),
        ),
      ],
    );
    addTearDown(container.dispose);
    container.read(backendProvider);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();
    expect(find.text('Folder is writable.'), findsOneWidget);

    // Host gone: the same path now means a folder on this machine, and the
    // wizard has no basis for the earlier verdict.
    notifier.replaceWith(FfiBackend());
    await tester.pumpAndSettle();

    expect(find.text('Folder is writable.'), findsNothing);
    expect(
      find.textContaining('has not confirmed it is writable'),
      findsOneWidget,
    );
  });
}
