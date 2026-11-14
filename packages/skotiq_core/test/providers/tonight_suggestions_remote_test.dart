import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/backend.dart';
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_core/src/database/database.dart'
    show DbTarget, ImagingSession;
import 'package:skotiq_astro/skotiq_astro.dart';

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

TargetSuggestion _hostSuggestion(
  String name,
  double score, {
  double airmass = 1.2,
}) => TargetSuggestion(
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
    airmass: airmass,
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

  ProviderContainer containerFor({List<DbTarget> localTargets = const []}) {
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
      // Below the horizon now: no airmass, which JSON carries as null.
      _hostSuggestion('NGC1003', 96, airmass: double.infinity),
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

    expect(suggestions.map((s) => s.targetName), [
      'IC0239',
      'IC1823',
      'NGC1003',
    ]);
    expect(suggestions.last.visibility.airmass, double.infinity);
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

  test('a host that cannot rank says so; the client does not rank its own '
      'catalog instead', () async {
    fake.setResponse(
      '/api/suggestions/ranked',
      status: 404,
      body: '{"error":"Not found"}',
    );
    final container = containerFor(localTargets: const []);
    await container.read(appSettingsProvider.future);

    await expectLater(
      container.read(tonightSuggestionsProvider.future),
      throwsA(isA<ServerError>()),
    );
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
