// A fresh install presents 0°, 0° as the observing site.
//
// Live repro (release bundle, empty SKOTIQ_DATABASE_DIR): the very first
// launch writes the site before the user has been asked anything —
// `db/profiles/settings.json` holds `{"location":{"latitude":0.0,
// "longitude":0.0,"elevation":0.0}}` and `app_settings` holds
// observer_latitude/longitude/elevation = 0.0 — while the onboarding wizard is
// still on step 1 of 13.
//
// `latitude` and `longitude` are non-nullable doubles, so the model itself
// cannot say "the user never chose"; every surface re-derived that from the
// two numbers, the copies drifted, and Settings → Location ended up printing
// "0 °" as a settled coordinate while the Dashboard beside it said "Set an
// observing location".
//
// [siteLocationIsSet] is now the one definition of the rule and
// [AppSettingsState.observerSite] is the nullable value surfaces should read.
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart';

void main() {
  group('siteLocationIsSet', () {
    test('the origin is the not-set sentinel', () {
      expect(siteLocationIsSet(0.0, 0.0), isFalse);
    });

    test('any configured component counts as set', () {
      expect(siteLocationIsSet(40.7, 0.0), isTrue);
      expect(siteLocationIsSet(0.0, -74.0), isTrue);
      expect(siteLocationIsSet(-33.9, 151.2), isTrue);
    });

    test('a millionth of a degree claims the origin back', () {
      // The documented escape hatch for an observer genuinely at 0,0 — the
      // Location editor exposes six decimals.
      expect(siteLocationIsSet(0.000001, 0.0), isTrue);
    });
  });

  group('AppSettingsState observer site', () {
    test('a default (fresh-install) state has no site', () {
      const settings = AppSettingsState();
      // What the fresh profile actually stores.
      expect(settings.latitude, 0.0);
      expect(settings.longitude, 0.0);
      // ...and what the model must say about it.
      expect(settings.hasObserverLocation, isFalse);
      expect(settings.observerSite, isNull);
    });

    test('a configured state exposes the site', () {
      const settings = AppSettingsState(
        latitude: 44.0581,
        longitude: -121.3153,
        elevation: 1100.0,
      );
      expect(settings.hasObserverLocation, isTrue);
      final site = settings.observerSite;
      expect(site, isNotNull);
      expect(site!.latitude, 44.0581);
      expect(site.longitude, -121.3153);
      expect(site.elevation, 1100.0);
    });

    test('elevation alone is not a site', () {
      // Sea level is a legitimate elevation, and an elevation without
      // coordinates still locates nobody.
      const settings = AppSettingsState(elevation: 250.0);
      expect(settings.hasObserverLocation, isFalse);
      expect(settings.observerSite, isNull);
    });
  });
}
