import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/src/database/database.dart' show DbTarget;
import 'package:skotiq_core/utils.dart';

import '../fakes/fake_target_scoring.dart';

class _Log extends Mock implements LoggingService {}

typedef _Site = ({double lat, double lon, String now});

/// The planners are handed the app clock's local time, so the clock-window
/// fallback lands on the machine's local calendar day, whatever its zone.
DateTime _localNow(_Site site) => DateTime.parse(site.now).toLocal();

/// [hour]:00 local, [days] after the local day of the site's instant.
DateTime _clockOn(_Site site, int days, int hour) {
  final local = _localNow(site);
  return DateTime(local.year, local.month, local.day + days, hour);
}

// Tonight's dark window as the two planners derive it, pinned at a
// mid-latitude night, a summer night with no astronomical dark, midnight sun
// and polar night.
void main() {
  const sites = {
    'mid-latitude': (lat: 40.0, lon: -105.0, now: '2024-07-16T04:00:00Z'),
    'nautical only': (lat: 60.0, lon: 10.0, now: '2024-06-21T22:00:00Z'),
    'midnight sun': (lat: 78.2, lon: 15.6, now: '2024-06-21T22:00:00Z'),
    'polar night': (lat: 89.0, lon: 15.6, now: '2024-12-21T20:00:00Z'),
  };

  Future<({int start, int end, List<String> warnings})> suggestionWindow(
    _Site site, {
    bool utcClock = false,
  }) async {
    final scoring = FakeTargetScoring();
    final log = _Log();
    final warnings = <String>[];
    when(() => log.warning(any(), source: any(named: 'source'))).thenAnswer(
      (call) => warnings.add(call.positionalArguments.first as String),
    );
    final service = TargetSuggestionService(
      loggingService: log,
      scorer: TargetScorer(scoring),
    );
    await service.getSuggestionsForTonight(
      config: const TargetSuggestionConfig(minScore: 0.0),
      latitude: site.lat,
      longitude: site.lon,
      targets: [
        DbTarget(
          id: 1,
          name: 'M31',
          ra: 0.71,
          dec: 41.27,
          minAltitude: 30.0,
          priority: 0,
          totalPlannedSubs: 0,
          capturedSubs: 0,
          totalIntegrationSecs: 0,
          goalIntegrationSecs: 0.0,
          createdAt: DateTime(2024),
          updatedAt: DateTime(2024),
          isFavorite: false,
        ),
      ],
      sessions: const [],
      observationTime: utcClock ? DateTime.parse(site.now) : _localNow(site),
      floor: const AltitudeFloor(horizon: null, minimumDeg: 0.0),
    );
    final sky = scoring.nightRequests.single.sky;
    return (
      start: sky.nightStartUnixMs,
      end: sky.nightEndUnixMs,
      warnings: warnings,
    );
  }

  Object smartNightWindow(_Site site) {
    final service = SmartNightService(
      suggestionService: TargetSuggestionService(
        loggingService: _Log(),
        scorer: TargetScorer(FakeTargetScoring()),
      ),
      logging: _Log(),
      floor: const AltitudeFloor(horizon: null, minimumDeg: 0.0),
    );
    try {
      final w = service.calculateWindow(
        latitudeDeg: site.lat,
        longitudeDeg: site.lon,
        now: _localNow(site),
      );
      return (start: w.start, end: w.end);
    } on SmartNightBuildException {
      return 'refused';
    }
  }

  test('a night with twilight gives both planners the same bounds', () async {
    const pinned = {
      'mid-latitude': (start: 1721103834375, end: 1721123320312),
      'nautical only': (start: 1719009267187, end: 1719014981250),
    };
    for (final MapEntry(:key, value: bounds) in pinned.entries) {
      final site = sites[key]!;
      final suggestion = await suggestionWindow(site);
      expect(
        (start: suggestion.start, end: suggestion.end),
        bounds,
        reason: key,
      );
      expect(suggestion.warnings, isEmpty, reason: key);
      final smart = smartNightWindow(site) as ({DateTime start, DateTime end});
      expect(
        (
          start: smart.start.millisecondsSinceEpoch,
          end: smart.end.millisecondsSinceEpoch,
        ),
        bounds,
        reason: key,
      );
    }
  });

  test(
    'midnight sun: suggestions take 21:00-05:00, Smart Night refuses',
    () async {
      final site = sites['midnight sun']!;
      final suggestion = await suggestionWindow(site);
      expect(
        DateTime.fromMillisecondsSinceEpoch(suggestion.start),
        _clockOn(site, 0, 21),
      );
      expect(
        DateTime.fromMillisecondsSinceEpoch(suggestion.end),
        _clockOn(site, 1, 5),
      );
      expect(suggestion.warnings, [
        'No twilight boundaries found - using default 21:00-05:00 window',
      ]);
      expect(smartNightWindow(sites['midnight sun']!), 'refused');
    },
  );

  test('polar night: both take a clock window from 21:00', () async {
    final site = sites['polar night']!;
    final suggestion = await suggestionWindow(site);
    expect(
      DateTime.fromMillisecondsSinceEpoch(suggestion.start),
      _clockOn(site, 0, 21),
    );
    expect(
      DateTime.fromMillisecondsSinceEpoch(suggestion.end),
      _clockOn(site, 1, 5),
    );
    final smart = smartNightWindow(site) as ({DateTime start, DateTime end});
    expect(smart.start, _clockOn(site, 0, 21));
    expect(smart.end, _clockOn(site, 1, 5));
  });

  // The clock window is read off the machine's local day. A UTC instant for
  // the same moment used to build it from the UTC date's fields, a day off on
  // a computer whose local date differs from the UTC one.
  test('a UTC clock gives the same fallback window as the local one', () async {
    for (final key in ['midnight sun', 'polar night']) {
      final site = sites[key]!;
      final local = await suggestionWindow(site);
      final utc = await suggestionWindow(site, utcClock: true);
      expect(
        (start: utc.start, end: utc.end),
        (start: local.start, end: local.end),
        reason: key,
      );
    }
  });
}
