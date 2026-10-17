/// Skotiq Self-Hosted Update Server
///
/// A simple HTTP server for hosting Skotiq OTA updates.
/// Provides version checking, manifest download, and package download endpoints.
///
/// Usage:
///   dart run tools/update_server/server.dart
///   dart run tools/update_server/server.dart --port 8090 --releases ./releases

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';
import 'package:path/path.dart' as path;

const defaultPort = 8090;
const defaultReleasesDir = 'releases';
const defaultManifestsDir = 'manifests';

late String releasesDir;
late String manifestsDir;

Future<void> main(List<String> args) async {
  // Parse arguments
  final port = int.tryParse(getArg(args, '--port') ?? '') ?? defaultPort;
  releasesDir = getArg(args, '--releases') ?? defaultReleasesDir;
  manifestsDir = getArg(args, '--manifests') ?? defaultManifestsDir;

  // Create directories if they don't exist
  await Directory(releasesDir).create(recursive: true);
  await Directory(manifestsDir).create(recursive: true);

  print('Skotiq Update Server');
  print('========================');
  print('Releases: $releasesDir');
  print('Manifests: $manifestsDir');
  print('');

  // Create router
  final router = Router();

  // Version endpoint
  router.get('/api/version', _handleVersion);

  // Manifest endpoints
  router.get('/api/manifests/<version>', _handleManifest);
  router.get('/manifests/<version>.json', _handleManifestFile);

  // Package download
  router.get('/releases/<version>/<filename>', _handleDownload);

  // Health check
  router.get('/health', (Request req) => Response.ok('OK'));

  // Add CORS middleware
  final handler = const Pipeline()
      .addMiddleware(logRequests())
      .addMiddleware(_corsMiddleware())
      .addHandler(router.call);

  // Start server
  final server = await shelf_io.serve(handler, InternetAddress.anyIPv4, port);
  print('Server running on http://${server.address.address}:${server.port}');
  print('');
  print('Endpoints:');
  print('  GET /api/version          - Get latest version info');
  print('  GET /api/manifests/<ver>  - Get manifest for version');
  print('  GET /releases/<ver>/<file> - Download package');
  print('');
  print('Press Ctrl+C to stop.');
}

String? getArg(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index >= 0 && index < args.length - 1) {
    return args[index + 1];
  }
  return null;
}

/// CORS middleware
Middleware _corsMiddleware() {
  return (Handler handler) {
    return (Request request) async {
      if (request.method == 'OPTIONS') {
        return Response.ok('', headers: _corsHeaders);
      }

      final response = await handler(request);
      return response.change(headers: _corsHeaders);
    };
  };
}

const _corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type, Range',
};

/// Handle /api/version endpoint
Future<Response> _handleVersion(Request request) async {
  // Build version info from available manifests
  final channels = <String, dynamic>{};

  // Scan manifests directory for available versions
  final manifestDir = Directory(manifestsDir);
  if (await manifestDir.exists()) {
    await for (final entity in manifestDir.list()) {
      if (entity is File && entity.path.endsWith('.json')) {
        try {
          final content = await entity.readAsString();
          final manifest = jsonDecode(content) as Map<String, dynamic>;
          final version = manifest['version'] as String;

          // Determine channel from version string
          String channel = 'stable';
          if (version.contains('beta')) {
            channel = 'beta';
          } else if (version.contains('alpha')) {
            channel = 'alpha';
          }

          final fileName = path.basename(entity.path);
          channels[channel] = {
            'version': version,
            'manifestUrl': '/manifests/$fileName',
          };
        } catch (e) {
          print('Error reading manifest ${entity.path}: $e');
        }
      }
    }
  }

  // Find latest stable version
  String? latestVersion;
  int? latestBuildNumber;

  if (channels.containsKey('stable')) {
    latestVersion = channels['stable']['version'] as String;

    // Try to get build number from manifest
    final manifestPath = path.join(manifestsDir, '$latestVersion.json');
    if (await File(manifestPath).exists()) {
      try {
        final content = await File(manifestPath).readAsString();
        final manifest = jsonDecode(content) as Map<String, dynamic>;
        latestBuildNumber = manifest['buildNumber'] as int?;
      } catch (e) {
        // Ignore
      }
    }
  }

  final versionInfo = {
    'latestVersion': latestVersion ?? '0.0.0',
    'latestBuildNumber': latestBuildNumber ?? 0,
    'channels': channels,
    'minSupportedVersion': '2.0.0',
    'serverVersion': '1.0.0',
  };

  return Response.ok(
    jsonEncode(versionInfo),
    headers: {'Content-Type': 'application/json'},
  );
}

/// Handle /api/manifests/<version> endpoint
Future<Response> _handleManifest(Request request, String version) async {
  return _serveManifest(version);
}

/// Handle /manifests/<version>.json endpoint
Future<Response> _handleManifestFile(Request request, String version) async {
  // Remove .json extension if present
  final cleanVersion = version.replaceAll('.json', '');
  return _serveManifest(cleanVersion);
}

Future<Response> _serveManifest(String version) async {
  final manifestPath = path.join(manifestsDir, '$version.json');
  final file = File(manifestPath);

  if (!await file.exists()) {
    return Response.notFound('Manifest not found for version $version');
  }

  final content = await file.readAsString();
  return Response.ok(content, headers: {'Content-Type': 'application/json'});
}

/// Handle /releases/<version>/<filename> endpoint
Future<Response> _handleDownload(
  Request request,
  String version,
  String filename,
) async {
  final filePath = path.join(releasesDir, version, filename);
  final file = File(filePath);

  if (!await file.exists()) {
    return Response.notFound('File not found: $version/$filename');
  }

  final fileSize = await file.length();

  // Check for Range header (resume support)
  final rangeHeader = request.headers['range'];
  if (rangeHeader != null) {
    return _handleRangeRequest(file, fileSize, rangeHeader);
  }

  // Full file download
  return Response.ok(
    file.openRead(),
    headers: {
      'Content-Type': 'application/octet-stream',
      'Content-Length': fileSize.toString(),
      'Accept-Ranges': 'bytes',
      'Content-Disposition': 'attachment; filename="$filename"',
    },
  );
}

/// Handle Range request for resume support
Future<Response> _handleRangeRequest(
  File file,
  int fileSize,
  String rangeHeader,
) async {
  // Parse range header: "bytes=start-end"
  final match = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(rangeHeader);
  if (match == null) {
    return Response(416, body: 'Invalid Range header');
  }

  final startStr = match.group(1);
  final endStr = match.group(2);

  int start = startStr?.isNotEmpty == true ? int.parse(startStr!) : 0;
  int end = endStr?.isNotEmpty == true ? int.parse(endStr!) : fileSize - 1;

  if (start >= fileSize || end >= fileSize || start > end) {
    return Response(416, body: 'Range not satisfiable');
  }

  final length = end - start + 1;

  // Create a stream that reads just the requested range
  final stream = file.openRead(start, end + 1);

  return Response(
    206,
    body: stream,
    headers: {
      'Content-Type': 'application/octet-stream',
      'Content-Length': length.toString(),
      'Content-Range': 'bytes $start-$end/$fileSize',
      'Accept-Ranges': 'bytes',
    },
  );
}
