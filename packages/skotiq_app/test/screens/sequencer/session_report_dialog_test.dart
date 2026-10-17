// Smoke tests for the Feature-A session report dialog.
//
// We avoid spinning up the full backend / FFI stack by overriding the
// `sessionReportProvider.family` with a pre-built fake report. The dialog
// only reads from that provider, so this exercises the rendering path and
// the Markdown-copy action without touching any IO.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/sequencer/widgets/session_report_dialog.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

SessionReport _fakeReport({
  String name = 'M42 night 1',
  String status = 'completed',
  List<SessionTargetReport>? targets,
  List<String> errors = const [],
  List<String> warnings = const [],
  String? terminalCause,
  String? rejectFolder,
}) {
  final t = targets ??
      [
        const SessionTargetReport(
          targetId: 1,
          targetName: 'M42',
          filters: [
            SessionFilterReport(
              filter: 'L',
              framesAttempted: 12,
              framesAccepted: 10,
              framesRejected: 2,
              totalIntegrationSecs: 600,
              meanHfr: 2.4,
              meanFwhm: 2.4 * 2.35,
              meanStarCount: 480,
              meanSnr: 21.5,
              meanGuidingRmsTotal: 0.62,
              meanSensorTemp: -10,
              rejectionReasons: {'High HFR': 2},
            ),
          ],
        ),
      ];
  return SessionReport(
    sessionId: 42,
    sessionName: name,
    status: status,
    startTime: DateTime.utc(2026, 1, 1, 22),
    endTime: DateTime.utc(2026, 1, 2, 1),
    wallClockDuration: const Duration(hours: 3),
    totalIntegration: const Duration(minutes: 10),
    effectiveImagingFraction: 10 / 180,
    downtime: const Duration(hours: 2, minutes: 50),
    targets: t,
    guideStats: const SessionGuideStats(
      meanRmsRaArcsec: 0.5,
      meanRmsDecArcsec: 0.4,
      meanRmsTotalArcsec: 0.6,
      maxRmsRaArcsec: 0.9,
      maxRmsDecArcsec: 0.7,
      maxRmsTotalArcsec: 1.1,
      percentUnguidedFrames: 0.0,
    ),
    mountStats: const SessionMountStats(
      autofocusRuns: 2,
      meridianFlips: 1,
      ditherCount: 9,
      triggerFires: 1,
    ),
    avgTemperatureC: 5.0,
    avgHumidityPercent: 60.0,
    avgSeeingArcsec: 2.0,
    notes: null,
    errorMessages: errors,
    warningMessages: warnings,
    terminalCause: terminalCause,
    rejectFolder: rejectFolder,
    generatedAt: DateTime.utc(2026, 1, 2, 2),
  );
}

/// Test-only stand-ins for the auxiliary providers `SessionReportDialog`
/// watches. The real implementations chain into `databaseProvider` /
/// `backendProvider`, which spin up Drift query streams and (in the case
/// of `appSettingsProvider`) recurring backend event subscriptions —
/// `pumpAndSettle` then never reaches steady state and times out.
/// Providing inert overrides matches the spirit of the original test
/// (smoke-test the dialog's rendering, not its provider graph).
class _FakeAppSettingsNotifierForReport extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async => const AppSettingsState();
}

class _FailingAppSettingsNotifierForReport extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async {
    throw StateError('settings unavailable');
  }
}

