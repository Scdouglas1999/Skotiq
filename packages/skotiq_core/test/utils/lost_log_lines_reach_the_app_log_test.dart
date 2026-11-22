// Log lines from core that used to go to `package:logging` or
// `dart:developer`, where nothing in a shipping build listens, reach the app
// log (the log file, the Log Viewer and the remote tail).

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_core/src/backend/ffi_backend.dart';
import 'package:skotiq_core/src/database/database.dart' as db;
import 'package:skotiq_core/src/database/rows/equipment_profile_rows.dart';
import 'package:skotiq_core/src/services/site_positioning/geolocation_service.dart';
import 'package:skotiq_core/utils.dart';

import '../harness/captured_log.dart';

void main() {
  test('an unreadable stored profile field is logged', () async {
    final appLog = await captureAppLog();
    final row = db.DbEquipmentProfile(
      id: 5,
      name: 'Host Rig',
      description: null,
      cameraId: null,
      mountId: null,
      focuserId: null,
      filterWheelId: null,
      guiderId: null,
      rotatorId: null,
      domeId: null,
      weatherId: null,
      safetyMonitorId: 'ascom:safety:0',
      switchId: 'ascom:switch:0',
      coverCalibratorId: null,
      focalLength: 0.0,
      aperture: 0.0,
      focalRatio: null,
      defaultGain: null,
      defaultOffset: null,
      defaultBinX: 1,
      defaultBinY: 1,
      defaultCoolingTemp: null,
      coolOnConnect: false,
      defaultCenteringExposure: null,
      filterNames: 'not a json list',
      filterFocusOffsets: null,
      meridianFlipOverrides: null,
      cameraName: null,
      mountName: null,
      focuserName: null,
      filterWheelName: null,
      guiderName: null,
      rotatorName: null,
      safetyMonitorName: 'Roof Switch Safety',
      switchName: 'Mains',
      telescopeName: null,
      telescopeFocalLength: null,
      telescopeAperture: null,
      profileIcon: null,
      profileColor: null,
      sortOrder: 0,
      isDefault: false,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 6, 1),
      isActive: false,
    );

    expect(row.toModel().filterNames, isEmpty);

    final lines = logFrom(appLog, 'ProfilesProvider');
    expect(lines, hasLength(1));
    expect(lines.single.level, LogLevel.warning);
    expect(
      lines.single.message,
      startsWith('Failed to parse filterNames JSON for profile "Host Rig"'),
    );
  });

  test('a failed native capability read is logged', () async {
    final appLog = await captureAppLog();
    final backend = FfiBackend();
    addTearDown(backend.dispose);

    expect(await backend.getCameraCapabilities('camera-1'), isNull);

    final lines = logFrom(appLog, 'FfiBackend');
    expect(
      lines.where(
        (e) =>
            e.level == LogLevel.warning &&
            e.message.startsWith('Failed to get camera capabilities'),
      ),
      hasLength(1),
    );
  });

  test('a place search that cannot reach the service is logged', () async {
    final appLog = await captureAppLog();
    final saved = GeolocationService.clientFactory;
    addTearDown(() => GeolocationService.clientFactory = saved);
    GeolocationService.clientFactory = () => MockClient(
      (request) async => throw http.ClientException('offline', request.url),
    );

    await expectLater(
      GeolocationService.searchPlaces('Cherry Springs'),
      throwsA(isA<PlaceSearchUnavailable>()),
    );

    final lines = logFrom(appLog, 'GeolocationService');
    expect(lines, hasLength(1));
    expect(lines.single.level, LogLevel.warning);
    expect(lines.single.message, contains('Place search failed'));
  });
}
