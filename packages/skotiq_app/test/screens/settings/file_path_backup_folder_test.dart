// Files & Storage must name the folder it silently backs up to and prunes.
//
// Live: "Enable automatic backups" defaults ON at a 24 h interval with
// "Maximum backups 7", and the page listed only Image output, Sequences and
// "Managed automatically in Skotiq's application data folder". Nothing
// anywhere named the directory the bundles were written to — while the
// retention setting DELETED the oldest bundles out of it.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/settings/widgets/file_path_settings.dart';
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
  required Future<String> Function() path,
  List<(String, String)>? reveals,
  Future<String?> Function()? override,
  String? picks,
  List<String?>? moves,
}) async {
  final handle = await pumpAppScreen(
    tester,
    const FilePathSettings(embedded: true),
    settle: false,
    extraOverrides: [
      appSettingsProvider.overrideWith(_LoadedAppSettings.new),
      backupDirectoryPathProvider.overrideWith((ref) => path()),
      if (override != null)
        backupDirectoryOverrideProvider.overrideWith((ref) => override()),
      if (moves != null)
        backupDirectoryWriterProvider.overrideWithValue((p) async {
          moves.add(p);
        }),
      filePathSettingsPickerProvider.overrideWithValue(
        (context, {required isRemote, required currentPath}) async => picks,
      ),
      if (reveals != null)
        backupFolderRevealerProvider.overrideWithValue(
          (context, p) async => reveals.add(('reveal', p)),
        ),
    ],
  );
  await tester.pump();
  await tester.pump();
  return handle;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the backup folder is named on the page', (tester) async {
    await _pump(tester, path: () async => '/data/skotiq/backups');

    expect(find.text('Backups'), findsOneWidget);
    expect(
      find.textContaining('/data/skotiq/backups'),
      findsOneWidget,
      reason: 'the folder backups are written to must be visible',
    );
  });

  testWidgets('the row says retention deletes from that folder',
      (tester) async {
    await _pump(tester, path: () async => '/data/skotiq/backups');

    expect(
      find.textContaining(
          'backups” deletes the oldest bundles from this folder'),
      findsOneWidget,
    );
  });

  testWidgets('the folder can be opened from the row', (tester) async {
    final reveals = <(String, String)>[];
    await _pump(
      tester,
      path: () async => '/data/skotiq/backups',
      reveals: reveals,
    );

    await tester.tap(find.text('Open folder'));
    await tester.pump();

    expect(reveals, [('reveal', '/data/skotiq/backups')]);
  });

  testWidgets('an unresolvable folder still states the retention policy',
      (tester) async {
    await _pump(tester, path: () async => throw StateError('no documents dir'));

    expect(find.textContaining('Could not resolve the backup folder'),
        findsOneWidget);
    expect(
      find.textContaining(
          'backups” deletes the oldest bundles from this folder'),
      findsOneWidget,
    );
    // Nothing to open, so no button that would fail on tap.
    expect(find.text('Open folder'), findsNothing);
  });

  testWidgets('the folder can be moved from the page', (tester) async {
    final moves = <String?>[];
    await _pump(
      tester,
      path: () async => '/data/skotiq/backups',
      picks: '/mnt/archive/skotiq',
      moves: moves,
    );

    await tester.tap(find.text('Change…'));
    await tester.pumpAndSettle();

    expect(
      moves,
      ['/mnt/archive/skotiq'],
      reason: 'the chosen folder must reach the service that writes backups',
    );
  });

  testWidgets('cancelling the picker leaves the folder alone', (tester) async {
    final moves = <String?>[];
    await _pump(
      tester,
      path: () async => '/data/skotiq/backups',
      picks: null,
      moves: moves,
    );

    await tester.tap(find.text('Change…'));
    await tester.pumpAndSettle();

    expect(moves, isEmpty);
  });

  testWidgets('a moved folder is not described as beside the database', (
    tester,
  ) async {
    await _pump(
      tester,
      path: () async => '/mnt/archive/skotiq',
      override: () async => '/mnt/archive/skotiq',
    );

    expect(find.textContaining('/mnt/archive/skotiq'), findsOneWidget);
    expect(
      find.textContaining('beside the database'),
      findsNothing,
      reason: 'the folder is on another drive; saying otherwise is untrue',
    );
    expect(
      find.textContaining(
          'backups” deletes the oldest bundles from this folder'),
      findsOneWidget,
    );
  });

  testWidgets('a moved folder can be handed back to the default', (
    tester,
  ) async {
    final moves = <String?>[];
    await _pump(
      tester,
      path: () async => '/mnt/archive/skotiq',
      override: () async => '/mnt/archive/skotiq',
      moves: moves,
    );

    await tester.tap(find.text('Use default'));
    await tester.pumpAndSettle();

    expect(moves, [null]);
  });

  testWidgets('the default folder offers nothing to reset', (tester) async {
    await _pump(
      tester,
      path: () async => '/data/skotiq/backups',
      override: () async => null,
    );

    expect(find.text('Use default'), findsNothing);
    expect(find.text('Change…'), findsOneWidget);
  });
}