Future<void> _pump(
  WidgetTester tester,
  SessionReport report, {
  SkotiqBackend? backend,
  bool failAuxiliary = false,
}) async {
  // Build the override list inside the function so it can include
  // family-keyed providers that depend on the report's session id /
  // primary target. Without `notesForTargetProvider` override the
  // dialog's journal section watches a Drift `Stream` whose underlying
  // periodic notifier ticks forever, so `pumpAndSettle` never reaches
  // steady state. Same rationale for the analytics/insights family
  // providers — give them inert resolved values.
  final primaryTarget = report.targets.isNotEmpty
      ? report.targets.first.targetName
      : report.sessionName;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        if (backend != null)
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
        sessionReportProvider(report.sessionId).overrideWith(
          (ref) async => report,
        ),
        appSettingsProvider.overrideWith(
          failAuxiliary
              ? () => _FailingAppSettingsNotifierForReport()
              : () => _FakeAppSettingsNotifierForReport(),
        ),
        recoveryHistoryForSessionProvider(report.sessionId).overrideWith(
          (ref) async => failAuxiliary
              ? throw StateError('recovery store unavailable')
              : const [],
        ),
        opticalTrainSnapshotForSessionProvider(report.sessionId).overrideWith(
          (ref) async => failAuxiliary
              ? throw StateError('diagnostic store unavailable')
              : const SessionOpticalTrainSnapshot(
                  baseline: null,
                  current: null,
                ),
        ),
        notesForTargetProvider(primaryTarget).overrideWith(
          (ref) => const Stream<List<JournalNote>>.empty(),
        ),
        sessionInsightsProvider(report.sessionId).overrideWith(
          (ref) async => failAuxiliary
              ? throw StateError('insights unavailable')
              : const <SessionInsight>[],
        ),
      ],
      child: MaterialApp(
        theme: SkotiqTheme.dark,
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () =>
                    SessionReportDialog.show(ctx, report.sessionId),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  // Don't `pumpAndSettle` — at least one of the provider chains watched
  // by SessionReportDialog (likely a Drift query stream) keeps a
  // periodic timer alive past the dialog open animation, so settling
  // never completes. A bounded pump + 500ms tick is enough to drive
  // the dialog past its open transition and resolve the overridden
  // futures.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  // Providers below the initially visible scroll extent are first watched
  // while that frame is built. Give their immediately-completing futures one
  // more frame to publish data/error states.
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('renders headline metrics and per-target table', (tester) async {
    await _pump(tester, _fakeReport());

    // Headline.
    expect(find.text('Session report'), findsOneWidget);
    expect(find.textContaining('M42 night 1'), findsOneWidget);

    // Overview tiles.
    expect(find.text('Wall clock'), findsOneWidget);
    expect(find.text('Integration'), findsAtLeastNWidgets(1));
    expect(find.text('Effective imaging'), findsOneWidget);
    expect(find.text('Downtime'), findsOneWidget);
    expect(find.text('Frames accepted'), findsOneWidget);
    expect(find.text('Frames rejected'), findsOneWidget);

    // Sections.
    expect(find.text('Mount / operations'), findsOneWidget);
    expect(find.text('Guiding'), findsOneWidget);
    expect(find.text('Conditions'), findsOneWidget);
    expect(find.text('Targets'), findsOneWidget);

    // Per-target table — filter row present.
    expect(find.text('M42'), findsOneWidget);
    expect(find.text('L'), findsOneWidget);
    // The rejection-rollup line is rendered.
    expect(find.textContaining('Rejections:'), findsOneWidget);
  });

  testWidgets('remote report directs Session Review to the imaging host',
      (tester) async {
    await _pump(
      tester,
      _fakeReport(),
      backend: _MockNetworkBackend(),
    );

    expect(find.text('Review on imaging host'), findsOneWidget);
    expect(find.text('Review & integrate'), findsNothing);
  });

  testWidgets('Copy as Markdown writes to the clipboard', (tester) async {
    final clipboardText = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final data = call.arguments as Map<dynamic, dynamic>;
        clipboardText.add(data['text'] as String);
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await _pump(tester, _fakeReport());

    await tester.tap(find.byTooltip('Copy as Markdown'));
    // Same as _pump: avoid pumpAndSettle because a watched Drift stream
    // keeps a periodic timer alive. A bounded pump is enough to deliver
    // the synchronous Clipboard.setData call.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(clipboardText, hasLength(1));
    expect(clipboardText.single, contains('# Session Report: M42 night 1'));
    expect(clipboardText.single, contains('## Targets'));
    expect(clipboardText.single, contains('### M42'));
  });

  testWidgets('surfaces error messages section when present', (tester) async {
    await _pump(
      tester,
      _fakeReport(errors: const ['Guider lost star', 'Recovered']),
    );

    // Errors and Warnings are distinct sections so the user can visually
    // triage by severity.
    expect(find.text('Errors'), findsOneWidget);
    expect(find.text('Guider lost star'), findsOneWidget);
    expect(find.text('Recovered'), findsOneWidget);
    // Warnings section is hidden when warningMessages is empty.
    expect(find.text('Warnings'), findsNothing);
  });

  testWidgets('renders the warningMessages section (trust-patch §B item 7)',
      (tester) async {
    await _pump(
      tester,
      _fakeReport(
        warnings: const [
          'Filter "Halpha" could not be matched 14 times',
          'Autofocus skipped: dome was closing',
        ],
      ),
    );

    // Pre-patch, warningMessages was dead data (collected by the
    // executor but never rendered). The section title plus both
    // messages must appear verbatim.
    expect(find.text('Warnings'), findsOneWidget);
    expect(
      find.text('Filter "Halpha" could not be matched 14 times'),
      findsOneWidget,
    );
    expect(find.text('Autofocus skipped: dome was closing'), findsOneWidget);
  });

  testWidgets('partial report provider failures are visible and retryable',
      (tester) async {
    await _pump(tester, _fakeReport(), failAuxiliary: true);

    expect(
        find.textContaining('Could not load recovery history'), findsOneWidget);
    expect(
      find.textContaining('Could not load diagnostic settings'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Could not load retrospective suggestions'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsNWidgets(3));
  });

  // Pressing Stop must not be reported as a failure: a report titled "Stopped
  // (resumable)" carrying a red "Errors - Sequence cancelled" section beside
  // that title states a critical fault for a deliberate user action.
  testWidgets('a run the operator stopped has no Errors section',
      (tester) async {
    await _pump(
      tester,
      _fakeReport(
          status: 'paused-stopped', errors: const ['Sequence cancelled']),
    );

    expect(find.textContaining('Stopped (resumable)'), findsOneWidget);
    expect(find.text('Errors'), findsNothing);
    expect(find.text('Sequence cancelled'), findsNothing);
    expect(
      find.textContaining('You stopped this run'),
      findsOneWidget,
      reason: 'the stop is stated plainly instead of dressed as a failure',
    );
  });

  testWidgets('a stopped run still reports faults that were not the stop',
      (tester) async {
    await _pump(
      tester,
      _fakeReport(
        status: 'paused-stopped',
        errors: const ['Sequence cancelled', 'Focuser lost communication'],
      ),
    );

    expect(find.text('Errors'), findsOneWidget);
    expect(find.text('Focuser lost communication'), findsOneWidget);
    expect(find.text('Sequence cancelled'), findsNothing);
  });

  testWidgets('a run that failed on its own keeps every error message',
      (tester) async {
    await _pump(
      tester,
      _fakeReport(status: 'failed', errors: const ['Sequence cancelled']),
    );

    // No cause was chosen for this run, so the list keeps its own heading.
    expect(find.text('Errors'), findsOneWidget);
    expect(find.text('Sequence cancelled'), findsOneWidget);
  });

  // Reading the Errors list top-down is how the owner came to believe a
  // cancelled filter change had ended his night. The cause goes above it.
  group('a failed run leads with why it ended', () {
    const rejectStorm =
        'Image grading: 3 consecutive rejects (limit 3). Sequence paused for '
        'inspection.';

    testWidgets('the cause is headlined above the cascade', (tester) async {
      await _pump(
        tester,
        _fakeReport(
          status: 'failed',
          terminalCause: rejectStorm,
          rejectFolder: r'C:\Images\NGC7380\Reject',
          errors: const [
            rejectStorm,
            'Change Filter failed: Operation cancelled',
          ],
        ),
      );

      expect(find.text('Why it ended'), findsOneWidget);
      expect(
        find.text(r'Rejected frames: C:\Images\NGC7380\Reject'),
        findsOneWidget,
        reason: 'the folder is what the operator opens next',
      );
      // The cascade keeps its own heading, renamed so it does not read as a
      // competing list of candidate causes.
      expect(find.text('Everything reported'), findsOneWidget);
      expect(find.text('Errors'), findsNothing);

      final causeY = tester.getTopLeft(find.text('Why it ended')).dy;
      final cascadeY = tester.getTopLeft(find.text('Everything reported')).dy;
      expect(
        causeY,
        lessThan(cascadeY),
        reason: 'the answer comes before the list it was chosen from',
      );
    });

    testWidgets('a completed run headlines nothing', (tester) async {
      await _pump(tester, _fakeReport());

      expect(find.text('Why it ended'), findsNothing);
    });

    testWidgets('a run the operator stopped did not fail', (tester) async {
      await _pump(
        tester,
        _fakeReport(
          status: 'stopped',
          terminalCause: 'Change Filter failed: Operation cancelled',
          errors: const ['Sequence cancelled'],
        ),
      );

      expect(
        find.text('Why it ended'),
        findsNothing,
        reason:
            'a stopped run is not a failed one, and its teardown message is '
            'not a cause',
      );
    });
  });
}
