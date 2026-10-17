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

void main() {
  testWidgets('remote onboarding browses and validates the host filesystem',
      (tester) async {
    final database = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final backend = _MockNetworkBackend();
    when(() => backend.browseRemoteDirectories(path: any(named: 'path')))
        .thenAnswer(
      (_) async => const RemoteDirectoryListing(
        currentPath: '/host/captures',
        parentPath: null,
        directories: [],
      ),
    );
    when(
      () => backend.validateRemoteDirectory(
        '/host/captures',
        mustExist: true,
        mustBeWritable: true,
      ),
    ).thenAnswer(
      (_) async => const {
        'valid': true,
        'normalizedPath': '/host/captures',
      },
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(database),
          backendProvider.overrideWith(
            (ref) => _PinnedBackendNotifier(ref, backend),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(body: OnboardingCaptureDirStep()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Browse'));
    await tester.pumpAndSettle();
    expect(find.text('Choose capture folder on host'), findsOneWidget);

    await tester.tap(find.text('Use this folder'));
    await tester.pumpAndSettle();

    expect(find.text('/host/captures'), findsOneWidget);
    verify(() => backend.browseRemoteDirectories(path: null)).called(1);
    verify(
      () => backend.validateRemoteDirectory(
        '/host/captures',
        mustExist: true,
        mustBeWritable: true,
      ),
    ).called(1);
  });
}
