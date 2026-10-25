// Obstructions a run met are learned per site and merged into the horizon the
// planners use, without changing the operator's own profile, and the current
// site's points travel to the native frame watch in the sequence metadata.

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart' hide HorizonProfile;
import 'package:skotiq_core/src/backend/skotiq_backend.dart' as bridge_event;
import 'package:skotiq_core/src/providers/settings_provider.dart'
    show HorizonProfile;

import '../mocks/mock_backend.dart';

class _TestBackendNotifier extends BackendNotifier {
  _TestBackendNotifier(super.ref, SkotiqBackend backend) {
    state = backend;
  }
}

LearnedObstructionPoint _point({
  double az = 286.2,
  double alt = 64.0,
  double lat = 43.1,
  double lon = -77.6,
  String? target = 'NGC 891',
}) => LearnedObstructionPoint(
  azimuthDeg: az,
  altitudeDeg: alt,
  latitude: lat,
  longitude: lon,
  recordedAt: DateTime.utc(2026, 10, 24, 7, 28),
  targetName: target,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(registerMocktailFallbackValues);

  group('HorizonProfile with learned obstructions', () {
    final user = HorizonProfile.fromJson(
      '{"N":10,"NE":10,"E":10,"SE":10,"S":10,"SW":10,"W":20,"NW":20}',
    );

    test('blocks a band of +/-6 deg up to the point altitude + 1 deg', () {
      final merged = user.withLearnedObstructions([_point()]);
      expect(merged.altitudeAtAzimuth(286.2), closeTo(65.0, 1e-9));
      expect(merged.altitudeAtAzimuth(280.3), closeTo(65.0, 1e-9));
      expect(merged.altitudeAtAzimuth(292.1), closeTo(65.0, 1e-9));
      expect(merged.altitudeAtAzimuth(293.0), user.altitudeAtAzimuth(293.0));
      expect(merged.altitudeAtAzimuth(90), user.altitudeAtAzimuth(90));
      expect(merged.isAboveHorizon(64.5, 286), isFalse);
      expect(merged.isAboveHorizon(65.5, 286), isTrue);
    });

    test('never lowers the operator profile and leaves its editor values', () {
      final high = HorizonProfile.fromJson(
        '{"N":0,"NE":0,"E":0,"SE":0,"S":0,"SW":0,"W":70,"NW":70}',
      );
      final merged = high.withLearnedObstructions([_point(alt: 30)]);
      expect(merged.altitudeAtAzimuth(286), high.altitudeAtAzimuth(286));
      expect(merged.altitudeAt('W'), 70);
      expect(merged.toJson(), high.toJson());
    });

    test('a learned point makes a flat profile not flat', () {
      final flat = HorizonProfile.fromJson(
        '{"N":0,"NE":0,"E":0,"SE":0,"S":0,"SW":0,"W":0,"NW":0}',
      );
      expect(flat.isFlat, isTrue);
      expect(flat.withLearnedObstructions([_point()]).isFlat, isFalse);
    });

    test('dense samples keep the band edges sharp', () {
      final merged = user.withLearnedObstructions([_point(az: 3)]);
      final samples = merged.denseSamples();
      double at(double az) =>
          samples.firstWhere((s) => (s.azimuth - az).abs() < 1e-9).altitude;
      expect(at(357), closeTo(65, 1e-9));
      expect(at(9), closeTo(65, 1e-9));
      expect(at(356.99), closeTo(user.altitudeAtAzimuth(356.99), 1e-9));
      expect(at(9.01), closeTo(user.altitudeAtAzimuth(9.01), 1e-9));
    });
  });

  group('learned points per site', () {
    test('a point belongs to a site within 0.05 deg', () {
      final p = _point();
      expect(p.belongsToSite(43.14, -77.56), isTrue);
      expect(p.belongsToSite(43.2, -77.6), isFalse);
      expect(
        _point(lon: 179.99).belongsToSite(43.1, -179.98),
        isTrue,
        reason: 'longitudes compare across the date line',
      );
    });

    test('round-trips through the stored JSON', () {
      final points = [_point(), _point(az: 120, target: null)];
      final decoded = decodeLearnedObstructionPoints(
        encodeLearnedObstructionPoints(points),
      );
      expect(decoded, points);
      expect(decodeLearnedObstructionPoints('not json'), isEmpty);
    });
  });

  group('providers', () {
    late SkotiqDatabase db;
    late MockBackend backend;
    late StreamController<bridge_event.SkotiqEvent> events;

    setUp(() {
      db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      backend = MockBackend();
      events = StreamController<bridge_event.SkotiqEvent>.broadcast();
      when(() => backend.eventStream).thenAnswer((_) => events.stream);
      when(
        () => backend.polarAlignmentEvents,
      ).thenAnswer((_) => const Stream.empty());
    });

    tearDown(() async {
      await events.close();
      await db.close();
    });

    Future<ProviderContainer> container() async {
      final c = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          backendProvider.overrideWith(
            (ref) => _TestBackendNotifier(ref, backend),
          ),
        ],
      );
      addTearDown(c.dispose);
      await c.read(appSettingsProvider.future);
      final settings = c.read(appSettingsProvider.notifier);
      await settings.setLatitude(43.1);
      await settings.setLongitude(-77.6);
      await c.read(frameWatchSettingsProvider.future);
      return c;
    }

    test('the planning horizon merges only the current site\'s points; the '
        'user profile stays as entered', () async {
      final c = await container();
      final notifier = c.read(frameWatchSettingsProvider.notifier);
      await notifier.addLearnedPoint(_point());
      await notifier.addLearnedPoint(_point(az: 90, lat: 10, lon: 10));

      final merged = c.read(horizonProfileProvider);
      expect(merged.learnedObstructionCount, 1);
      expect(merged.altitudeAtAzimuth(286), closeTo(65, 1e-9));
      expect(merged.altitudeAtAzimuth(90), 0);
      expect(c.read(userHorizonProfileProvider).isFlat, isTrue);
    });

    test('a point seen again replaces the old one; clear forgets only this '
        'site', () async {
      final c = await container();
      final notifier = c.read(frameWatchSettingsProvider.notifier);
      await notifier.addLearnedPoint(_point());
      await notifier.addLearnedPoint(_point(az: 286.8, alt: 63.5));
      await notifier.addLearnedPoint(_point(az: 90, lat: 10, lon: 10));
      var settings = c.read(frameWatchSettingsProvider).value!;
      expect(settings.pointsForSite(43.1, -77.6), hasLength(1));
      expect(
        settings.pointsForSite(43.1, -77.6).single.azimuthDeg,
        closeTo(286.8, 1e-9),
      );

      await notifier.clearLearnedPointsForSite(43.1, -77.6);
      settings = c.read(frameWatchSettingsProvider).value!;
      expect(settings.pointsForSite(43.1, -77.6), isEmpty);
      expect(settings.learnedPoints, hasLength(1));
    });

    test('drift limit is clamped to 2-50 percent and persists', () async {
      final c = await container();
      final notifier = c.read(frameWatchSettingsProvider.notifier);
      expect(
        c.read(frameWatchSettingsProvider).value!.driftLimitPercent,
        frameWatchDriftLimitDefaultPercent,
      );
      await notifier.setDriftLimitPercent(80);
      expect(c.read(frameWatchSettingsProvider).value!.driftLimitPercent, 50);
      await notifier.setDriftLimitPercent(15);
      await notifier.setObstructionDetection(false);
      c.invalidate(frameWatchSettingsProvider);
      final reloaded = await c.read(frameWatchSettingsProvider.future);
      expect(reloaded.driftLimitPercent, 15);
      expect(reloaded.obstructionDetection, isFalse);
    });

    test(
      'the sequence metadata carries the frame watch for this site',
      () async {
        final c = await container();
        final notifier = c.read(frameWatchSettingsProvider.notifier);
        await notifier.setDriftLimitPercent(12);
        await notifier.addLearnedPoint(_point());
        await notifier.addLearnedPoint(_point(az: 90, lat: 10, lon: 10));

        final root = TargetHeaderNode(
          id: 'root',
          targetName: 'NGC 891',
          raHours: 2.376,
          decDegrees: 42.349,
        );
        final sequence = Sequence.create(
          id: 'fw',
          name: 'FW',
          rootNodeId: 'root',
          nodes: {'root': root},
        );
        final decoded =
            jsonDecode(
                  c
                      .read(sequenceExecutorProvider)
                      .sequenceToJsonForTest(sequence),
                )
                as Map<String, dynamic>;
        final metadata = decoded['metadata'] as Map<String, dynamic>;
        final frameWatch =
            jsonDecode(metadata['frame_watch'] as String)
                as Map<String, dynamic>;
        expect(frameWatch['drift_limit_fraction'], closeTo(0.12, 1e-9));
        expect(frameWatch['obstruction_detection'], isTrue);
        expect(frameWatch['learned_horizon'], [
          {'azimuth_deg': 286.2, 'altitude_deg': 64.0},
        ]);
      },
    );
  });
}
