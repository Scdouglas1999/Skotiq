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

DbCapturedImage _frame() => DbCapturedImage(
      id: 7,
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
}
