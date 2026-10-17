// The AstroBin acquisition CSV must carry the night the subs were shot.
//
// AstroBin requires a date on every acquisition row, and the export sources it
// from the imaging session's start time so restacking old data does not stamp
// it with today. That lookup runs on the export tap, so it has to actually
// resolve the session list rather than read a stream provider that has not
// emitted yet — a synchronous `.valueOrNull` on a cold provider is null, and
// the fallback is the run's own timestamp, i.e. today.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/screens/stack_result/stack_result_screen.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import '../harness/mock_database.dart' show inMemoryDatabaseOverride;
import '../harness/provider_teardown.dart';

const _sessionId = 42;

/// A fake orchestrator notifier holding a finished run, so the viewer renders
/// from an in-memory buffer instead of the native re-stretch.
class _FakeStackAndShareNotifier extends StackAndShareNotifier {
  _FakeStackAndShareNotifier(super.ref, StackAndShareState initial) {
    state = initial;
  }

  @override
  Future<void> runForSession(int sessionId,
      {StackAndShareConfig? config}) async {}
}

/// Stacked TODAY from subs shot on the night of 2026-05-28.
StackAndShareResult _restack() => StackAndShareResult(
      id: 7,
      sessionId: _sessionId,
      targetName: 'M51',
      width: 2,
      height: 2,
      framesStacked: 18,
      framesAttempted: 18,
      integrationSecs: 5400,
      avgAlignmentResidual: 0.42,
      filter: 'L',
      createdAt: DateTime(2026, 8, 9, 14),
      stats: const LiveStackingStats(stackedFrameCount: 18),
    );

ImagingSession _session() => ImagingSession(
      id: _sessionId,
      name: 'M51',
      startTime: DateTime(2026, 5, 28, 22, 10),
      totalExposures: 18,
      successfulExposures: 18,
      failedExposures: 0,
      totalIntegrationSecs: 5400,
      autofocusCount: 0,
      status: 'completed',
    );

Uint8List _rgba2x2() {
  final out = Uint8List(2 * 2 * 4);
  for (var i = 0; i < out.length; i += 4) {
    out[i] = 128;
    out[i + 1] = 128;
    out[i + 2] = 128;
    out[i + 3] = 255;
  }
  return out;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('astrobin_date_test');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  testWidgets('the CSV carries the session night, not the restack day',
      (tester) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1400, 1000);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final result = _restack();
    final csvPath = '${tempDir.path}/m51-astrobin.csv';
    var pickedExtensions = const <String>[];
    var suggestedName = '';

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          // Emits on a microtask, exactly like drift's watchAllSessions: a
          // synchronous read at tap time sees AsyncLoading.
          allSessionsProvider.overrideWith((ref) => Stream.value([_session()])),
          stackResultViewerProvider(result.id!)
              .overrideWith((ref) async => result),
          stackAndShareProvider.overrideWith(
            (ref) => _FakeStackAndShareNotifier(
              ref,
              StackAndShareState(
                progress: const StackAndShareProgress(
                  phase: StackAndSharePhase.complete,
                ),
                result: result,
                resultRgba: _rgba2x2(),
                resultWidth: result.width,
                resultHeight: result.height,
              ),
            ),
          ),
          stackResultSavePickerProvider.overrideWithValue((
              {required String dialogTitle,
              required String fileName,
              required List<String> allowedExtensions}) async {
            pickedExtensions = allowedExtensions;
            suggestedName = fileName;
            return csvPath;
          }),
          stackResultShareProvider.overrideWithValue(
              (String path, {required String text}) async {}),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: StackResultScreen(resultId: result.id!),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Exports live behind the header's single overflow menu now (05 §5), so
    // the tap is two steps: open it, then pick the row.
    await tester.tap(find.byKey(const ValueKey('stack_result_export_menu')));
    // Explicit pumps, not pumpAndSettle: this screen keeps a live preview
    // ticking, so settling never arrives (the pumps above are here for the
    // same reason).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('AstroBin'));
    await tester.pump();
    // The export writes real files, and dart:io futures only complete outside
    // the fake-async zone; each write needs its own turn of the real loop.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pump();
    }

    expect(
      suggestedName,
      endsWith('.csv'),
      reason: 'the importable format is the suggested one',
    );
    expect(pickedExtensions, contains('csv'));

    final rows = File(csvPath).readAsLinesSync();
    expect(rows.first, 'date,number,duration');
    expect(
      rows[1],
      startsWith('2026-05-28'),
      reason: 'the acquisition night, not the day the restack ran',
    );
    expect(rows[1], '2026-05-28,18,300');

    await settleProviderTeardown(tester);
  });
}
