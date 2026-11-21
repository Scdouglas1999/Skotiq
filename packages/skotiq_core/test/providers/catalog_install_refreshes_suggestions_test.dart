import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_astro/skotiq_astro.dart';
import 'package:skotiq_core/database.dart' show DbTarget, ImagingSession;
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/settings.dart';
import 'package:skotiq_core/src/backend/target_scoring.dart';
import 'package:skotiq_core/src/utils/logging_service.dart';

import '../harness/in_memory_database.dart';

const _csvName = 'NGC0001';

const _ngcCsv =
    'Name;Type;RA;Dec;Const;MajAx;MinAx;PosAng;B-Mag;V-Mag;J-Mag;H-Mag;K-Mag;'
    'SurfBr;Hubble;Pax;Pm-RA;Pm-Dec;RadVel;Redshift;Cstar U-Mag;Cstar B-Mag;'
    'Cstar V-Mag;M;NGC;IC;Cstar Names;Identifiers;Common names;NED notes;'
    'OpenNGC notes;Sources\n'
    '$_csvName;G;00:07:15.84;+27:42:29.1;Peg;1.59;1.07;112;;13.4;;;;;Sb;;;;;;;;;;;;;;;;;\n';

/// The catalog drops leading zeros (`NGC0628` → `NGC628`). The expected id is
/// that reading of the CSV name, not a value copied out of the suggestion list.
String _catalogId(String name) {
  final match = RegExp(
    r'^(NGC|IC)\s*(0*)(\d+)$',
    caseSensitive: false,
  ).firstMatch(name);
  return '${match!.group(1)!.toUpperCase()}${match.group(3)}';
}

class _Scoring extends Fake implements TargetScoring {}

/// Echoes the targets the provider loaded. Night scoring needs the native
/// bridge, which this test does not start; the list under test is still the
/// suggestion provider's, and each catalog id is the target's own.
class _PassThroughSuggestions extends TargetSuggestionService {
  _PassThroughSuggestions()
    : super(
        loggingService: LoggingService(
          nativeInit: () {},
          nativeInitWithLogging: ({String? logDirectory}) {},
          currentLogFileProvider: () => null,
        ),
        scorer: TargetScorer(_Scoring()),
      );

  @override
  Future<List<TargetSuggestion>> getSuggestionsForTonight({
    required TargetSuggestionConfig config,
    required double latitude,
    required double longitude,
    required List<DbTarget> targets,
    required List<ImagingSession> sessions,
    DateTime? observationTime,
    OpticalConfig? opticalConfig,
    required AltitudeFloor floor,
  }) async {
    return [
      for (final target in targets)
        TargetSuggestion(
          targetId: target.id,
          targetName: target.name,
          catalogId: target.catalogId,
          raHours: target.ra,
          decDegrees: target.dec,
          totalScore: 1,
          visibility: const TargetVisibilityInfo(
            currentAltitude: 50,
            currentAzimuth: 180,
            airmass: 1.2,
            moonDistance: 40,
          ),
        ),
    ];
  }
}

class _Settings extends AppSettingsNotifier {
  @override
  Future<AppSettingsState> build() async =>
      const AppSettingsState(latitude: 40, longitude: -75);
}

class _Clock implements Clock {
  @override
  DateTime now() => DateTime(2026, 10, 31, 22);

  @override
  DateTime nowUtc() => DateTime(2026, 10, 31, 22).toUtc();

  @override
  Duration get utcOffset => DateTime(2026, 10, 31, 22).timeZoneOffset;

  @override
  DateTime fromUtc(DateTime utc) => utc.toLocal();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('installing NGC 0001 refreshes suggestions that are already listening', () async {
    final root = await Directory.systemTemp.createTemp('g1-catalog-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final manager = CatalogManager.instance;
    await manager.initialize(root.path);
    final source = File('${root.path}/ngc.csv');
    await source.writeAsString(_ngcCsv);
    final expectedId = _catalogId(_csvName);
    expect(_ngcCsv.contains(_csvName), isTrue);

    final container = ProviderContainer(
      overrides: [
        inMemoryDatabaseOverride(),
        targetSuggestionServiceProvider.overrideWithValue(
          _PassThroughSuggestions(),
        ),
        appSettingsProvider.overrideWith(_Settings.new),
        clockProvider.overrideWithValue(_Clock()),
        altitudeFloorProvider.overrideWithValue(
          const AltitudeFloor(horizon: null, minimumDeg: 30),
        ),
        allDbTargetsProvider.overrideWith((ref) => Stream.value(const <DbTarget>[])),
        allSessionsProvider.overrideWith(
          (ref) => Stream.value(const <ImagingSession>[]),
        ),
      ],
    );
    addTearDown(container.dispose);
    const config = TargetSuggestionConfig(minScore: 0);
    final provider = localTonightSuggestionsProvider(config);
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);
    await container.read(appSettingsProvider.future);

    final before = await container.read(provider.future);
    expect(before.map((s) => s.catalogId), isNot(contains(expectedId)));

    await manager.installFromFile(SkyCatalog.dso, source);
    await pumpEventQueue();
    final installed = await container.read(provider.future);
    expect(installed.map((s) => s.catalogId), contains(expectedId));

    await manager.uninstall(SkyCatalog.dso);
    await pumpEventQueue();
    final removed = await container.read(provider.future);
    expect(removed.map((s) => s.catalogId), isNot(contains(expectedId)));
  });
}
