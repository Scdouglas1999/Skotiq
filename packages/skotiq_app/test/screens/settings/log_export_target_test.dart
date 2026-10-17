// Settings › Logs › Export must offer a picker, a scope choice and a size
// notice. Writing straight to the ROOT of the user's Documents folder turns a
// support request for "the log" into an 18.8 MB file of every rotated log the
// machine has kept, dropped next to the operator's personal documents rather
// than in the `exports/` directory every other in-app export uses.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/log_viewer.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockLoggingService extends Mock implements LoggingService {}

class _MockLocalBackend extends Mock implements SkotiqBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

late Directory _tempDir;

/// Two entries the viewer is showing, and one big rotated file it is not.
List<LogEntry> _visibleEntries() => [
      LogEntry(
        timestamp: DateTime.utc(2026, 8, 3, 21, 0),
        level: LogLevel.info,
        message: 'on-screen entry one',
        source: 'Test',
      ),
      LogEntry(
        timestamp: DateTime.utc(2026, 8, 3, 21, 1),
        level: LogLevel.warning,
        message: 'on-screen entry two',
        source: 'Test',
      ),
    ];

Future<({_MockLoggingService logging, String targetPath})> _pump(
  WidgetTester tester, {
  bool cancelPicker = false,
  bool logFilesUnreadable = false,
}) async {
  final logging = _MockLoggingService();
  when(logging.getRecentLogs).thenReturn(_visibleEntries());

  // One rotated file on disk, far bigger than what the viewer shows. Written
  // synchronously: the test body runs inside fake async, where an awaited
  // dart:io future would never complete.
  final rotated = File('${_tempDir.path}/skotiq.log.2026-07-28');
  rotated.writeAsStringSync('x' * 4096);
  when(() => logging.getLogFiles()).thenAnswer((_) async {
    if (logFilesUnreadable) {
      throw const FileSystemException('cannot list the log directory');
    }
    return [rotated.path];
  });

  final targetPath = '${_tempDir.path}/exported_logs.txt';
  when(() => logging.exportLogs(any())).thenAnswer((invocation) async {
    final path = invocation.positionalArguments.first as String;
    File(path).writeAsStringSync('=== full history ===\n');
    return path;
  });

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, _MockLocalBackend()),
        ),
        loggingServiceProvider.overrideWithValue(logging),
        logExportTargetPickerProvider.overrideWithValue(
          (suggestedName) async => cancelPicker
              ? null
              : ExportTarget(path: targetPath, needsShareSheet: false),
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: const Scaffold(body: LogViewer(isMobile: true)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return (logging: logging, targetPath: targetPath);
}

/// The viewer live-tails at 1 Hz, so its tree never goes quiet and
/// `pumpAndSettle` would spin until its own timeout. Pump explicitly, and let
/// the real event loop run so the export's dart:io futures can complete.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 30)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _tapExport(WidgetTester tester) async {
  final export = find.widgetWithText(SkotiqButton, 'Export');
  await tester.ensureVisible(export);
  await tester.tap(export);
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _tempDir = Directory.systemTemp.createTempSync('sk_log_export_test');
  });

  tearDown(() {
    if (_tempDir.existsSync()) _tempDir.deleteSync(recursive: true);
  });

  testWidgets('Export asks what it should contain, and how big that is',
      (tester) async {
    await _pump(tester);
    await _tapExport(tester);

    expect(find.text('Export logs'), findsOneWidget);
    expect(find.text('Entries on screen'), findsOneWidget);
    expect(find.text('2 entries, exactly as filtered'), findsOneWidget);
    expect(
      find.textContaining('Every retained log file — about 4.0 KB'),
      findsOneWidget,
      reason: 'the full-history size must be stated before it is written',
    );
  });

  testWidgets('an unreadable log directory is said so, not reported as 0 bytes',
      (tester) async {
    // Nothing was measured when the retained set cannot even be enumerated.
    // "about 0 B" would read as "there is no history to export", which is the
    // opposite of what an unreadable log directory means.
    await _pump(tester, logFilesUnreadable: true);
    await _tapExport(tester);

    expect(find.text('Export logs'), findsOneWidget);
    expect(
      find.textContaining('Every retained log file — size could not be read'),
      findsOneWidget,
    );
    expect(find.textContaining('about 0'), findsNothing);
  });

  testWidgets('the on-screen scope writes only what the viewer shows',
      (tester) async {
    final handles = await _pump(tester);
    await _tapExport(tester);
    await tester.tap(find.text('Entries on screen'));
    await _settle(tester);

    final written = File(handles.targetPath);
    expect(written.existsSync(), isTrue,
        reason: 'the export must land on the chosen path');
    final content = written.readAsStringSync();
    expect(content, contains('on-screen entry one'));
    expect(content, contains('Entries: 2'));
    verifyNever(() => handles.logging.exportLogs(any()));
  });

  testWidgets('the full-history scope is what dumps every rotated file',
      (tester) async {
    final handles = await _pump(tester);
    await _tapExport(tester);
    await tester.tap(find.text('Full history'));
    await _settle(tester);

    verify(() => handles.logging.exportLogs(handles.targetPath)).called(1);
  });

  testWidgets('cancelling the destination writes nothing', (tester) async {
    final handles = await _pump(tester, cancelPicker: true);
    await _tapExport(tester);
    await tester.tap(find.text('Full history'));
    await _settle(tester);

    verifyNever(() => handles.logging.exportLogs(any()));
    expect(File(handles.targetPath).existsSync(), isFalse);
  });
}
