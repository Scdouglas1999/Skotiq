// Where "Create dump" opens its save dialog.
//
// `chooseExportTarget` with no `initialDirectory` hands `file_selector` a null
// it forwards straight through, so the platform picker starts at the process
// working directory — inside the running application bundle
// (`…/build/linux/x64/release/bundle`, `C:\Program Files\…`). In an installed
// build that folder is read-only, so the first thing a user filing a bug report
// sees is somewhere they cannot save.
//
// The test drives the real screen and inspects what reached the file_selector
// platform channel, so dropping the argument at the call site fails it.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/diagnostics/diagnostic_dump_screen.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

void main() {
  late Directory root;
  late Directory downloads;
  late Directory documents;
  Map<Object?, Object?>? saveDialogArguments;

  setUp(() {
    root = Directory.systemTemp.createTempSync('sk-dump-save-');
    downloads = Directory('${root.path}/Downloads')..createSync();
    documents = Directory('${root.path}/Documents')..createSync();
    saveDialogArguments = null;

    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
      switch (call.method) {
        case 'getDownloadsDirectory':
          return downloads.path;
        case 'getApplicationDocumentsDirectory':
          return documents.path;
        default:
          return root.path;
      }
    });

    const fileSelector = MethodChannel('plugins.flutter.io/file_selector');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(fileSelector, (call) async {
      if (call.method == 'getSavePath') {
        saveDialogArguments = call.arguments as Map<Object?, Object?>;
      }
      // Null = the user backed out, which keeps the test clear of the real
      // file I/O the dump itself would perform.
      return null;
    });
  });

  tearDown(() {
    for (final name in const [
      'plugins.flutter.io/path_provider',
      'plugins.flutter.io/file_selector',
    ]) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), null);
    }
    root.deleteSync(recursive: true);
  });

  testWidgets('the save dialog opens somewhere the user can write',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [],
        child: MaterialApp(
          home: Scaffold(body: DiagnosticDumpScreen()),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Create dump'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      saveDialogArguments,
      isNotNull,
      reason: 'the save dialog should have been asked for',
    );
    // Documents, not Downloads: under `flutter test` path_provider falls back
    // to its method-channel implementation, whose getDownloadsPath is macOS-
    // only and throws, so the second choice wins here. The ordering itself is
    // covered by the injected-resolver cases below; what matters at this level
    // is that a real, user-writable folder reached the picker at all.
    expect(
      saveDialogArguments!['initialDirectory'],
      isNotNull,
      reason: 'null lets the picker open in the read-only app bundle',
    );
    expect(saveDialogArguments!['initialDirectory'], documents.path);
  });

  test('Documents stands in when the platform has no Downloads folder',
      () async {
    expect(
      await resolveDumpSaveDirectory(
        downloadsDirectory: () async => null,
        documentsDirectory: () async => documents,
      ),
      documents.path,
    );
  });

  test('an unsupported platform is not treated as a failure', () async {
    expect(
      await resolveDumpSaveDirectory(
        downloadsDirectory: () async => throw UnsupportedError('mobile'),
        documentsDirectory: () async => documents,
      ),
      documents.path,
    );
  });

  test('a directory that does not exist is not offered', () async {
    expect(
      await resolveDumpSaveDirectory(
        downloadsDirectory: () async => Directory('${root.path}/nope'),
        documentsDirectory: () async => documents,
      ),
      documents.path,
    );
  });
}
