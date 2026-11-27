// The remote clients (cloud sync, the hub, the shared calibration library)
// bound every exchange by the time no bytes move: a stalled server (a real
// loopback one) ends the call, a slow link that keeps moving finishes.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:skotiq_core/database.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/services.dart';

import 'backup_restore_support.dart';

/// A loopback server whose handling of each request the test decides.
class _Server {
  _Server._(this._server);

  final HttpServer _server;
  final List<HttpRequest> held = [];
  final List<Object> errors = [];

  static Future<_Server> start(
    Future<void> Function(HttpRequest request, _Server server) handle,
  ) async {
    final server = _Server._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(
      (request) => handle(request, server).then(
        (_) {},
        // The client giving up closes the connection under a handler that is
        // still writing; that is the client's bound working.
        onError: server.errors.add,
      ),
    );
    return server;
  }

  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> close() => _server.close(force: true);
}

/// Accepts the request and never answers.
Future<void> _neverAnswer(HttpRequest request, _Server server) async {
  server.held.add(request);
}

/// A link that moves [bytesPerSecond] each way: it takes the request body at
/// that pace, then answers [status] with [reply] at the same pace.
///
/// A client transport rather than a loopback server: the kernel buffers of a
/// loopback connection take tens of megabytes at once, so a server reading
/// slowly cannot make the sender's side slow.
class _SlowLink extends http.BaseClient {
  _SlowLink(this.bytesPerSecond, {this.status = 201, this.reply = const []});

  final int bytesPerSecond;
  final int status;
  final List<int> reply;

  Future<void> _move(int bytes) => Future<void>.delayed(
    Duration(microseconds: bytes * 1000000 ~/ bytesPerSecond),
  );

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    await for (final chunk in request.finalize()) {
      await _move(chunk.length);
    }
    Stream<List<int>> body() async* {
      for (var start = 0; start < reply.length; start += 64 * 1024) {
        final end = start + 64 * 1024 < reply.length
            ? start + 64 * 1024
            : reply.length;
        await _move(end - start);
        yield reply.sublist(start, end);
      }
    }

    return http.StreamedResponse(body(), status);
  }
}

/// Reads the first chunk of the request body, then stops reading.
Future<void> _stopReading(HttpRequest request, _Server server) async {
  server.held.add(request);
  late StreamSubscription<List<int>> sub;
  sub = request.listen((_) => sub.pause());
}

/// About 1.5 s of transfer at [_rate], five times the idle limit, in steps
/// of about 16 ms.
const _transferBytes = 6 * 1024 * 1024;
const _rate = 4 * 1024 * 1024;

Future<File> _file(Directory dir, int bytes) async {
  final file = File('${dir.path}/payload.fits');
  await file.writeAsBytes(Uint8List(bytes));
  return file;
}

