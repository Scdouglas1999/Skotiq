// A first run starts with a capture folder already chosen and checked.
//
// Walk-2 F7: the capture-folder step opened on an empty box and Next said
// "Pick a capture folder." NINA and ASIAIR start from a folder of their own.
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/services/host_folders.dart';
import 'package:skotiq_app/screens/onboarding/steps/capture_dir_step.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/providers.dart';

import '../../harness/fake_host_folders.dart';

const _suggested = '/home/astro/Pictures/Skotiq';

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  String? storedFolder,
}) async {
  final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      onboardingDefaultCaptureDirectoryProvider
          .overrideWithValue(() async => _suggested),
      hostFoldersProvider.overrideWithValue(FakeHostFolders(
          onCheck: folderCheckFrom(
        (path) async => null,
      ))),
    ],
  );
  addTearDown(container.dispose);
  final notifier = container.read(onboardingDraftProvider.notifier);
  await notifier.loaded;
  if (storedFolder != null) await notifier.setCaptureDirectory(storedFolder);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: OnboardingCaptureDirStep()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('an empty step fills in the suggested folder, checked',
      (tester) async {
    final container = await _pump(tester);

    expect(
      container.read(onboardingDraftProvider).captureDirectory,
      _suggested,
    );
    expect(find.text(_suggested), findsOneWidget);
    expect(find.text('Folder is writable.'), findsOneWidget);
  });

  testWidgets('a folder the user already chose is kept', (tester) async {
    final container = await _pump(tester, storedFolder: '/mnt/nvme/astro');

    expect(
      container.read(onboardingDraftProvider).captureDirectory,
      '/mnt/nvme/astro',
    );
  });

  test('the folder is made inside the pictures folder the system names',
      () async {
    final home = await Directory.systemTemp.createTemp('skotiq-home');
    addTearDown(() => home.delete(recursive: true));
    await Directory('${home.path}/.config').create();
    await Directory('${home.path}/Bilder').create();
    await File('${home.path}/.config/user-dirs.dirs')
        .writeAsString('XDG_PICTURES_DIR="\$HOME/Bilder"\n');

    final made = await makeCaptureDirectoryIn(
      home.path,
      configDir: '${home.path}/.config',
    );

    expect(made, '${home.path}/Bilder/Skotiq');
    expect(Directory(made).existsSync(), isTrue);
  });

  test('without a pictures folder the folder goes in the home folder',
      () async {
    final home = await Directory.systemTemp.createTemp('skotiq-home');
    addTearDown(() => home.delete(recursive: true));

    final made = await makeCaptureDirectoryIn(home.path);

    expect(made, '${home.path}/Skotiq');
    expect(Directory(made).existsSync(), isTrue);
  });
}
