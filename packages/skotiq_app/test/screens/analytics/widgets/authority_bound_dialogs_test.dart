import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/analytics/widgets/image_grader_dialog.dart';
import 'package:skotiq_app/screens/analytics/widgets/science_export_hub.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

class _FakeScienceSettingsNotifier extends ScienceSettingsNotifier {
  @override
  Future<ScienceSettings> build() async => const ScienceSettings();
}

/// Rules that reject every frame above HFR 2, and a save of them that the
/// test finishes by hand.
class _PendingSaveScienceSettingsNotifier extends ScienceSettingsNotifier {
  final saved = Completer<void>();
  int saves = 0;

  @override
  Future<ScienceSettings> build() async => ScienceSettings(
        frameGradeRulesJson: const FrameGradeRules(maxHfr: 2).toJsonString(),
      );

  @override
  Future<void> setFrameGradeRules(FrameGradeRules rules) {
    saves++;
    return saved.future;
  }
}

ImagingSession _session(int id) => ImagingSession(
      id: id,
      name: 'Night $id',
      startTime: DateTime.utc(2026, 7, 13),
      totalExposures: 1,
      successfulExposures: 1,
      failedExposures: 0,
      totalIntegrationSecs: 120,
      autofocusCount: 0,
      status: 'completed',
    );

DbCapturedImage _frame({double? hfr}) => DbCapturedImage(
      id: 7,
      hfr: hfr,
      filePath: '/host-a/light-7.fits',
      fileName: 'light-7.fits',
      fileFormat: 'fits',
      frameType: 'light',
      exposureDuration: 120,
      binX: 1,
      binY: 1,
      capturedAt: DateTime.utc(2026, 7, 13),
      createdAt: DateTime.utc(2026, 7, 13),
      isAccepted: true,
      isPlateSolved: false,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => registerFallbackValue(<String, dynamic>{}));

  setUp(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .physicalSize = const Size(1200, 900);
    TestWidgetsFlutterBinding
        .instance.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetPhysicalSize();
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .resetDevicePixelRatio();
  });

  testWidgets('science export hub closes when its rig authority changes',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
          allSessionsProvider.overrideWith(
            (ref) => Stream.value(const <ImagingSession>[]),
          ),
          allTransientDetectionsProvider.overrideWith(
            (ref) => Stream.value(const <TransientDetectionRow>[]),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const ScienceExportHub(),
                ),
                child: const Text('Open export'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open export'));
    await tester.pumpAndSettle();
    expect(find.text('Science Data Export'), findsOneWidget);

    await tester.tap(find.text('Start Date'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pumpAndSettle();

    expect(find.text('Science Data Export'), findsNothing);
    expect(find.byType(DatePickerDialog), findsNothing);
    expect(find.text('Open export'), findsOneWidget);
  });

  testWidgets('image grader closes when its fixed frame authority changes',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    when(() => hostA.getSessionPsfTiles(42))
        .thenAnswer((_) async => const <PsfFieldTileRow>[]);
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
          scienceSettingsProvider.overrideWith(
            _FakeScienceSettingsNotifier.new,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => ImageGraderDialog.show(
                  context,
                  frames: [_frame()],
                  sessionId: 42,
                ),
                child: const Text('Open grader'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open grader'));
    await tester.pumpAndSettle();
    expect(find.text('Image grader'), findsOneWidget);

    notifier.switchTo(hostB);
    await tester.pumpAndSettle();

    expect(find.text('Image grader'), findsNothing);
  });

  testWidgets(
      'an observation report the old host finishes after a switch is not '
      'saved', (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final report = Completer<Uint8List>();
    when(() => hostA.generateObservationReport(5))
        .thenAnswer((_) => report.future);
    var exportDirectoryReads = 0;
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
          allSessionsProvider.overrideWith(
            (ref) => Stream.value([_session(5)]),
          ),
          allTransientDetectionsProvider.overrideWith(
            (ref) => Stream.value(const <TransientDetectionRow>[]),
          ),
          scienceExportDirectoryProvider.overrideWith((ref) async {
            exportDirectoryReads++;
            throw StateError('the old host report reached the export folder');
          }),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const ScienceExportHub(),
                ),
                child: const Text('Open export'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open export'));
    await tester.pumpAndSettle();
    final generate = find.text('Generate Observation Report (PDF)');
    await tester.ensureVisible(generate);
    await tester.tap(generate);
    await tester.pump();
    verify(() => hostA.generateObservationReport(5)).called(1);

    notifier.switchTo(hostB);
    report.complete(Uint8List.fromList([1, 2, 3]));
    await tester.pumpAndSettle();
    expect(find.text('Science Data Export'), findsNothing);

    expect(exportDirectoryReads, 0);
    expect(find.textContaining('Report generated'), findsNothing);
    expect(find.textContaining('Report generation failed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'a grade the old host saves after a switch rejects no frame on either '
      'host', (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    for (final host in [hostA, hostB]) {
      when(() => host.getSessionPsfTiles(42))
          .thenAnswer((_) async => const <PsfFieldTileRow>[]);
      when(() => host.updateCapturedImage(any(), any()))
          .thenAnswer((_) async {});
    }
    final settings = _PendingSaveScienceSettingsNotifier();
    late _SwappableBackendNotifier notifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            notifier = _SwappableBackendNotifier(ref, hostA);
            return notifier;
          }),
          scienceSettingsProvider.overrideWith(() => settings),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => ImageGraderDialog.show(
                  context,
                  frames: [_frame(hfr: 3.5)],
                  sessionId: 42,
                ),
                child: const Text('Open grader'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open grader'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reject 1 frame'));
    await tester.pump();
    expect(settings.saves, 1);

    // The old host answers in the same turn as the switch, before the closed
    // dialog has left the tree.
    notifier.switchTo(hostB);
    settings.saved.complete();
    await tester.pumpAndSettle();
    expect(find.text('Image grader'), findsNothing);

    verifyNever(() => hostA.updateCapturedImage(any(), any()));
    verifyNever(() => hostB.updateCapturedImage(any(), any()));
    expect(tester.takeException(), isNull);
  });
}
