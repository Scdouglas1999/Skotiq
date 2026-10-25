import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_bridge/skotiq_bridge.dart' as bridge;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/models/mount_site_reconciliation.dart';
import 'package:skotiq_core/src/services/mount_site/mount_site_reconciler.dart';

/// A backend that answers only the site/time calls; anything else is a test
/// bug and should throw rather than silently return null.
class _SiteBackend implements DeviceBackend {
  _SiteBackend({
    required this.capabilities,
    this.site,
    this.time,
    this.siteThrows,
    this.timeThrows,
  });

  final bridge.MountSiteCapabilities capabilities;
  final bridge.MountSite? site;
  final bridge.MountTimeInfo? time;
  final Object? siteThrows;
  final Object? timeThrows;

  final List<String> calls = <String>[];

  @override
  Future<bridge.MountSiteCapabilities> mountSiteCapabilities(String d) async =>
      capabilities;

  @override
  Future<bridge.MountSite> mountGetSite(String d) async {
    if (siteThrows != null) throw siteThrows!;
    return site!;
  }

  @override
  Future<bridge.MountTimeInfo> mountGetTime(String d) async {
    if (timeThrows != null) throw timeThrows!;
    return time!;
  }

  @override
  Future<void> mountSetSite(
    String d,
    double lat,
    double lon,
    double? el,
  ) async {
    calls.add('setSite($lat,$lon)');
  }

  @override
  Future<void> mountSetTime(String d, int utc, double offset) async {
    calls.add('setTime($utc,$offset)');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
    '${invocation.memberName} is not part of this test',
  );
}

bridge.MountSiteCapabilities _caps({
  bool readSite = true,
  bool writeSite = true,
  bool readTime = true,
  bool writeTime = true,
}) => bridge.MountSiteCapabilities(
  canReadSite: readSite,
  canWriteSite: writeSite,
  canReadTime: readTime,
  canWriteTime: writeTime,
);

MountSiteReconciliation _comparison({
  required double mountLat,
  required double mountLon,
  int? mountUtc,
  bridge.MountSiteCapabilities? capabilities,
}) => MountSiteReconciliation(
  deviceId: 'mount',
  deviceName: 'Test Mount',
  capabilities: capabilities ?? _caps(),
  computerLatitudeDeg: 40.0,
  computerLongitudeDeg: -75.0,
  computerElevationM: 100,
  computerUtcSeconds: 1000000,
  computerUtcOffsetHours: -4,
  mountLatitudeDeg: mountLat,
  mountLongitudeDeg: mountLon,
  mountUtcSeconds: mountUtc ?? 1000000,
  mountUtcOffsetHours: -4,
);

