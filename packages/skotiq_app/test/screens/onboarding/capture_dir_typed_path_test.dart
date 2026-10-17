// The onboarding capture-folder step must accept a path you already know.
//
// Live finding: step 10 showed "No folder selected yet" beside a single Browse
// button that opens the native GTK chooser. There was no way to type or paste a
// path — which is the fast route when you already know it, and the only sane
// route on an appliance driven over VNC or a small screen. Settings → Files &
// Storage accepts a typed path for this same setting (image_output_path); the
// wizard that sets it first refused to.
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/onboarding/steps/capture_dir_step.dart';
import 'package:skotiq_core/skotiq_core.dart';

class _TestOnboardingNotifier extends OnboardingNotifier {
  _TestOnboardingNotifier(super.ref);
}

/// Records what the step decided to store, so a rejected path is visibly
/// distinct from an accepted one.
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
      // The draft persists itself on every commit; give it a real schema so
      // the write is exercised rather than warned about.
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
      // Wrap the real writer so the draft actually moves — the step only shows
      // its "writable" verdict for the folder the DRAFT holds, which is what
      // stops a stale green tick surviving a changed path.
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
  testWidgets('a typed folder that checks out becomes the capture directory',
      (tester) async {
    final writer = _Writer();
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = _container(
      writer: writer,
      writableFolders: {'/mnt/nvme/astro'},
      db: db,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(onboardingCaptureDirFieldKey),
      '/mnt/nvme/astro',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(writer.written, ['/mnt/nvme/astro']);
    expect(find.text('Folder is writable.'), findsOneWidget);
  });

  testWidgets('a typed folder that fails the check is not stored',
      (tester) async {
    final writer = _Writer();
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container =
        _container(writer: writer, writableFolders: const {}, db: db);
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(onboardingCaptureDirFieldKey),
      '/mnt/typo',
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(writer.written, isEmpty,
        reason: 'a typo must not become the answer that unblocks Next');
    expect(find.text('That folder does not exist.'), findsOneWidget);
    // Left in the box so it can be corrected rather than retyped.
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(onboardingCaptureDirFieldKey),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      '/mnt/typo',
    );
  });

  testWidgets('leaving the field commits it, not just Enter', (tester) async {
    // Tabbing away is how people leave a path box, so dropping the edit there
    // loses it silently.
    final writer = _Writer();
    final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = _container(
      writer: writer,
      writableFolders: {'/srv/captures'},
      db: db,
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(_surface(container));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(onboardingCaptureDirFieldKey),
      '/srv/captures',
    );
    // Drop focus without submitting.
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();

    expect(writer.written, ['/srv/captures']);
  });
}
