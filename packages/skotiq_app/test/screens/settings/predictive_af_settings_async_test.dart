import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/screens/settings/widgets/predictive_af_settings.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../../harness/mock_database.dart' show inMemoryDatabaseOverride;

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _SwappableBackendNotifier extends BackendNotifier {
  _SwappableBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }

  void switchTo(SkotiqBackend backend) => state = backend;
}

Map<String, dynamic> _settingsResponse({
  List<Map<String, dynamic>> models = const [],
}) =>
    {
      'config': const PredictiveAfConfig().toJson(),
      'models': models,
    };

Finder _fieldWithText(String text) => find.byWidgetPredicate(
      (widget) => widget is TextFormField && widget.controller?.text == text,
    );

Future<void> _submit(
  WidgetTester tester,
  String oldValue,
  String newValue,
) async {
  final field = _fieldWithText(oldValue);
  expect(field, findsOneWidget);
  await tester.enterText(field, newValue);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  registerFallbackValue(<String, dynamic>{});

  testWidgets('failed numeric save is awaited and rolls back without leaking',
      (tester) async {
    final backend = _MockNetworkBackend();
    when(backend.getPredictiveAfSettings).thenAnswer(
      (_) async => _settingsResponse(),
    );
    when(
      () => backend.updatePredictiveAfConfig(any()),
    ).thenAnswer((_) async => throw StateError('write failed'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          activeEquipmentProfileProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: PredictiveAfSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _submit(tester, '0.8', '0.9');
    await tester.pumpAndSettle();

    expect(_fieldWithText('0.8'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued config write is discarded when imaging host changes',
      (tester) async {
    final hostA = _MockNetworkBackend();
    final hostB = _MockNetworkBackend();
    final firstWrite = Completer<void>();
    var hostAWrites = 0;
    when(hostA.getPredictiveAfSettings).thenAnswer(
      (_) async => _settingsResponse(),
    );
    when(hostB.getPredictiveAfSettings).thenAnswer(
      (_) async => _settingsResponse(),
    );
    when(() => hostA.updatePredictiveAfConfig(any())).thenAnswer((_) {
      hostAWrites++;
      return hostAWrites == 1 ? firstWrite.future : Future<void>.value();
    });
    late _SwappableBackendNotifier backendNotifier;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith((ref) {
            backendNotifier = _SwappableBackendNotifier(ref, hostA);
            return backendNotifier;
          }),
          activeEquipmentProfileProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: PredictiveAfSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _submit(tester, '0.8', '0.9');
    expect(hostAWrites, 1);
    await _submit(tester, '200', '300');

    backendNotifier.switchTo(hostB);
    await tester.pump();
    await tester.pump();
    firstWrite.complete();
    await tester.pump();
    await tester.pump();

    expect(hostAWrites, 1);
    verifyNever(() => hostB.updatePredictiveAfConfig(any()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('learned model actions fit a phone-width settings page', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 900);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    final backend = _MockNetworkBackend();
    final model = FilterFocusModel(
      uuid: 'model-1',
      equipmentProfileId: 7,
      filterName: 'Hydrogen alpha narrowband filter',
      filterIndex: 1,
      slopeStepsPerC: 123.4,
      focusOffsetRelativeToLum: 50,
      interceptAtReferenceTemp: 12000,
      referenceTempCelsius: 0,
      lastTrainedAt: DateTime.utc(2026, 7, 1),
      trainingRunCount: 12,
      confidenceScore: 0.923,
      lastUsedAt: DateTime.utc(2026, 7, 2),
      samples: const [],
      maxTrainingSamples: 50,
      consecutiveBadPredictions: 0,
      accumulatedDriftSteps: 0,
    );
    when(backend.getPredictiveAfSettings).thenAnswer(
      (_) async => _settingsResponse(models: [model.toWireJson()]),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _SwappableBackendNotifier(ref, backend),
          ),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(id: 7, name: 'Phone rig'),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: PredictiveAfSettingsPage(isMobile: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Re-train'), findsOneWidget);
    expect(find.byIcon(LucideIcons.download), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
