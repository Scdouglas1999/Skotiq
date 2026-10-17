import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/readiness/readiness_models.dart';

/// Convenience builder for the "everything is good" baseline. Individual
/// tests flip one flag at a time so each rule is exercised in isolation.
ReadinessReport _report({
  bool cameraConnected = true,
  bool mountConnected = true,
  bool hasProfile = true,
  bool locationSet = true,
  bool outputPathSet = true,
  bool plateSolverReady = true,
  bool darkLibraryHasCoverage = true,
  bool focusKnown = true,
  List<String> offlineProfileDevices = const <String>[],
  bool hasActiveProfile = true,
  // Baseline = a populated profile (camera, mount + two accessories), so the
  // "all green" default is a genuine pass rather than a vacuous one.
  int assignedProfileDeviceCount = 4,
  int otherAssignedProfileDeviceCount = 2,
}) {
  return buildReadinessReport(
    cameraConnected: cameraConnected,
    mountConnected: mountConnected,
    hasProfile: hasProfile,
    locationSet: locationSet,
    outputPathSet: outputPathSet,
    plateSolverReady: plateSolverReady,
    darkLibraryHasCoverage: darkLibraryHasCoverage,
    focusKnown: focusKnown,
    offlineProfileDevices: offlineProfileDevices,
    hasActiveProfile: hasActiveProfile,
    assignedProfileDeviceCount: assignedProfileDeviceCount,
    otherAssignedProfileDeviceCount: otherAssignedProfileDeviceCount,
  );
}