/// Sends headers and a few body bytes, then goes silent.
Future<void> _stallMidBody(HttpRequest request, _Server server) async {
  server.held.add(request);
  await request.drain<void>();
  request.response
    ..statusCode = 200
    ..contentLength = 1000
    ..add(List<int>.filled(10, 1));
  await request.response.flush();
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sk_remote_http_bounds_');
  });
  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  group('S3 sync', () {
    test('a stalled endpoint ends the push, and the next push is not refused '
        'as already in progress', () async {
      final server = await _Server.start(_neverAnswer);
      addTearDown(server.close);
      final db = SkotiqDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      await SettingsDao(db).setSettings({
        SyncSettingsKeys.provider: SyncProvider.s3.key,
        SyncSettingsKeys.s3Endpoint: server.uri.toString(),
        SyncSettingsKeys.s3Region: 'us-east-1',
        SyncSettingsKeys.s3Bucket: 'astro-backups',
        SyncSettingsKeys.s3AccessKey: 'AKIAEXAMPLE',
        SyncSettingsKeys.s3PathStyle: 'true',
        SyncSettingsKeys.machineName: 's3-machine',
      });
      final logger = testLogger(tmp);
      final service = SyncService(
        backupService: BackupService(database: db, logger: logger),
        settingsDao: SettingsDao(db),
        secretsStore: SecretsStore(InMemorySecureKeyValueStore()),
        logger: logger,
        targetFactory: (config, password) => S3SyncTarget(
          endpoint: Uri.parse(config.s3Endpoint),
          region: config.s3Region,
          bucket: config.s3Bucket,
          accessKey: config.s3AccessKey,
          secretKey: password,
          pathStyle: config.s3PathStyle,
          timeout: const Duration(milliseconds: 300),
        ),
        downloadDirectoryProvider: () async => tmp,
      );

      final first = await service.pushNow();
      expect(first.success, isFalse);
      expect(first.errorMessage, contains('timed out'));
      expect(service.pushInProgress, isFalse);

      final second = await service.pushNow();
      expect(second.errorMessage, isNot(contains('already in progress')));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('shared calibration library', () {
    test(
      'a hub that sends headers then stalls mid-body ends the download',
      () async {
        final server = await _Server.start(_stallMidBody);
        addTearDown(server.close);
        final client = SharedCalibrationClient(
          hubBaseUrl: server.uri,
          bearerToken: 'tok',
          timeout: const Duration(milliseconds: 300),
        );
        addTearDown(client.close);

        await expectLater(
          client.downloadMasterBytes('m-1'),
          throwsA(
            isA<ConstellationException>().having(
              (e) => e.kind,
              'kind',
              ConstellationErrorKind.network,
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(seconds: 20)),
    );
  });

  group('a slow link that keeps moving', () {
    const idle = Duration(milliseconds: 300);
    final receipt = utf8.encode(
      jsonEncode({'contributionId': 'c-1', 'accepted': true, 'storedBytes': 1}),
    );

    Future<T> timed<T>(Future<T> Function() transfer) async {
      final watch = Stopwatch()..start();
      final result = await transfer();
      expect(
        watch.elapsed,
        greaterThan(idle * 3),
        reason: 'the transfer must outlast the idle limit to prove anything',
      );
      return result;
    }

    test('finishes a hub subframe upload', () async {
      final file = await _file(tmp, _transferBytes);
      final client = ConstellationClient(
        hubBaseUrl: Uri.parse('http://hub.test'),
        bearerToken: 'tok',
        client: _SlowLink(_rate, reply: receipt),
        timeout: idle,
      );

      final result = await timed(
        () => client.pushSubframe(
          tileId: 42,
          order: 9,
          fitsPath: file.path,
          license: 'cc-by',
        ),
      );
      expect(result.accepted, isTrue);
    });

    test('finishes a calibration master upload', () async {
      final file = await _file(tmp, _transferBytes);
      final client = SharedCalibrationClient(
        hubBaseUrl: Uri.parse('http://hub.test'),
        bearerToken: 'tok',
        client: _SlowLink(
          _rate,
          reply: utf8.encode(
            jsonEncode({
              'id': 'pub-1',
              'masterType': 'dark',
              'license': 'cc-by',
              'frameCount': 1,
            }),
          ),
        ),
        timeout: idle,
      );

      final master = await timed(
        () => client.publishMaster(
          filePath: file.path,
          masterType: 'dark',
          cameraModel: 'cam',
          license: ContributionLicense.ccBy,
          sensorWidth: 10,
          sensorHeight: 10,
          gain: 100,
          offset: 10,
          exposureSeconds: 60,
          frameCount: 1,
          provenance: const Provenance(displayName: 'me', frameCount: 1),
        ),
      );
      expect(master.id, 'pub-1');
    });

    test('finishes a WebDAV backup upload', () async {
      final target = WebDavSyncTarget(
        baseUrl: Uri.parse('http://dav.test/skotiq'),
        username: 'u',
        password: 'p',
        client: _SlowLink(_rate),
        timeout: idle,
      );

      await timed(
        () => target.uploadFile('bundle.skbak', Uint8List(_transferBytes)),
      );
    });

    test('finishes a WebDAV backup download', () async {
      final target = WebDavSyncTarget(
        baseUrl: Uri.parse('http://dav.test/skotiq'),
        username: 'u',
        password: 'p',
        client: _SlowLink(_rate, status: 200, reply: Uint8List(_transferBytes)),
        timeout: idle,
      );

      final bytes = await timed(() => target.downloadFile('bundle.skbak'));
      expect(bytes, hasLength(_transferBytes));
    });
  });

  test(
    'a hub that stops reading an upload ends it',
    () async {
      final server = await _Server.start(_stopReading);
      addTearDown(server.close);
      final file = await _file(tmp, 8 * 1024 * 1024);
      final client = ConstellationClient(
        hubBaseUrl: server.uri,
        bearerToken: 'tok',
        timeout: const Duration(milliseconds: 300),
      );
      addTearDown(client.close);

      await expectLater(
        client.pushSubframe(
          tileId: 42,
          order: 9,
          fitsPath: file.path,
          license: 'cc-by',
        ),
        throwsA(
          isA<ConstellationException>().having(
            (e) => e.kind,
            'kind',
            ConstellationErrorKind.network,
          ),
        ),
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'an upload that cannot connect leaves its file closed',
    () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = probe.port;
      await probe.close();
      final file = await _file(tmp, 1024 * 1024);
      final client = ConstellationClient(
        hubBaseUrl: Uri.parse('http://127.0.0.1:$port'),
        bearerToken: 'tok',
      );
      addTearDown(client.close);

      await expectLater(
        client.pushSubframe(
          tileId: 42,
          order: 9,
          fitsPath: file.path,
          license: 'cc-by',
        ),
        throwsA(isA<ConstellationException>()),
      );
      await pumpEventQueue();

      final open = [
        for (final fd in Directory('/proc/self/fd').listSync())
          if (_linkTarget(fd.path) == file.path) fd.path,
      ];
      expect(open, isEmpty);
    },
    skip: !Directory('/proc/self/fd').existsSync(),
  );
}

String? _linkTarget(String path) {
  try {
    return Link(path).targetSync();
  } on FileSystemException {
    return null;
  }
}
