import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_app/widgets/focus_model_curve_card.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';
import '../harness/mock_database.dart' show inMemoryDatabaseOverride;

void main() {
  testWidgets('compact focus model card opens its merged Settings section', (
    tester,
  ) async {
    final visited = ValueNotifier<String?>(null);
    addTearDown(visited.dispose);
    final router = GoRouter(
      initialLocation: '/devices',
      routes: [
        GoRoute(
          path: '/devices',
          builder: (_, __) => const Scaffold(
            body: FocusModelCurveCard(compact: true),
          ),
        ),
        GoRoute(
          path: '/settings',
          builder: (_, state) {
            visited.value = state.uri.toString();
            return const Scaffold(body: Text('SETTINGS'));
          },
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(id: 7, name: 'Test rig'),
          ),
          focuserStateProvider.overrideWith(_ConnectedFocuser.new),
          focusModelServiceProvider.overrideWithValue(_FocusDataService()),
        ],
        child: MaterialApp.router(
          theme: SkotiqTheme.dark,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FocusModelCurveCard));
    await tester.pumpAndSettle();

    expect(visited.value, '/settings?section=focus-model');
    expect(find.text('SETTINGS'), findsOneWidget);
  });

  testWidgets('remote card renders the imaging host focus model', (
    tester,
  ) async {
    final remoteProfile = ProfileFocusData(
      profileId: '7',
      dataPoints: [
        FocusHistoryPoint(
          timestamp: DateTime.utc(2026, 7, 13),
          temperatureCelsius: 6.5,
          focusPosition: 11800,
          hfr: 1.9,
        ),
      ],
      temperatureModel: FocusModel(
        slope: -31.0,
        intercept: 12000,
        rSquared: 0.95,
        dataPointCount: 7,
        lastUpdated: DateTime.utc(2026, 7, 13),
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(id: 7, name: 'Remote rig'),
          ),
          focuserStateProvider.overrideWith(_ConnectedFocuser.new),
          isRemoteModeProvider.overrideWithValue(true),
          focusProfileDataProvider('7').overrideWith(
            (ref) async => remoteProfile,
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: FocusModelCurveCard(compact: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Excellent · R²=0.95'), findsOneWidget);
    expect(find.text('Could not load focus model'), findsNothing);
  });

  testWidgets('remote add point mutates the imaging host, not local storage', (
    tester,
  ) async {
    final backend = _MockNetworkBackend();
    final localService = _TrackingFocusService();
    when(() => backend.getFilterFocusOffsets()).thenAnswer(
      (_) async => <String, dynamic>{
        'referenceFilter': null,
        'offsets': <String, dynamic>{},
      },
    );
    when(
      () => backend.addFocusDataPoint(
        temperature: any(named: 'temperature'),
        position: any(named: 'position'),
        hfr: any(named: 'hfr'),
        filter: any(named: 'filter'),
      ),
    ).thenAnswer((_) async {});

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inMemoryDatabaseOverride(),
          backendProvider.overrideWith(
            (ref) => _FixedBackendNotifier(ref, backend),
          ),
          activeEquipmentProfileProvider.overrideWithValue(
            const EquipmentProfileModel(id: 7, name: 'Remote rig'),
          ),
          focuserStateProvider.overrideWith(_ConnectedFocuser.new),
          isRemoteModeProvider.overrideWithValue(true),
          focusModelServiceProvider.overrideWithValue(localService),
          focusProfileDataProvider('7').overrideWith(
            (ref) async => ProfileFocusData(
              profileId: '7',
              dataPoints: [
                FocusHistoryPoint(
                  timestamp: DateTime.utc(2026, 7, 13),
                  temperatureCelsius: 8,
                  focusPosition: 12000,
                  hfr: 2.1,
                ),
              ],
            ),
          ),
        ],
        child: MaterialApp(
          theme: SkotiqTheme.dark,
          home: const Scaffold(
            body: SingleChildScrollView(child: FocusModelCurveCard()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(SkotiqButton, 'Add point'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.widgetWithText(TextField, 'HFR'), '1.8');
    await tester.tap(find.widgetWithText(TextButton, 'Save'));
    await tester.pumpAndSettle();

    verify(
      () => backend.addFocusDataPoint(
        temperature: 8,
        position: 12000,
        hfr: 1.8,
        filter: null,
      ),
    ).called(1);
    expect(localService.addCalls, 0);
    expect(find.text('Focus point added'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _MockNetworkBackend extends Mock implements NetworkBackend {}

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _ConnectedFocuser extends FocuserStateNotifier {
  _ConnectedFocuser(super.ref) {
    state = const FocuserState(
      connectionState: DeviceConnectionState.connected,
      position: 12000,
      hasTemperature: true,
      temperature: 8.0,
    );
  }
}

class _FocusDataService extends FocusModelService {
  @override
  Future<void> initialize() async {}

  @override
  ProfileFocusData? getProfileData(String profileId) => ProfileFocusData(
        profileId: profileId,
        dataPoints: [
          FocusHistoryPoint(
            timestamp: DateTime.utc(2026, 7, 13),
            temperatureCelsius: 8.0,
            focusPosition: 12000,
            hfr: 2.1,
          ),
        ],
      );
}

class _TrackingFocusService extends FocusModelService {
  int addCalls = 0;

  @override
  Future<void> addDataPoint({
    required String profileId,
    required double temperatureCelsius,
    required int focusPosition,
    required double hfr,
    String? filterName,
  }) async {
    addCalls++;
  }
}