void main() {
  group('ReadinessLevel', () {
    test('severity orders blocked > caution > ready', () {
      expect(
        ReadinessLevel.blocked.severity,
        greaterThan(ReadinessLevel.caution.severity),
      );
      expect(
        ReadinessLevel.caution.severity,
        greaterThan(ReadinessLevel.ready.severity),
      );
    });

    test('worstOf returns the more severe level', () {
      expect(
        ReadinessLevel.ready.worstOf(ReadinessLevel.caution),
        ReadinessLevel.caution,
      );
      expect(
        ReadinessLevel.caution.worstOf(ReadinessLevel.blocked),
        ReadinessLevel.blocked,
      );
      expect(
        ReadinessLevel.blocked.worstOf(ReadinessLevel.ready),
        ReadinessLevel.blocked,
      );
      // Tie returns the receiver.
      expect(
        ReadinessLevel.caution.worstOf(ReadinessLevel.caution),
        ReadinessLevel.caution,
      );
    });

    test('each level has a label', () {
      for (final level in ReadinessLevel.values) {
        expect(level.label, isNotEmpty);
      }
    });
  });

  group('buildReadinessReport — all green', () {
    test('all-true inputs produce overall ready and every item ready', () {
      final report = _report();

      expect(report.overall, ReadinessLevel.ready);
      expect(report.summaryLabel, 'Ready to image');
      expect(report.isReadyToImage, isTrue);
      expect(report.blockedItems, isEmpty);
      expect(report.cautionItems, isEmpty);

      // Exactly the six defined items, all ready, all without a fix route.
      expect(report.items.length, ReadinessItemId.values.length);
      for (final id in ReadinessItemId.values) {
        final item = report.itemFor(id);
        expect(item, isNotNull, reason: 'missing item for $id');
        expect(
          item!.level,
          ReadinessLevel.ready,
          reason: '$id should be ready',
        );
        expect(item.fixRoute, isNull, reason: '$id ready -> no fix route');
        expect(item.fixLabel, isNull, reason: '$id ready -> no fix label');
        expect(item.isReady, isTrue);
      }
    });
  });

  group('criticalDevices — fail-closed', () {
    test(
      'camera disconnected blocks the whole report (explicit fail-closed)',
      () {
        final report = _report(cameraConnected: false);

        final critical = report.itemFor(ReadinessItemId.criticalDevices);
        expect(critical, isNotNull);
        // The one truly-critical device being down must be BLOCKED, never
        // caution and never silently ready.
        expect(critical!.level, ReadinessLevel.blocked);
        expect(critical.fixRoute, '/equipment');
        expect(critical.fixLabel, isNotNull);

        // And it must drag the overall report to blocked.
        expect(report.overall, ReadinessLevel.blocked);
        expect(report.summaryLabel, 'Not ready');
        expect(report.isReadyToImage, isFalse);
        expect(
          report.blockedItems.map((i) => i.id),
          contains(ReadinessItemId.criticalDevices),
        );
      },
    );

    test('no profile blocks the report regardless of camera', () {
      final report = _report(hasProfile: false, cameraConnected: true);

      final critical = report.itemFor(ReadinessItemId.criticalDevices)!;
      expect(critical.level, ReadinessLevel.blocked);
      expect(critical.fixRoute, '/equipment');
      expect(report.overall, ReadinessLevel.blocked);
    });

    test('only mount missing is caution, not blocked', () {
      final report = _report(mountConnected: false);

      final critical = report.itemFor(ReadinessItemId.criticalDevices)!;
      expect(critical.level, ReadinessLevel.caution);
      expect(critical.fixRoute, '/equipment');

      // No item is blocked; overall is caution.
      expect(report.blockedItems, isEmpty);
      expect(report.overall, ReadinessLevel.caution);
      expect(report.summaryLabel, 'Almost ready');
      expect(report.isReadyToImage, isTrue);
    });

    test('camera connected + mount connected + profile is ready', () {
      final report = _report();
      final critical = report.itemFor(ReadinessItemId.criticalDevices)!;
      expect(critical.level, ReadinessLevel.ready);
    });

    test('a disconnected mount is named even when the camera is also down', () {
      // The mount is deliberately excluded from the profile-devices item
      // ("already covered by critical devices"), so a critical-devices item
      // that reports only the camera would drop the mount from the whole
      // readiness report.
      final report = _report(cameraConnected: false, mountConnected: false);
      final critical = report.itemFor(ReadinessItemId.criticalDevices)!;

      expect(critical.level, ReadinessLevel.blocked);
      expect(critical.detail.toLowerCase(), contains('mount'));
      expect(critical.detail.toLowerCase(), contains('camera'));
    });

    test('no profile takes precedence over a disconnected camera message', () {
      // Both bad: profile-missing branch should win (it is checked first and
      // describes the more fundamental problem).
      final report = _report(hasProfile: false, cameraConnected: false);
      final critical = report.itemFor(ReadinessItemId.criticalDevices)!;
      expect(critical.level, ReadinessLevel.blocked);
      expect(critical.detail, contains('profile'));
    });
  });

  group('location — blocking', () {
    test('location unset blocks the report', () {
      final report = _report(locationSet: false);
      final item = report.itemFor(ReadinessItemId.location)!;
      expect(item.level, ReadinessLevel.blocked);
      expect(item.fixRoute, '/settings');
      expect(report.overall, ReadinessLevel.blocked);
    });
  });

  group('outputPath — blocking', () {
    test('output path unset blocks the report', () {
      final report = _report(outputPathSet: false);
      final item = report.itemFor(ReadinessItemId.outputPath)!;
      expect(item.level, ReadinessLevel.blocked);
      expect(item.fixRoute, '/settings');
      expect(report.overall, ReadinessLevel.blocked);
    });
  });

  group('non-blocking checks never produce blocked on their own', () {
    test('plate solver not ready is caution only', () {
      final report = _report(plateSolverReady: false);
      final item = report.itemFor(ReadinessItemId.plateSolver)!;
      expect(item.level, ReadinessLevel.caution);
      expect(item.fixRoute, '/settings/plate-solving');
      expect(report.blockedItems, isEmpty);
      expect(report.overall, ReadinessLevel.caution);
    });

    test('dark library no coverage is caution only', () {
      final report = _report(darkLibraryHasCoverage: false);
      final item = report.itemFor(ReadinessItemId.darkLibrary)!;
      expect(item.level, ReadinessLevel.caution);
      expect(item.fixRoute, '/settings');
      expect(report.blockedItems, isEmpty);
      expect(report.overall, ReadinessLevel.caution);
    });

    test('focus unknown is caution only', () {
      final report = _report(focusKnown: false);
      final item = report.itemFor(ReadinessItemId.focusState)!;
      expect(item.level, ReadinessLevel.caution);
      expect(item.fixRoute, '/equipment');
      expect(report.blockedItems, isEmpty);
      expect(report.overall, ReadinessLevel.caution);
    });

    test(
      'all three soft checks failing together stays caution, not blocked',
      () {
        final report = _report(
          plateSolverReady: false,
          darkLibraryHasCoverage: false,
          focusKnown: false,
        );
        expect(report.blockedItems, isEmpty);
        expect(report.cautionItems.length, 3);
        expect(report.overall, ReadinessLevel.caution);
      },
    );
  });

  group('profileDevices — no vacuous green over an empty profile', () {
    test('an empty profile is caution, not an all-connected pass', () {
      // A profile with nothing assigned has an empty offline set, which used to
      // satisfy "every device is connected" and render GREEN on a fresh install
      // with nothing connected at all.
      final report = _report(
        assignedProfileDeviceCount: 0,
        otherAssignedProfileDeviceCount: 0,
      );
      final item = report.itemFor(ReadinessItemId.profileDevices)!;
      expect(item.level, ReadinessLevel.caution);
      expect(item.detail, contains('No devices are assigned'));
      expect(item.detail, isNot(contains('is connected')));
      expect(item.fixRoute, '/equipment');
    });

    test('no active profile does not claim assignments are connected', () {
      final report = _report(
        hasActiveProfile: false,
        assignedProfileDeviceCount: 0,
        otherAssignedProfileDeviceCount: 0,
      );
      final item = report.itemFor(ReadinessItemId.profileDevices)!;
      expect(item.detail, contains('No equipment profile is active'));
      expect(item.detail, isNot(contains('is connected')));
    });

    test(
      'camera+mount-only profile says so instead of claiming accessories',
      () {
        final report = _report(
          assignedProfileDeviceCount: 2,
          otherAssignedProfileDeviceCount: 0,
        );
        final item = report.itemFor(ReadinessItemId.profileDevices)!;
        expect(item.level, ReadinessLevel.ready);
        expect(item.detail, contains('no accessories'));
      },
    );

    test('a populated profile with everything online still reads ready', () {
      final report = _report();
      final item = report.itemFor(ReadinessItemId.profileDevices)!;
      expect(item.level, ReadinessLevel.ready);
      expect(item.detail, contains('Every accessory assigned'));
    });
  });

  group('overall reduction is fail-closed', () {
    test('blocked dominates caution', () {
      // A blocking item (location) plus a caution item (focus) -> blocked.
      final report = _report(locationSet: false, focusKnown: false);
      expect(report.overall, ReadinessLevel.blocked);
    });

    test('empty report is blocked, never ready', () {
      const report = ReadinessReport(items: []);
      expect(report.overall, ReadinessLevel.blocked);
      expect(report.isReadyToImage, isFalse);
      expect(report.summaryLabel, 'Not ready');
    });
  });

  group('value equality (for provider de-dup)', () {
    test('identical inputs produce equal reports and equal hashCodes', () {
      final a = _report();
      final b = _report();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing inputs produce unequal reports', () {
      final a = _report();
      final b = _report(cameraConnected: false);
      expect(a, isNot(equals(b)));
    });

    test('ReadinessItem equality holds for identical fields', () {
      const a = ReadinessItem(
        id: ReadinessItemId.location,
        title: 'Observing location',
        detail: 'detail',
        level: ReadinessLevel.ready,
      );
      const b = ReadinessItem(
        id: ReadinessItemId.location,
        title: 'Observing location',
        detail: 'detail',
        level: ReadinessLevel.ready,
      );
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('ReadinessItem invariants', () {
    test('fixRoute and fixLabel are paired across all generated items', () {
      // Drive every branch by flipping each flag false; assert the invariant
      // holds for whatever item set is produced.
      final reports = <ReadinessReport>[
        _report(),
        _report(hasProfile: false),
        _report(cameraConnected: false),
        _report(mountConnected: false),
        _report(locationSet: false),
        _report(outputPathSet: false),
        _report(plateSolverReady: false),
        _report(darkLibraryHasCoverage: false),
        _report(focusKnown: false),
      ];
      for (final report in reports) {
        for (final item in report.items) {
          expect(
            (item.fixRoute == null),
            (item.fixLabel == null),
            reason: 'fixRoute/fixLabel pairing violated for ${item.id}',
          );
          // Ready items never carry a fix; non-ready items always do here.
          if (item.level == ReadinessLevel.ready) {
            expect(item.hasFix, isFalse, reason: '${item.id} ready has fix');
          } else {
            expect(item.hasFix, isTrue, reason: '${item.id} non-ready no fix');
          }
        }
      }
    });
  });
}
