// Correcting a rejected capture folder must clear the rejection.
//
// Computing the verdict on submit/focus-loss only leaves onboarding step 10
// saying "That folder does not exist." under a path the user has already
// replaced with a real one: retyping — the natural recovery — never re-runs the
// validator, and Next stays dead. Back-then-Next remounts the step and accepts
// the very same text, which shows the check is right and only its result is
// stale.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/capture_dir_step.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _TestOnboardingNotifier extends OnboardingNotifier {
  _TestOnboardingNotifier(super.ref);
}

class _Writer {
  final written = <String>[];
}

ProviderContainer _container({
  required _Writer writer,
  required Set<String> writableFolders,
  required SkotiqDatabase db,
}) {
  return ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      onboardingDraftProvider.overrideWith(_TestOnboardingNotifier.new),
      onboardingCaptureDirectoryPickerProvider.overrideWithValue(
        (context, {required isRemote, required initialPath}) async => null,
      ),
      onboardingCaptureDirectoryValidatorProvider.overrideWithValue(
        (path) async => writableFolders.contains(path)
            ? null
            : 'That folder does not exist.',
      ),
      onboardingCaptureDirectoryWriterProvider.overrideWith((ref) {
        return (path) async {
          writer.written.add(path);
          await ref
              .read(onboardingDraftProvider.notifier)
              .setCaptureDirectory(path);
        };
      }),
    ],
  );
}

Widget _surface(ProviderContainer container) {
  return UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(
      home: Scaffold(body: OnboardingCaptureDirStep()),
    ),
  );
}

void main() {
  testWidgets('retyping a good path clears the rejection and commits it',
      (tester) async {
    final writer = _Writer();
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container =
        _container(writer: writer, writableFolders: {'/tmp'}, db: db);
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(onboardingCaptureDirFieldKey),
      '/tmp/does-not-exist',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('That folder does not exist.'), findsOneWidget);

    // The recovery a user actually performs: select all, type a real folder,
    // and expect the field to answer for what it now contains.
    await tester.enterText(find.byKey(onboardingCaptureDirFieldKey), '/tmp');
    await tester.pump();
    expect(
      find.text('That folder does not exist.'),
      findsNothing,
      reason: 'the rejection describes text that is no longer in the box',
    );

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(writer.written, ['/tmp']);
    expect(find.text('Folder is writable.'), findsOneWidget);
  });

  testWidgets('an edit away from an accepted folder drops the green tick',
      (tester) async {
    final writer = _Writer();
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container =
        _container(writer: writer, writableFolders: {'/srv/captures'}, db: db);
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(onboardingCaptureDirFieldKey),
      '/srv/captures',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('Folder is writable.'), findsOneWidget);

    await tester.enterText(
      find.byKey(onboardingCaptureDirFieldKey),
      '/srv/captures-typo',
    );
    await tester.pump();
    expect(find.text('Folder is writable.'), findsNothing);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.text('That folder does not exist.'), findsOneWidget);
    expect(writer.written, ['/srv/captures']);
  });
}
