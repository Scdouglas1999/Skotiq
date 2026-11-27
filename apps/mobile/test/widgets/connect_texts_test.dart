import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_mobile/widgets/connect_texts.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  final en = SkotiqLocalizations(const Locale('en'));
  final es = SkotiqLocalizations(const Locale('es'));

  test('every discovery step says where the phone is looking', () {
    expect(
      connectActivityText(const ConnectDiscovering(), en),
      'Looking for it on this Wi-Fi…',
    );
    expect(
      connectActivityText(
        const ConnectDiscovering(DiscoveryStage.lastServer),
        en,
      ),
      'Trying the computer this phone used last…',
    );
    for (final stage in [
      DiscoveryStage.bonjour,
      DiscoveryStage.broadcast,
      DiscoveryStage.nothingFound,
    ]) {
      expect(
        connectActivityText(ConnectDiscovering(stage), en),
        'Looking for it on this Wi-Fi…',
        reason: '$stage',
      );
    }
  });

  test('a Spanish phone reads the connect screen in Spanish', () {
    expect(
      connectActivityText(const ConnectLinking('NYX'), es),
      'Conectando con NYX...',
    );
    expect(
      connectProblemText(
        const ConnectNoSession('192.168.1.20', 8080, tokenMissing: true),
        es,
      ),
      contains('No se pudo conectar con 192.168.1.20:8080'),
    );
    expect(
      connectProblemText(const ConnectSessionLost(), en),
      'Connection to server lost. Retrying automatically — or reconnect '
      'below.',
    );
  });

  group('a refused pairing reads as on the desktop', () {
    final rig = DiscoveredServer(
      host: '192.168.1.50',
      webPort: 8099,
      name: 'rig',
    );

    test('a wrong code says it does not match', () {
      const failure = RigPairingFailure(
        RigPairingFailureKind.invalidCode,
        'Invalid pairing code',
        hostMessage: 'Invalid pairing code',
        statusCode: 401,
      );

      expect(
        connectProblemText(ConnectPairingFailed(failure, rig), en),
        "That code doesn't match the one rig shows. Check it and try again.",
      );
    });

    test('a request that never reached the host names the address', () {
      final failure = RigPairingFailure(
        RigPairingFailureKind.unreachable,
        'SocketException: refused',
        cause: const SocketException('refused'),
      );

      expect(
        connectProblemText(ConnectPairingFailed(failure, rig), en),
        "Can't reach rig at 192.168.1.50:8099.",
      );
    });
  });
}
