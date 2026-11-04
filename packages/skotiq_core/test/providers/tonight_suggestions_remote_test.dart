import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart'
    show Target, ImagingSession;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

import '../fakes/fake_network_client.dart';

class _FixedBackendNotifier extends BackendNotifier {
  _FixedBackendNotifier(super.ref, SkotiqBackend backend) : super() {
    state = backend;
  }
}

class _LocatedSettings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 39.97, longitude: -75.36);
}

TargetSuggestion _hostSuggestion(String name, double score) => TargetSuggestion(
  targetId: -1,
  targetName: name,
  catalogId: name,
  raHours: 2.5,
  decDegrees: 60.0,
  totalScore: score,
  scoreBreakdown: const {'altitude': 30.0},
  warnings: const [
    TargetWarning(
      type: WarningType.moonProximity,
      severity: WarningSeverity.info,
      message: 'Moon 40° away',
    ),
  ],
  visibility: TargetVisibilityInfo(
    currentAltitude: 55,
    currentAzimuth: 30,
    transitTime: DateTime.utc(2026, 11, 4, 3, 10),
    airmass: 1.2,
    moonDistance: 40,
    peakAltitude: 80,
    peakAzimuth: 0,
    hoursAboveMinAlt: 9.5,
  ),
  reasoning: 'High all night',
  objectType: 'Galaxy',
  tags: const ['Fits the field'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNetworkClient fake;
  late NetworkBackend backend;

  setUp(() {
    fake = FakeNetworkClient();
    backend = NetworkBackend(
      serverHost: '127.0.0.1',
      serverPort: 9999,
      webSocketPort: 9999,
      httpClient: fake,
      autoConnectWebSocket: false,
    );
  });

  tearDown(() => backend.dispose());

  ProviderContainer containerFor({List<Target> localTargets = const []}) {
    final container = ProviderContainer(
      overrides: [
        backendProvider.overrideWith(
          (ref) => _FixedBackendNotifier(ref, backend),
        ),
        appSettingsProvider.overrideWith(_LocatedSettings.new),
        allDbTargetsProvider.overrideWith((ref) => Stream.value(localTargets)),
        allSessionsProvider.overrideWith(
          (ref) => Stream.value(const <ImagingSession>[]),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('a linked client lists the host\'s ranking, not its own', () async {
    final host = [
      _hostSuggestion('IC0239', 97),
      _hostSuggestion('IC1823', 96.5),
    ];
    fake.setResponse(
      '/api/suggestions/ranked',
      body: jsonEncode({
        'suggestions': host.map((s) => s.toJson()).toList(),
        'totalMatching': host.length,
      }),
    );
    final container = containerFor();
    await container.read(appSettingsProvider.future);

    final suggestions = await container.read(tonightSuggestionsProvider.future);

    expect(suggestions.map((s) => s.targetName), ['IC0239', 'IC1823']);
    expect(suggestions.first.toJson(), host.first.toJson());
    expect(suggestions.first.visibility.hoursAboveMinAlt, 9.5);
    expect(suggestions.first.visibility.peakAzimuth, 0);
    expect(suggestions.first.warnings.single.message, 'Moon 40° away');

    final request = fake.requestsFor('/api/suggestions/ranked').single;
    const config = TargetSuggestionConfig(
      minAltitude: 30.0,
      minScore: 50.0,
      prioritizeIncomplete: true,
    );
    expect(request.url.queryParameters, {
      'minAltitude': '${config.minAltitude}',
      'minScore': '${config.minScore}',
      'sortMode': 'bestScore',
      'prioritizeIncomplete': 'true',
    });
  });

  test('an older host without the endpoint is ranked on the client', () async {
    fake.setResponse(
      '/api/suggestions/ranked',
      status: 404,
      body: '{"error":"Not found"}',
    );
    final now = DateTime.now();
    final container = containerFor(
      localTargets: [
        Target(
          id: 1,
          name: 'Polaris field',
          catalogId: 'POLARIS',
          ra: 2.53,
          dec: 89.26,
          minAltitude: 0,
          priority: 5,
          totalPlannedSubs: 0,
          capturedSubs: 0,
          totalIntegrationSecs: 0,
          goalIntegrationSecs: 0,
          createdAt: now,
          updatedAt: now,
          isFavorite: false,
        ),
      ],
    );
    container.read(targetSuggestionConfigProvider.notifier).state =
        const TargetSuggestionConfig(minAltitude: 0, minScore: 0);
    await container.read(appSettingsProvider.future);

    final suggestions = await container.read(tonightSuggestionsProvider.future);

    expect(suggestions.map((s) => s.targetName), ['Polaris field']);
  });

  test('any other host failure is shown, not replaced by a local list', () {
    fake.setResponse(
      '/api/suggestions/ranked',
      status: 400,
      body: '{"error":"No location configured"}',
    );
    final container = containerFor();

    expect(
      container
          .read(appSettingsProvider.future)
          .then((_) => container.read(tonightSuggestionsProvider.future)),
      throwsA(anything),
    );
  });
}
