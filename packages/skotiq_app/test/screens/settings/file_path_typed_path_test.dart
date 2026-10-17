// The storage path boxes must accept the path you type into them.
//
// Live: Settings > Files & Storage renders "Image output" and "Sequences" as
// bordered, filled boxes with a muted "Not set" placeholder and a folder
// button beside them. Clicking in and typing "/tmp/lights" then pressing Enter
// did nothing at all — the box was a Text — and image_output_path stayed empty.
// The only way in was the directory picker, which cannot reach a share that is
// not mounted yet and, from a tablet, cannot reach the imaging host's disk.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/file_path_settings.dart';
import 'package:skotiq_app/screens/settings/widgets/settings_widgets.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../harness/harness.dart';

class _LoadedAppSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState(
        imageOutputPath: '/images',
        sequencesPath: '/sequences',
      );
}

Future<HarnessHandle> _pump(
  WidgetTester tester, {
  String? probeFailure,
  List<(String, String)>? reveals,
}) async {
  final handle = await pumpAppScreen(
    tester,
    const FilePathSettings(embedded: true),
    size: const Size(1280, 1000),
    settle: false,
    extraOverrides: [
      appSettingsProvider.overrideWith(_LoadedAppSettings.new),
      backupDirectoryPathProvider.overrideWith((ref) async => '/backups'),
      backupDirectoryOverrideProvider.overrideWith((ref) async => null),
      applicationDataPathProvider.overrideWith((ref) async => '/appdata'),
      applicationLogPathProvider.overrideWith((ref) async => '/support/logs'),
      storageDirectoryProbeProvider
          .overrideWithValue((path) async => probeFailure),
      if (reveals != null)
        appDataFolderRevealerProvider.overrideWithValue(
          (context, path) async => reveals.add(('reveal', path)),
        ),
    ],
  );
  await tester.pump();
  await tester.pump();
  return handle;
}

/// The text field inside the Image output row.
Finder _imageField() => find.descendant(
      of: find.byType(SettingsPathInput).first,
      matching: find.byType(TextField),
    );

/// The text field inside the Sequences row — the second path input.
Finder _sequencesField() => find.descendant(
      of: find.byType(SettingsPathInput).at(1),
      matching: find.byType(TextField),
    );

Future<void> _type(WidgetTester tester, Finder field, String text) async {
  await tester.ensureVisible(field);
  await tester.pump();
  await tester.enterText(field, text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

String _imagePath(HarnessHandle handle) =>
    handle.container.read(appSettingsProvider).value!.imageOutputPath;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a typed image output path is stored', (tester) async {
    final handle = await _pump(tester);

    await _type(tester, _imageField(), '/mnt/nas/lights');

    expect(_imagePath(handle), '/mnt/nas/lights');
    expect(find.textContaining('Image output set to /mnt/nas/lights'),
        findsOneWidget);
  });

  // The box commits on Enter AND on focus loss — tabbing away is how people
  // leave a path box. Enter is covered above; without this case, wiring only
  // onSubmitted would look complete while the operator who types a path and
  // clicks the next field loses it silently.
  testWidgets('leaving the field commits the typed path', (tester) async {
    final handle = await _pump(tester);

    final field = _imageField();
    await tester.ensureVisible(field);
    await tester.pump();
    await tester.enterText(field, '/mnt/nas/tabbed');
    // No Enter. Move focus to the next path box, as tabbing or clicking away
    // would.
    await tester.tap(_sequencesField());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(_imagePath(handle), '/mnt/nas/tabbed');
  });

  testWidgets('a relative path is refused, not stored', (tester) async {
    final handle = await _pump(tester);

    await _type(tester, _imageField(), 'lights');

    expect(_imagePath(handle), '/images');
    expect(find.textContaining('Enter a full path'), findsOneWidget);
    // The box goes back to what is actually stored rather than showing a
    // value the app did not accept.
    expect(tester.widget<TextField>(_imageField()).controller!.text, '/images');
  });

  testWidgets('a folder this machine cannot reach is confirmed first',
      (tester) async {
    final handle = await _pump(
      tester,
      probeFailure: 'FileSystemException: Read-only file system',
    );

    await _type(tester, _imageField(), '/mnt/unmounted/lights');

    expect(find.text('Use a folder this machine cannot open?'), findsOneWidget);
    expect(_imagePath(handle), '/images', reason: 'not stored while asking');

    await tester.tap(find.text('Store anyway'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(_imagePath(handle), '/mnt/unmounted/lights');
  });

  testWidgets('cancelling that question keeps the old path', (tester) async {
    final handle = await _pump(tester, probeFailure: 'No such file');

    await _type(tester, _imageField(), '/mnt/typo');
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(_imagePath(handle), '/images');
  });

  testWidgets('the application data folder is named and reachable',
      (tester) async {
    final reveals = <(String, String)>[];
    await _pump(tester, reveals: reveals);

    expect(find.text('Database and logs'), findsOneWidget);
    expect(find.textContaining('/appdata'), findsOneWidget);
    expect(
      find.textContaining('Managed automatically'),
      findsNothing,
      reason: 'the page used to refuse to say where the folder is',
    );

    // The Backups row below offers the same button, so scope to this row.
    final open = find.descendant(
      of: find.ancestor(
        of: find.text('Database and logs'),
        matching: find.byType(SettingRow),
      ),
      matching: find.text('Open folder'),
    );
    await tester.ensureVisible(open);
    await tester.pump();
    await tester.tap(open);
    await tester.pump();

    expect(reveals, [('reveal', '/appdata')]);
  });

  // The row is titled "Database and logs" and told the operator this folder is
  // "what to attach to a bug report" — but the logs are not in it. The database
  // resolves under the documents directory (resolveDefaultDatabaseFile) while
  // LoggingService writes <application-support>/logs
  // (resolveSkotiqDataDirectory). Naming one folder and claiming the other
  // is inside it produces a bug report with no logs attached.
  testWidgets('the logs folder is named separately and can be opened',
      (tester) async {
    final reveals = <(String, String)>[];
    await _pump(tester, reveals: reveals);

    final row = find.ancestor(
      of: find.text('Database and logs'),
      matching: find.byType(SettingRow),
    );

    expect(
      find.descendant(of: row, matching: find.textContaining('/support/logs')),
      findsOneWidget,
      reason: 'the logs live somewhere else and must be named',
    );
    expect(
      find.descendant(
        of: row,
        matching: find.textContaining('the logs folder,'),
      ),
      findsNothing,
      reason: 'the database folder does not contain the logs folder',
    );

    final openLogs = find.descendant(of: row, matching: find.text('Open logs'));
    await tester.ensureVisible(openLogs);
    await tester.pump();
    await tester.tap(openLogs);
    await tester.pump();

    expect(reveals, [('reveal', '/support/logs')]);
  });
}
