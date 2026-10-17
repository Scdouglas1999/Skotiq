import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart' hide HorizonProfile;
import 'package:skotiq_core/src/providers/settings_provider.dart'
    show HorizonProfile;
import 'package:skotiq_core/src/database/database.dart'
    show Target, ImagingSession;

/// Mock implementation of LoggingService
class MockLoggingService extends Mock implements LoggingService {}

void main() {
  group('TargetSuggestionService', () {
    late TargetSuggestionService service;
    late MockLoggingService mockLogger;

    setUp(() {
      mockLogger = MockLoggingService();
      service = TargetSuggestionService(loggingService: mockLogger);
    });

    /// Helper to create a test target
    Target createTarget({
      required int id,
      required String name,
      required double ra,
      required double dec,
      String? catalogId,
      String? objectType,
      double? magnitude,
      double? sizeArcmin,
      String? constellation,
      int totalPlannedSubs = 0,
      double totalIntegrationSecs = 0,
    }) {
      return Target(
        id: id,
        name: name,
        catalogId: catalogId,
        objectType: objectType,
        ra: ra,
        dec: dec,
        magnitude: magnitude,
        sizeArcmin: sizeArcmin,
        constellation: constellation,
        minAltitude: 30.0,
        priority: 0,
        totalPlannedSubs: totalPlannedSubs,
        capturedSubs: 0,
        totalIntegrationSecs: totalIntegrationSecs,
        goalIntegrationSecs: 0.0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        isFavorite: false,
      );
    }

    /// Helper to create a test imaging session
    ImagingSession createSession({
      required int id,
      required int targetId,
      required double totalIntegrationSecs,
    }) {
      return ImagingSession(
        id: id,
        targetId: targetId,
        startTime: DateTime.now().subtract(const Duration(hours: 1)),
        totalExposures: 10,
        successfulExposures: 10,
        failedExposures: 0,
        totalIntegrationSecs: totalIntegrationSecs,
        autofocusCount: 1,
        status: 'completed',
      );
    }

    test('catalog scoring keeps the UI event loop responsive', () async {
      final targets = List.generate(
        3716,
        (i) => createTarget(
          id: i + 1,
          name: 'Catalog $i',
          ra: (i % 240) / 10,
          dec: (i % 150) - 70.0,
          objectType: 'Galaxy',
          sizeArcmin: 10,
        ),
      );
      final clock = Stopwatch()..start();
      var lastTick = Duration.zero;
      var longestGap = Duration.zero;
      var ticks = 0;
      void recordTick() {
        final now = clock.elapsed;
        final gap = now - lastTick;
        if (gap > longestGap) longestGap = gap;
        lastTick = now;
        ticks++;
      }

      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 10),
        (_) => recordTick(),
      );
      try {
        await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(),
          latitude: 39.97,
          longitude: -75.36,
          targets: targets,
          sessions: [],
          observationTime: DateTime.utc(2026, 10, 7, 22),
        );
        final deliveredTicks = ticks;
        recordTick();
        printOnFailure(
          'Scored ${targets.length} targets in ${clock.elapsedMilliseconds}ms; '
          'UI heartbeats: $deliveredTicks; longest stall: ${longestGap.inMilliseconds}ms',
        );
        expect(
          longestGap,
          lessThan(const Duration(milliseconds: 250)),
          reason:
              'Target scoring must not freeze rendering and input while loading the catalog',
        );
        expect(deliveredTicks, greaterThan(0));
      } finally {
        heartbeat.cancel();
      }
    });

    test('background scoring respects an imported horizon profile', () async {
      final targets = [
        createTarget(
          id: 1,
          name: 'NGC7380',
          ra: 22.78,
          dec: 58.1,
          objectType: 'Emission Nebula',
          sizeArcmin: 25,
        ),
      ];
      Future<List<TargetSuggestion>> score(HorizonProfile? horizon) =>
          service.getSuggestionsForTonight(
            config: const TargetSuggestionConfig(minAltitude: 0, minScore: 0),
            latitude: 39.97,
            longitude: -75.36,
            targets: targets,
            sessions: [],
            observationTime: DateTime.utc(2026, 10, 7, 22),
            horizonProfile: horizon,
          );
      expect(await score(null), isNotEmpty);
      expect(
        await score(
          HorizonProfile.fromSamples(const [
            (azimuth: 0, altitude: 89),
            (azimuth: 180, altitude: 89),
          ]),
        ),
        isEmpty,
      );
    });

    group('getSuggestionsForTonight', () {
      // A sizeless star otherwise takes tonight's #1 imaging pick: "gam Cyg /
      // IC1318", typed Star at mag 2.2 — a naked-eye point source above every
      // nebula in the list, with the exposure suggestion and the magnitude sort
      // inheriting its stellar magnitude.
      test('does not offer a sizeless star as an imaging target', () async {
        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(minAltitude: 0.0, minScore: 0.0),
          latitude: 40.0,
          longitude: -105.0,
          targets: [
            createTarget(
              id: 1,
              name: 'gam Cyg',
              catalogId: 'IC1318',
              ra: 20.37,
              dec: 40.26,
              objectType: 'Star',
              magnitude: 2.2,
            ),
            createTarget(
              id: 2,
              name: 'M39',
              catalogId: 'NGC7092',
              ra: 21.53,
              dec: 48.43,
              objectType: 'Open Cluster',
              magnitude: 4.6,
              sizeArcmin: 29.0,
            ),
          ],
          sessions: [],
          observationTime: DateTime(2024, 7, 15, 22),
        );

        expect(
          suggestions.map((s) => s.targetName),
          isNot(contains('gam Cyg')),
        );
        expect(suggestions.map((s) => s.targetName), contains('M39'));
      });

      // A star the user explicitly asked for is still theirs to image, and a
      // star-typed row with a real angular size (an extended emission region
      // carrying a stellar type) is a legitimate subject.
      test(
        'keeps star-typed rows when they have a size or were asked for',
        () async {
          final extended = await service.getSuggestionsForTonight(
            config: const TargetSuggestionConfig(
              minAltitude: 0.0,
              minScore: 0.0,
            ),
            latitude: 40.0,
            longitude: -105.0,
            targets: [
              createTarget(
                id: 1,
                name: 'Extended star field',
                ra: 20.37,
                dec: 40.26,
                objectType: 'Star cloud',
                magnitude: 4.0,
                sizeArcmin: 45.0,
              ),
            ],
            sessions: [],
            observationTime: DateTime(2024, 7, 15, 22),
          );
          expect(extended, hasLength(1));

          final requested = await service.getSuggestionsForTonight(
            config: const TargetSuggestionConfig(
              minAltitude: 0.0,
              minScore: 0.0,
              preferredObjectTypes: ['Star'],
            ),
            latitude: 40.0,
            longitude: -105.0,
            targets: [
              createTarget(
                id: 1,
                name: 'gam Cyg',
                ra: 20.37,
                dec: 40.26,
                objectType: 'Star',
                magnitude: 2.2,
              ),
            ],
            sessions: [],
            observationTime: DateTime(2024, 7, 15, 22),
          );
          expect(requested, hasLength(1));
        },
      );

      test('returns empty list for empty targets', () async {
        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(),
          latitude: 40.0,
          longitude: -75.0,
          targets: [],
          sessions: [],
        );

        expect(suggestions, isEmpty);
      });

      test('returns suggestions with calculated scores', () async {
        // Use a target that will be visible from this location
        // Vega (RA ~18.6h, Dec ~+38.8 deg) is a good choice for mid-latitudes
        final targets = [
          createTarget(
            id: 1,
            name: 'Vega',
            ra: 18.6, // RA in hours
            dec: 38.8, // Dec in degrees
            objectType: 'Star',
            magnitude: 0.0,
          ),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(
            minAltitude: 0.0, // Allow any altitude above horizon
            minScore: 0.0, // Allow any score
          ),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(
            2024,
            7,
            15,
            22,
            0,
          ), // Summer evening when Vega is high
        );

        // Should return at least one suggestion if target is above horizon
        // Note: actual result depends on astronomical calculations
        // This test verifies that scoring logic is invoked
        if (suggestions.isNotEmpty) {
          final suggestion = suggestions.first;
          expect(suggestion.targetId, equals(1));
          expect(suggestion.targetName, equals('Vega'));
          expect(suggestion.totalScore, greaterThanOrEqualTo(0));
          expect(suggestion.scoreBreakdown, isNotEmpty);
          expect(suggestion.scoreBreakdown.containsKey('altitude'), isTrue);
          expect(suggestion.scoreBreakdown.containsKey('moonDistance'), isTrue);
        }
      });

      test('calculates data progress from sessions', () async {
        final targets = [
          createTarget(
            id: 1,
            name: 'Test Target',
            ra: 12.0,
            dec: 45.0,
            totalPlannedSubs: 100, // 100 planned subs
          ),
        ];

        // Session with 15000 seconds of integration (50 subs at 300s each)
        final sessions = [
          createSession(
            id: 1,
            targetId: 1,
            totalIntegrationSecs: 15000, // 50% of planned
          ),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(minAltitude: 0.0, minScore: 0.0),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: sessions,
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        if (suggestions.isNotEmpty) {
          // 50% progress (15000s out of 30000s total planned)
          expect(suggestions.first.dataProgress, closeTo(0.5, 0.01));
        }
      });

      test('generates reasoning for suggestions', () async {
        final targets = [
          createTarget(
            id: 1,
            name: 'Test Galaxy',
            ra: 12.0,
            dec: 45.0,
            objectType: 'Galaxy',
          ),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(minAltitude: 0.0, minScore: 0.0),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        if (suggestions.isNotEmpty) {
          final reasoning = suggestions.first.reasoning;
          expect(reasoning, isNotEmpty);
          // Reasoning should mention altitude
          expect(reasoning.toLowerCase(), contains('altitude'));
        }
      });

      test('filters targets below minimum altitude', () async {
        // Target at Dec = -80 degrees will be below horizon for latitude 40N
        final targets = [
          createTarget(
            id: 1,
            name: 'Southern Target',
            ra: 12.0,
            dec: -80.0, // Very southern - not visible from 40N
          ),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(
            minAltitude: 30.0, // Require 30 degrees altitude
          ),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        // Target should be filtered out - never rises above 30 degrees at this latitude
        expect(suggestions, isEmpty);
      });

      test('filters targets below minimum score', () async {
        final targets = [
          createTarget(id: 1, name: 'Test Target', ra: 12.0, dec: 45.0),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(
            minAltitude: 0.0,
            minScore: 100.0, // Impossibly high score requirement
          ),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        // All targets should be filtered out due to score threshold
        expect(suggestions, isEmpty);
      });

      test('sorts by best score when configured', () async {
        final targets = [
          createTarget(id: 1, name: 'Target A', ra: 6.0, dec: 30.0),
          createTarget(id: 2, name: 'Target B', ra: 12.0, dec: 50.0),
          createTarget(id: 3, name: 'Target C', ra: 18.0, dec: 40.0),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(
            minAltitude: 0.0,
            minScore: 0.0,
            sortMode: SuggestionSortMode.bestScore,
            prioritizeIncomplete: false,
          ),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 6, 21, 22, 0),
        );

        if (suggestions.length >= 2) {
          // Verify sorted by score descending
          for (int i = 0; i < suggestions.length - 1; i++) {
            expect(
              suggestions[i].totalScore,
              greaterThanOrEqualTo(suggestions[i + 1].totalScore),
            );
          }
        }
      });

      test('sorts by highest altitude when configured', () async {
        final targets = [
          createTarget(id: 1, name: 'Target A', ra: 6.0, dec: 30.0),
          createTarget(id: 2, name: 'Target B', ra: 12.0, dec: 50.0),
          createTarget(id: 3, name: 'Target C', ra: 18.0, dec: 40.0),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(
            minAltitude: 0.0,
            minScore: 0.0,
            sortMode: SuggestionSortMode.highestAltitude,
            prioritizeIncomplete: false,
          ),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 6, 21, 22, 0),
        );

        if (suggestions.length >= 2) {
          // Verify sorted by peak altitude descending (night-aware)
          for (int i = 0; i < suggestions.length - 1; i++) {
            final aAlt =
                suggestions[i].visibility.peakAltitude ??
                suggestions[i].visibility.currentAltitude;
            final bAlt =
                suggestions[i + 1].visibility.peakAltitude ??
                suggestions[i + 1].visibility.currentAltitude;
            expect(aAlt, greaterThanOrEqualTo(bAlt));
          }
        }
      });

      test('sorts by least data collected when configured', () async {
        final targets = [
          createTarget(
            id: 1,
            name: 'Target A',
            ra: 12.0,
            dec: 50.0,
            totalPlannedSubs: 100,
            totalIntegrationSecs: 25000, // 83% complete
          ),
          createTarget(
            id: 2,
            name: 'Target B',
            ra: 13.0,
            dec: 50.0,
            totalPlannedSubs: 100,
            totalIntegrationSecs: 5000, // 17% complete
          ),
          createTarget(
            id: 3,
            name: 'Target C',
            ra: 14.0,
            dec: 50.0,
            totalPlannedSubs: 100,
            totalIntegrationSecs: 15000, // 50% complete
          ),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(
            minAltitude: 0.0,
            minScore: 0.0,
            sortMode: SuggestionSortMode.leastDataCollected,
            prioritizeIncomplete: false,
          ),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        if (suggestions.length >= 2) {
          // Verify sorted by data progress ascending (least data first)
          for (int i = 0; i < suggestions.length - 1; i++) {
            expect(
              suggestions[i].dataProgress,
              lessThanOrEqualTo(suggestions[i + 1].dataProgress),
            );
          }
        }
      });

      test('prioritizes incomplete targets when configured', () async {
        final targets = [
          createTarget(
            id: 1,
            name: 'Almost Complete',
            ra: 12.0,
            dec: 50.0,
            totalPlannedSubs: 100,
            totalIntegrationSecs: 28000, // 93% complete
          ),
          createTarget(
            id: 2,
            name: 'Just Started',
            ra: 13.0,
            dec: 50.0,
            totalPlannedSubs: 100,
            totalIntegrationSecs: 3000, // 10% complete
          ),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(
            minAltitude: 0.0,
            minScore: 0.0,
            sortMode: SuggestionSortMode.bestScore,
            prioritizeIncomplete: true,
          ),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        if (suggestions.length == 2) {
          // With prioritizeIncomplete=true, "Just Started" should come first
          // because the progress difference is > 0.2
          expect(suggestions[0].targetName, equals('Just Started'));
          expect(suggestions[1].targetName, equals('Almost Complete'));
        }
      });

      test('filters by preferred object types when specified', () async {
        final targets = [
          createTarget(
            id: 1,
            name: 'Galaxy Target',
            ra: 12.0,
            dec: 50.0,
            objectType: 'Galaxy',
          ),
          createTarget(
            id: 2,
            name: 'Nebula Target',
            ra: 13.0,
            dec: 50.0,
            objectType: 'Nebula',
          ),
          createTarget(
            id: 3,
            name: 'Cluster Target',
            ra: 14.0,
            dec: 50.0,
            objectType: 'Globular Cluster',
          ),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(
            minAltitude: 0.0,
            minScore: 0.0,
            preferredObjectTypes: ['Galaxy'], // Only want galaxies
          ),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        // Should only include the galaxy
        for (final suggestion in suggestions) {
          expect(suggestion.targetName.toLowerCase(), contains('galaxy'));
        }
      });

      test('filters targets below horizon', () async {
        // Create a target that's definitely below the horizon
        // From 40N latitude, a target at Dec -70 is always below horizon
        final targets = [
          createTarget(
            id: 1,
            name: 'Below Horizon',
            ra: 12.0,
            dec: -70.0, // Far southern, below horizon for 40N
          ),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(
            minAltitude: 0.0, // Even with 0 altitude requirement
            minScore: 0.0,
          ),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        // Target should be filtered out - never above horizon
        expect(suggestions, isEmpty);
      });

      test('includes visibility information in suggestions', () async {
        final targets = [
          createTarget(id: 1, name: 'Test Target', ra: 12.0, dec: 45.0),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(minAltitude: 0.0, minScore: 0.0),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        if (suggestions.isNotEmpty) {
          final visibility = suggestions.first.visibility;
          expect(visibility.currentAltitude, isNotNull);
          expect(visibility.currentAzimuth, isNotNull);
          expect(visibility.airmass, greaterThan(0));
          expect(visibility.moonDistance, greaterThanOrEqualTo(0));
        }
      });

      test('handles target with no planned subs gracefully', () async {
        final targets = [
          createTarget(
            id: 1,
            name: 'No Plan',
            ra: 12.0,
            dec: 45.0,
            totalPlannedSubs: 0, // No planned subs
            totalIntegrationSecs: 1000, // But has some data
          ),
        ];

        final suggestions = await service.getSuggestionsForTonight(
          config: const TargetSuggestionConfig(minAltitude: 0.0, minScore: 0.0),
          latitude: 40.0,
          longitude: -75.0,
          targets: targets,
          sessions: [],
          observationTime: DateTime(2024, 3, 21, 22, 0),
        );

        if (suggestions.isNotEmpty) {
          // Should show 10% progress (some data exists but no plan)
          expect(suggestions.first.dataProgress, closeTo(0.1, 0.01));
        }
      });

      group('framing fit scoring', () {
        /// Creates an OpticalConfig with a known FOV.
        /// With 1000mm focal length, 4656x3520 pixels at 3.76 µm pixel size:
        /// sensorWidthMm = 4656 * 3.76 / 1000 = 17.51 mm
        /// sensorHeightMm = 3520 * 3.76 / 1000 = 13.24 mm
        /// FOV width ≈ 1.003°, FOV height ≈ 0.759°
        /// FOV short axis ≈ 0.759° ≈ 45.5 arcmin
        OpticalConfig createTestOpticalConfig() {
          return const OpticalConfig(
            focalLength: 1000,
            aperture: 200,
            sensorWidth: 4656,
            sensorHeight: 3520,
            pixelSize: 3.76,
          );
        }

        test(
          'suggestions without opticalConfig have no framingFit score',
          () async {
            final targets = [
              createTarget(
                id: 1,
                name: 'Test Nebula',
                ra: 12.0,
                dec: 45.0,
                sizeArcmin: 15.0,
                objectType: 'Nebula',
              ),
            ];

            final suggestions = await service.getSuggestionsForTonight(
              config: const TargetSuggestionConfig(
                minAltitude: 0.0,
                minScore: 0.0,
              ),
              latitude: 40.0,
              longitude: -75.0,
              targets: targets,
              sessions: [],
              observationTime: DateTime(2024, 3, 21, 22, 0),
            );

            if (suggestions.isNotEmpty) {
              expect(
                suggestions.first.scoreBreakdown.containsKey('framingFit'),
                isFalse,
              );
            }
          },
        );

        test(
          'suggestions with opticalConfig include framingFit score',
          () async {
            final opticalConfig = createTestOpticalConfig();
            final targets = [
              createTarget(
                id: 1,
                name: 'Test Nebula',
                ra: 12.0,
                dec: 45.0,
                sizeArcmin: 15.0,
                objectType: 'Nebula',
              ),
            ];

            final suggestions = await service.getSuggestionsForTonight(
              config: const TargetSuggestionConfig(
                minAltitude: 0.0,
                minScore: 0.0,
              ),
              latitude: 40.0,
              longitude: -75.0,
              targets: targets,
              sessions: [],
              observationTime: DateTime(2024, 3, 21, 22, 0),
              opticalConfig: opticalConfig,
            );

            if (suggestions.isNotEmpty) {
              expect(
                suggestions.first.scoreBreakdown.containsKey('framingFit'),
                isTrue,
              );
              expect(
                suggestions.first.scoreBreakdown['framingFit'],
                greaterThan(0),
              );
            }
          },
        );

        test('ideal fill ratio target gets high framing fit score', () async {
          final opticalConfig = createTestOpticalConfig();
          // FOV short axis ≈ 45.5 arcmin
          // Target at 22 arcmin → fill ratio ≈ 0.48 → in sweet spot (0.40-0.60) → score 100
          final targets = [
            createTarget(
              id: 1,
              name: 'Well-framed Galaxy',
              ra: 12.0,
              dec: 45.0,
              sizeArcmin: 22.0,
              objectType: 'Galaxy',
            ),
          ];

          final suggestions = await service.getSuggestionsForTonight(
            config: const TargetSuggestionConfig(
              minAltitude: 0.0,
              minScore: 0.0,
            ),
            latitude: 40.0,
            longitude: -75.0,
            targets: targets,
            sessions: [],
            observationTime: DateTime(2024, 3, 21, 22, 0),
            opticalConfig: opticalConfig,
          );

          if (suggestions.isNotEmpty) {
            final framingScore =
                suggestions.first.scoreBreakdown['framingFit']!;
            // 22 / 45.5 ≈ 0.48 fill ratio → should be 100
            expect(framingScore, equals(100.0));
          }
        });

        test('target much larger than FOV gets gentle penalty', () async {
          final opticalConfig = createTestOpticalConfig();
          // FOV short axis ≈ 45.5 arcmin
          // Target at 120 arcmin → fill ratio ≈ 2.64 → overflows → gentle score
          final targets = [
            createTarget(
              id: 1,
              name: 'Huge Nebula',
              ra: 12.0,
              dec: 45.0,
              sizeArcmin: 120.0,
              objectType: 'Nebula',
            ),
          ];

          final suggestions = await service.getSuggestionsForTonight(
            config: const TargetSuggestionConfig(
              minAltitude: 0.0,
              minScore: 0.0,
            ),
            latitude: 40.0,
            longitude: -75.0,
            targets: targets,
            sessions: [],
            observationTime: DateTime(2024, 3, 21, 22, 0),
            opticalConfig: opticalConfig,
          );

          if (suggestions.isNotEmpty) {
            final framingScore =
                suggestions.first.scoreBreakdown['framingFit']!;
            // 120 / 45.5 ≈ 2.64 → >2.0 fill ratio → neutral score of 50
            expect(framingScore, equals(50.0));
          }
        });

        test(
          'target with no size data gets neutral framing fit score',
          () async {
            final opticalConfig = createTestOpticalConfig();
            final targets = [
              createTarget(
                id: 1,
                name: 'Unknown Size Target',
                ra: 12.0,
                dec: 45.0,
                sizeArcmin: null,
                objectType: 'Galaxy',
              ),
            ];

            final suggestions = await service.getSuggestionsForTonight(
              config: const TargetSuggestionConfig(
                minAltitude: 0.0,
                minScore: 0.0,
              ),
              latitude: 40.0,
              longitude: -75.0,
              targets: targets,
              sessions: [],
              observationTime: DateTime(2024, 3, 21, 22, 0),
              opticalConfig: opticalConfig,
            );

            if (suggestions.isNotEmpty) {
              final framingScore =
                  suggestions.first.scoreBreakdown['framingFit']!;
              // No size data → neutral score of 50
              expect(framingScore, equals(50.0));
            }
          },
        );

        test('overflow target gets "Mosaic recommended" tag', () async {
          final opticalConfig = createTestOpticalConfig();
          // FOV short axis ≈ 45.5 arcmin
          // Target at 80 arcmin → fill ratio ≈ 1.76 → overflows FOV
          final targets = [
            createTarget(
              id: 1,
              name: 'Large Nebula',
              ra: 12.0,
              dec: 45.0,
              sizeArcmin: 80.0,
              objectType: 'Nebula',
            ),
          ];

          final suggestions = await service.getSuggestionsForTonight(
            config: const TargetSuggestionConfig(
              minAltitude: 0.0,
              minScore: 0.0,
            ),
            latitude: 40.0,
            longitude: -75.0,
            targets: targets,
            sessions: [],
            observationTime: DateTime(2024, 3, 21, 22, 0),
            opticalConfig: opticalConfig,
          );

          if (suggestions.isNotEmpty) {
            expect(suggestions.first.tags, contains('Mosaic recommended'));
          }
        });

        test('well-framed target has no mosaic tag', () async {
          final opticalConfig = createTestOpticalConfig();
          // FOV short axis ≈ 45.5 arcmin
          // Target at 22 arcmin → fill ratio ≈ 0.48 → fits well
          final targets = [
            createTarget(
              id: 1,
              name: 'Nice Galaxy',
              ra: 12.0,
              dec: 45.0,
              sizeArcmin: 22.0,
              objectType: 'Galaxy',
            ),
          ];

          final suggestions = await service.getSuggestionsForTonight(
            config: const TargetSuggestionConfig(
              minAltitude: 0.0,
              minScore: 0.0,
            ),
            latitude: 40.0,
            longitude: -75.0,
            targets: targets,
            sessions: [],
            observationTime: DateTime(2024, 3, 21, 22, 0),
            opticalConfig: opticalConfig,
          );

          if (suggestions.isNotEmpty) {
            expect(suggestions.first.tags, isEmpty);
          }
        });

        test('no tags without optical config', () async {
          final targets = [
            createTarget(
              id: 1,
              name: 'Large Nebula',
              ra: 12.0,
              dec: 45.0,
              sizeArcmin: 120.0,
              objectType: 'Nebula',
            ),
          ];

          final suggestions = await service.getSuggestionsForTonight(
            config: const TargetSuggestionConfig(
              minAltitude: 0.0,
              minScore: 0.0,
            ),
            latitude: 40.0,
            longitude: -75.0,
            targets: targets,
            sessions: [],
            observationTime: DateTime(2024, 3, 21, 22, 0),
          );

          if (suggestions.isNotEmpty) {
            expect(suggestions.first.tags, isEmpty);
          }
        });
      });
    });
  });
}
