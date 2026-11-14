import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:skotiq_planetarium/src/services/geolocation_service.dart';

class _StalledPlatform extends GeolocatorPlatform {
  _StalledPlatform(this.stage);

  final String stage;

  @override
  Future<bool> isLocationServiceEnabled() => stage == 'service'
      ? Completer<bool>().future
      : Future.value(stage != 'disabled');

  @override
  Future<LocationPermission> checkPermission() => stage == 'permission'
      ? Completer<LocationPermission>().future
      : Future.value(
          stage == 'request'
              ? LocationPermission.denied
              : LocationPermission.whileInUse,
        );

  @override
  Future<LocationPermission> requestPermission() =>
      Completer<LocationPermission>().future;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) =>
      Completer<Position>().future;
}

class _LatePlatform extends _StalledPlatform {
  _LatePlatform() : super('service');

  final service = Completer<bool>();
  var permissionChecks = 0;

  @override
  Future<bool> isLocationServiceEnabled() => service.future;

  @override
  Future<LocationPermission> checkPermission() {
    permissionChecks++;
    return super.checkPermission();
  }
}

class _StalledClient extends http.BaseClient {
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      Completer<http.StreamedResponse>().future;

  @override
  void close() => closed = true;
}

void main() {
  final platform = GeolocatorPlatform.instance;
  final client = GeolocationService.clientFactory;
  final scanner = GeolocationService.scannerFactory;
  tearDown(() {
    GeolocatorPlatform.instance = platform;
    GeolocationService.clientFactory = client;
    GeolocationService.scannerFactory = scanner;
  });

  for (final stage in ['service', 'permission', 'request', 'position']) {
    testWidgets('a stalled OS $stage call cannot strand Detect Location', (
      tester,
    ) async {
      GeolocatorPlatform.instance = _StalledPlatform(stage);
      GeolocationService.clientFactory = () => MockClient((request) async {
        return http.Response('{"loc":"40,-75","city":"Test town"}', 200);
      });
      PositioningAttempt? result;
      unawaited(
        GeolocationService.locate(
          allowWifiScan: false,
          allowIp: true,
        ).then((value) => result = value),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 12));

      expect(result, isNotNull, reason: 'the detection spinner must finish');
      expect(result!.fix!.source, PositioningSource.ipAddress);
      expect(result!.fix!.isPrecise, isFalse);
      expect(result!.outcomes.first.succeeded, isFalse);
    });
  }

  testWidgets('a stalled Wi-Fi command cannot strand Detect Location', (
    tester,
  ) async {
    GeolocatorPlatform.instance = _StalledPlatform('disabled');
    GeolocationService.scannerFactory = () => WifiScanner(
      operatingSystem: 'linux',
      runner: (_, _) => Completer<CommandResult>().future,
    );
    GeolocationService.clientFactory = () => MockClient((request) async {
      return http.Response('{"loc":"40,-75","city":"Test town"}', 200);
    });
    PositioningAttempt? result;
    unawaited(
      GeolocationService.locate(
        allowWifiScan: true,
        allowIp: true,
      ).then((value) => result = value),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 12));

    expect(result, isNotNull, reason: 'the detection spinner must finish');
    expect(result!.fix!.source, PositioningSource.ipAddress);
    expect(result!.outcomes[1].succeeded, isFalse);
  });

  testWidgets('a late OS response cannot start a permission request', (
    tester,
  ) async {
    final late = _LatePlatform();
    GeolocatorPlatform.instance = late;
    PositioningAttempt? result;
    unawaited(
      GeolocationService.locate(
        allowWifiScan: false,
        allowIp: false,
      ).then((value) => result = value),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(result, isNotNull);
    late.service.complete(true);
    await tester.pump();
    expect(late.permissionChecks, 0);
  });

  testWidgets('a late Wi-Fi command does not continue the abandoned scan', (
    tester,
  ) async {
    final pending = Completer<CommandResult>();
    var commands = 0;
    final scanner = WifiScanner(
      operatingSystem: 'linux',
      runner: (_, _) {
        commands++;
        return pending.future;
      },
    );
    WifiScanOutcome? result;
    unawaited(scanner.scan().then((value) => result = value));
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(result, isA<WifiScanUnavailable>());
    pending.complete(
      const CommandResult(exitCode: 0, stdout: 'wifi', stderr: ''),
    );
    await tester.pump();
    expect(commands, 1);
  });

  testWidgets('OS stages share one deadline instead of restarting the wait', (
    tester,
  ) async {
    final late = _LatePlatform();
    GeolocatorPlatform.instance = late;
    PositioningAttempt? result;
    unawaited(
      GeolocationService.locate(
        allowWifiScan: false,
        allowIp: false,
      ).then((value) => result = value),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    late.service.complete(true);
    await tester.pump();
    expect(late.permissionChecks, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(result, isNotNull);
    expect(result!.fix, isNull);
  });

  testWidgets('Wi-Fi HTTP stalls fall through without claiming a precise fix', (
    tester,
  ) async {
    GeolocatorPlatform.instance = _StalledPlatform('disabled');
    GeolocationService.scannerFactory = () => WifiScanner(
      operatingSystem: 'linux',
      runner: (_, arguments) async => CommandResult(
        exitCode: 0,
        stdout: switch (arguments.join(' ')) {
          '-t -f TYPE dev' => 'wifi',
          'radio wifi' => 'enabled',
          _ => r'00\:11\:22\:33\:44\:55:80:6:test',
        },
        stderr: '',
      ),
    );
    final stalled = <_StalledClient>[];
    GeolocationService.clientFactory = () {
      if (stalled.length < 2) {
        final client = _StalledClient();
        stalled.add(client);
        return client;
      }
      return MockClient((_) async => http.Response('{"loc":"40,-75"}', 200));
    };
    PositioningAttempt? result;
    unawaited(
      GeolocationService.locate(
        allowWifiScan: true,
        allowIp: true,
        googleApiKey: 'test-key',
      ).then((value) => result = value),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(result, isNotNull);
    expect(result!.fix!.source, PositioningSource.ipAddress);
    expect(result!.fix!.isPrecise, isFalse);
    expect(result!.outcomes[1].succeeded, isFalse);
    expect(stalled.every((client) => client.closed), isTrue);
  });

  testWidgets('a timed-out radio enable still restores the previous state', (
    tester,
  ) async {
    GeolocatorPlatform.instance = _StalledPlatform('disabled');
    final commands = <String>[];
    GeolocationService.scannerFactory = () => WifiScanner(
      operatingSystem: 'linux',
      runner: (_, arguments) async {
        final command = arguments.join(' ');
        commands.add(command);
        if (command == 'radio wifi on') {
          return Completer<CommandResult>().future;
        }
        return CommandResult(
          exitCode: 0,
          stdout: command == 'radio wifi' ? 'disabled' : '',
          stderr: '',
        );
      },
    );
    PositioningAttempt? result;
    unawaited(
      GeolocationService.locate(
        allowWifiScan: true,
        allowIp: false,
        mayEnableWifiRadio: true,
      ).then((value) => result = value),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(result, isNotNull);
    expect(commands, ['radio wifi', 'radio wifi on', 'radio wifi off']);
    expect(result!.fix, isNull);
  });

  testWidgets('unresponsive IP providers finish and close both clients', (
    tester,
  ) async {
    GeolocatorPlatform.instance = _StalledPlatform('disabled');
    final clients = <_StalledClient>[];
    GeolocationService.clientFactory = () {
      final client = _StalledClient();
      clients.add(client);
      return client;
    };
    PositioningAttempt? result;
    unawaited(
      GeolocationService.locate(
        allowWifiScan: false,
        allowIp: true,
      ).then((value) => result = value),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(result, isNotNull);
    expect(result!.fix, isNull);
    expect(result!.noInternet, isTrue);
    expect(clients, hasLength(2));
    expect(clients.every((client) => client.closed), isTrue);
  });

  test(
    'internet estimate retains its source without OS or Wi-Fi work',
    () async {
      final late = _LatePlatform();
      GeolocatorPlatform.instance = late;
      GeolocationService.scannerFactory = () =>
          throw StateError('must not scan');
      GeolocationService.clientFactory = () => MockClient((request) async {
        return http.Response('{"loc":"40,-75","city":"Test town"}', 200);
      });
      final result = await GeolocationService.fetchInternetEstimate();
      expect(result!.source, PositioningSource.ipAddress);
      expect(result.provider, 'ipinfo.io');
      expect(result.accuracyMetres, isNull);
      expect(result.isPrecise, isFalse);
      expect(late.permissionChecks, 0);
    },
  );

  test('a timed-out scan subprocess is terminated', () async {
    final result = await runWifiScanCommand('sh', const [
      '-c',
      r'printf "%s" "$$"; exec sleep 60',
    ]);
    expect(result.exitCode, 124);
    final pid = int.parse(result.stdout);
    final status = await Process.run('kill', ['-0', '$pid']);
    expect(
      status.exitCode,
      isNot(0),
      reason: 'the timed-out child must be gone',
    );
  }, skip: Platform.isWindows);
}
