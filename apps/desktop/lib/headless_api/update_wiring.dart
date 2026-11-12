import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:skotiq_core/services.dart';
import 'package:skotiq_core/utils.dart';
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
  final secret = await readOrCreateSecretFile(
    secretFile,
    LanPushReceiver.generatePushSecret,
  );
  if (secret.created) {
    logger.info(
      'Generated new LAN push secret. Configure this on the push tool.',
      source: logSource,
      fields: {'secret_path': secretFile.path},
    );
  }
  return secret.value;
}

