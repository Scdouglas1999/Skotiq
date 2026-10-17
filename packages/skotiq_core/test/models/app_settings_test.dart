import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/models/settings/app_settings.dart';

void main() {
  group('ObserverLocation', () {
    test('creates with required fields', () {
      const location = ObserverLocation(
        latitude: 45.5,
        longitude: -122.6,
        elevation: 100.0,
      );

      expect(location.latitude, 45.5);
      expect(location.longitude, -122.6);
      expect(location.elevation, 100.0);
    });

    test('serializes to JSON', () {
      const location = ObserverLocation(
        latitude: 45.5,
        longitude: -122.6,
        elevation: 100.0,
      );

      final json = location.toJson();
      expect(json['latitude'], 45.5);
      expect(json['longitude'], -122.6);
      expect(json['elevation'], 100.0);
    });

    test('deserializes from JSON', () {
      final json = {'latitude': 45.5, 'longitude': -122.6, 'elevation': 100.0};

      final location = ObserverLocation.fromJson(json);
      expect(location.latitude, 45.5);
      expect(location.longitude, -122.6);
      expect(location.elevation, 100.0);
    });

    test('equality works', () {
      const loc1 = ObserverLocation(
        latitude: 45.5,
        longitude: -122.6,
        elevation: 100.0,
      );
      const loc2 = ObserverLocation(
        latitude: 45.5,
        longitude: -122.6,
        elevation: 100.0,
      );
      const loc3 = ObserverLocation(
        latitude: 46.0,
        longitude: -122.6,
        elevation: 100.0,
      );

      expect(loc1, equals(loc2));
      expect(loc1, isNot(equals(loc3)));
    });
  });

  group('AppSettings', () {
    test('has sensible defaults', () {
      const settings = AppSettings();

      expect(settings.theme, 'dark');
      expect(settings.language, 'en');
      expect(settings.autoConnect, true);
      expect(settings.indiServerHost, 'localhost');
      expect(settings.indiServerPort, 7624);
      expect(settings.alpacaServerHost, 'localhost');
      expect(settings.alpacaServerPort, 11111);
    });

    test('creates with custom values', () {
      const settings = AppSettings(
        theme: 'light',
        latitude: 45.5,
        longitude: -122.6,
        indiServerHost: '192.168.1.100',
        indiServerPort: 7625,
      );

      expect(settings.theme, 'light');
      expect(settings.latitude, 45.5);
      expect(settings.longitude, -122.6);
      expect(settings.indiServerHost, '192.168.1.100');
      expect(settings.indiServerPort, 7625);
    });

    test('serializes to JSON', () {
      const settings = AppSettings(
        theme: 'dark',
        latitude: 45.5,
        longitude: -122.6,
        indiServerHost: 'localhost',
        indiServerPort: 7624,
      );

      final json = settings.toJson();
      expect(json['theme'], 'dark');
      expect(json['latitude'], 45.5);
      expect(json['longitude'], -122.6);
      expect(json['indiServerHost'], 'localhost');
      expect(json['indiServerPort'], 7624);
    });

    test('deserializes from JSON', () {
      final json = {
        'theme': 'light',
        'language': 'en',
        'autoConnect': false,
        'latitude': 45.5,
        'longitude': -122.6,
        'elevation': 100.0,
        'indiServerHost': '192.168.1.100',
        'indiServerPort': 7625,
        'alpacaServerHost': 'localhost',
        'alpacaServerPort': 11111,
      };

      final settings = AppSettings.fromJson(json);
      expect(settings.theme, 'light');
      expect(settings.autoConnect, false);
      expect(settings.latitude, 45.5);
      expect(settings.longitude, -122.6);
      expect(settings.indiServerHost, '192.168.1.100');
      expect(settings.indiServerPort, 7625);
    });

    test('copyWith creates new instance', () {
      const settings = AppSettings();
      final updated = settings.copyWith(theme: 'light', latitude: 50.0);

      expect(settings.theme, 'dark'); // Original unchanged
      expect(updated.theme, 'light'); // New value
      expect(updated.latitude, 50.0);
      expect(updated.language, 'en'); // Preserved
    });
  });

  group('AppSettingsExtension', () {
    test('effectiveLatitude returns location.latitude when available', () {
      const settings = AppSettings(
        location: ObserverLocation(
          latitude: 45.5,
          longitude: -122.6,
          elevation: 100.0,
        ),
        latitude: 0.0, // Direct field should be ignored
      );

      expect(settings.effectiveLatitude, 45.5);
    });

    test('effectiveLatitude falls back to latitude field', () {
      const settings = AppSettings(latitude: 45.5);

      expect(settings.effectiveLatitude, 45.5);
    });

    test('effectiveLongitude returns location.longitude when available', () {
      const settings = AppSettings(
        location: ObserverLocation(
          latitude: 45.5,
          longitude: -122.6,
          elevation: 100.0,
        ),
      );

      expect(settings.effectiveLongitude, -122.6);
    });

    test('effectiveElevation returns location.elevation when available', () {
      const settings = AppSettings(
        location: ObserverLocation(
          latitude: 45.5,
          longitude: -122.6,
          elevation: 100.0,
        ),
      );

      expect(settings.effectiveElevation, 100.0);
    });
  });
}
