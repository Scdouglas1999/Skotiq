import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_updater/skotiq_updater.dart';

import '../secret_file.dart';

/// Load or generate the LAN-push authentication secret. Persisted under
/// the application-support directory so it survives restarts. Used by
/// both GUI and headless bootstraps.
///
/// Exposed at library level so unit tests can pre-seed a fixed secret in
/// the AppData root. [appDataDir] overrides where that root is, which is what
/// lets a test assert the file mode without a platform-channel mock; production
/// callers leave it null and get the real application-support directory.
Future<String> getOrCreatePushSecret(
  LoggingService logger, {
  required String logSource,
  Directory? appDataDir,
}) async {
  final appData = appDataDir ?? await resolveSkotiqDataDirectory();
  final secretFile = File(p.join(appData.path, 'push_secret.txt'));

  if (await secretFile.exists()) {
    final secret = (await secretFile.readAsString()).trim();
    if (secret.isNotEmpty) {
      // Repair a file an older build created world-readable.
      await restrictSecretFile(secretFile);
      return secret;
    }
  }

  final secret = LanPushReceiver.generatePushSecret();
  await writeSecretFile(secretFile, secret);
  logger.info(
    'Generated new LAN push secret. Configure this on the push tool.',
    source: logSource,
    fields: {'secret_path': secretFile.path},
  );
  return secret;
}