void main() {
  group('what counts as a disagreement', () {
    test('a difference inside the LX200 wire resolution is agreement', () {
      // The wire carries arcminutes, so half an arcminute of difference is
      // not something any amount of syncing could resolve — reporting it
      // would give the operator a card they can never make go away.
      final same = _comparison(mountLat: 40.0 + 0.5 / 60.0, mountLon: -75.0);
      expect(same.siteDiffers, isFalse);
    });

    test('a difference beyond the wire resolution is reported', () {
      final moved = _comparison(mountLat: 40.05, mountLon: -75.0);
      expect(moved.siteDiffers, isTrue);
    });

    test('a clock inside the tolerance is agreement, beyond it is not', () {
      expect(
        _comparison(mountLat: 40, mountLon: -75, mountUtc: 1000020).timeDiffers,
        isFalse,
      );
      expect(
        _comparison(mountLat: 40, mountLon: -75, mountUtc: 1000100).timeDiffers,
        isTrue,
      );
    });

    test('a hemisphere sign error is a disagreement, not a rounding blip', () {
      // The failure mode that matters most: west read as east.
      final flipped = _comparison(mountLat: 40.0, mountLon: 75.0);
      expect(flipped.siteDiffers, isTrue);
      expect(flipped.longitudeDeltaDeg, closeTo(150.0, 1e-9));
    });
  });

  group('directions the driver cannot honour', () {
    test(
      'a mount that can read the clock but not set it cannot be pushed to',
      () {
        final alpacaLike = _comparison(
          mountLat: 40.0,
          mountLon: -75.0,
          mountUtc: 1000100,
          capabilities: _caps(writeTime: false),
        );
        expect(alpacaLike.timeDiffers, isTrue);
        expect(
          alpacaLike.canApply(MountSiteSyncDirection.computerToMount),
          isFalse,
        );
        expect(
          alpacaLike.unavailableReason(MountSiteSyncDirection.computerToMount),
          contains('but not set it'),
        );
      },
    );

    test('an available direction has no reason text', () {
      final ordinary = _comparison(mountLat: 40.05, mountLon: -75.0);
      expect(ordinary.canApply(MountSiteSyncDirection.computerToMount), isTrue);
      expect(
        ordinary.unavailableReason(MountSiteSyncDirection.computerToMount),
        isNull,
      );
    });
  });

  group('reading the mount', () {
    test('a site read failure is carried, not thrown', () async {
      final backend = _SiteBackend(
        capabilities: _caps(),
        siteThrows: StateError('serial timeout'),
        time: const bridge.MountTimeInfo(
          utcUnixSeconds: 1000000,
          utcOffsetHours: -4,
        ),
      );
      final reconciler = MountSiteReconciler(
        backend: backend,
        writeComputerLocation: (a, b, c) async {},
      );

      final comparison = await reconciler.compare(
        deviceId: 'mount',
        deviceName: 'Test Mount',
        computerLatitudeDeg: 40,
        computerLongitudeDeg: -75,
      );

      expect(comparison.hasMountSite, isFalse);
      expect(comparison.siteReadError, contains('serial timeout'));
      // The clock still got read: one failure must not lose the other answer.
      expect(comparison.hasMountTime, isTrue);
    });

    test('a driver that cannot read a site is not asked for one', () async {
      final backend = _SiteBackend(
        capabilities: _caps(readSite: false, writeSite: false),
        time: const bridge.MountTimeInfo(
          utcUnixSeconds: 1000000,
          utcOffsetHours: -4,
        ),
      );
      final reconciler = MountSiteReconciler(
        backend: backend,
        writeComputerLocation: (a, b, c) async {},
      );

      // mountGetSite throws UnimplementedError if called, so reaching the end
      // proves it was skipped rather than attempted and swallowed.
      final comparison = await reconciler.compare(
        deviceId: 'mount',
        deviceName: 'Test Mount',
        computerLatitudeDeg: 40,
        computerLongitudeDeg: -75,
      );
      expect(comparison.hasMountSite, isFalse);
      expect(comparison.siteReadError, isNull);
    });

    // The reciprocal of the two failures above: the pair of reads that BOTH
    // succeed is what every disagreement card is drawn from, and nothing here
    // exercised it -- `site` was a constructor parameter no test ever gave.
    test(
      'both reads succeeding carry the mount\'s own site and clock',
      () async {
        final backend = _SiteBackend(
          capabilities: _caps(),
          site: const bridge.MountSite(
            latitudeDeg: 40.05,
            longitudeDeg: -75.0,
            elevationM: 120,
          ),
          time: const bridge.MountTimeInfo(
            utcUnixSeconds: 1000000,
            utcOffsetHours: -4,
          ),
        );
        final reconciler = MountSiteReconciler(
          backend: backend,
          writeComputerLocation: (a, b, c) async {},
        );

        final comparison = await reconciler.compare(
          deviceId: 'mount',
          deviceName: 'Test Mount',
          computerLatitudeDeg: 40,
          computerLongitudeDeg: -75,
        );

        expect(comparison.hasMountSite, isTrue);
        expect(comparison.mountLatitudeDeg, closeTo(40.05, 1e-9));
        expect(comparison.mountLongitudeDeg, closeTo(-75.0, 1e-9));
        expect(comparison.siteReadError, isNull);
        expect(comparison.hasMountTime, isTrue);
        expect(comparison.timeReadError, isNull);
      },
    );

    // The mirror of 'a site read failure is carried, not thrown': the clock is
    // the read that fails, and the site must survive it.
    test('a clock read failure is carried, not thrown', () async {
      final backend = _SiteBackend(
        capabilities: _caps(),
        site: const bridge.MountSite(
          latitudeDeg: 40.05,
          longitudeDeg: -75.0,
          elevationM: 120,
        ),
        timeThrows: StateError('clock timeout'),
      );
      final reconciler = MountSiteReconciler(
        backend: backend,
        writeComputerLocation: (a, b, c) async {},
      );

      final comparison = await reconciler.compare(
        deviceId: 'mount',
        deviceName: 'Test Mount',
        computerLatitudeDeg: 40,
        computerLongitudeDeg: -75,
      );

      expect(comparison.hasMountTime, isFalse);
      expect(comparison.timeReadError, contains('clock timeout'));
      expect(comparison.hasMountSite, isTrue);
    });
  });

  group('applying a direction', () {
    test(
      'adopting the mount moves the site and never the computer clock',
      () async {
        var wroteLocation = false;
        final backend = _SiteBackend(capabilities: _caps());
        final reconciler = MountSiteReconciler(
          backend: backend,
          writeComputerLocation: (lat, lon, el) async {
            wroteLocation = true;
            expect(lat, closeTo(40.05, 1e-9));
          },
        );

        final failures = await reconciler.apply(
          _comparison(mountLat: 40.05, mountLon: -75.0, mountUtc: 1000100),
          MountSiteSyncDirection.mountToComputer,
        );

        expect(failures, isEmpty);
        expect(wroteLocation, isTrue);
        // Setting the computer's clock would mean setting the OS clock, which
        // this app has no business doing.
        expect(backend.calls, isEmpty);
      },
    );

    test('pushing to the mount skips what the driver cannot take', () async {
      final backend = _SiteBackend(capabilities: _caps(writeTime: false));
      final reconciler = MountSiteReconciler(
        backend: backend,
        writeComputerLocation: (a, b, c) async {},
      );

      await reconciler.apply(
        _comparison(
          mountLat: 40.05,
          mountLon: -75.0,
          mountUtc: 1000100,
          capabilities: _caps(writeTime: false),
        ),
        MountSiteSyncDirection.computerToMount,
      );

      expect(backend.calls.where((c) => c.startsWith('setSite')), hasLength(1));
      expect(backend.calls.where((c) => c.startsWith('setTime')), isEmpty);
    });
  });

  group('site elevation', () {
    MountSiteReconciliation withElevations({
      double? computer,
      double? mount,
      double mountLat = 40.0,
    }) => MountSiteReconciliation(
      deviceId: 'mount',
      deviceName: 'Test Mount',
      capabilities: _caps(),
      computerLatitudeDeg: 40.0,
      computerLongitudeDeg: -75.0,
      computerElevationM: computer,
      computerUtcSeconds: 1000000,
      computerUtcOffsetHours: -4,
      mountLatitudeDeg: mountLat,
      mountLongitudeDeg: -75.0,
      mountElevationM: mount,
      mountUtcSeconds: 1000000,
      mountUtcOffsetHours: -4,
    );

    test('an unset elevation takes the mount\'s at the same site', () {
      expect(withElevations(computer: 0, mount: 112).elevationToAdopt, 112);
      expect(withElevations(mount: 112).elevationToAdopt, 112);
    });

    test('a set elevation is never overwritten', () {
      expect(withElevations(computer: 95, mount: 112).elevationToAdopt, isNull);
    });

    test('a mount with no elevation, or at another site, offers none', () {
      expect(withElevations(computer: 0, mount: 0).elevationToAdopt, isNull);
      expect(withElevations(computer: 0).elevationToAdopt, isNull);
      expect(
        withElevations(computer: 0, mount: 112, mountLat: 41).elevationToAdopt,
        isNull,
      );
    });
  });
}
