import 'package:skotiq_app/localization/skotiq_localizations.dart';
import 'package:skotiq_core/errors.dart';
import 'package:skotiq_core/services.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

import '../services/mobile_pairing_service.dart';

/// What the connection screen's progress card says while [activity] runs;
/// empty when nothing is being tried.
String connectActivityText(
  ConnectActivity? activity,
  SkotiqLocalizations l10n,
) => switch (activity) {
  null => '',
  ConnectDiscovering(stage: DiscoveryStage.lastServer) => l10n.text(
    'mobileTryingLastComputer',
  ),
  // The methods the search tries are its business; where it is looking is
  // the operator's.
  ConnectDiscovering() => l10n.text('mobileLookingOnWifi'),
  ConnectLinking(:final label) => l10n.text(
    'mobileConnectingTo',
    params: {'name': label},
  ),
  ConnectPairing(:final host, :final port) => l10n.text(
    'mobilePairingWith',
    params: {'address': '$host:$port'},
  ),
  ConnectViaRelay() => l10n.text('mobileConnectingViaRelay'),
  ConnectViaQr() => l10n.text('mobileConnectingViaQr'),
};

/// Why the last connect did not link, as the connection screen says it. The
/// host's own reasons and pairing failures use the words every linking
/// surface shares.
String connectProblemText(ConnectProblem problem, SkotiqLocalizations l10n) {
  String error(Object e) => '$e';
  return switch (problem) {
    ConnectHostProblem(:final problem) => problem.message,
    ConnectPairingFailed(:final failure, :final host) => pairingFailureText(
      failure,
      host,
    ),
    ConnectOneTapIdentity(:final failure) => failure.message,
    ConnectForgotten(:final name) => l10n.text(
      'mobileForgotten',
      params: {'name': name},
    ),
    ConnectNoSession(:final host, :final port, :final tokenMissing) => [
      l10n.text('mobileNoSession', params: {'address': '$host:$port'}),
      if (tokenMissing) l10n.text('mobileNoSessionTokenMissing'),
    ].join('\n\n'),
    ConnectFailedWith(error: final e) => l10n.text(
      'mobileConnectionError',
      params: {'error': userFacingError(e)},
    ),
    ConnectNothingFound() => l10n.text('mobileNothingFound'),
    ConnectDiscoveryFailed(error: final e) => l10n.text(
      'mobileDiscoveryFailed',
      params: {'error': error(e)},
    ),
    ConnectSessionLost() => l10n.text('mobileSessionLost'),
    ConnectLostStillSettling() => l10n.text('mobileLostStillSettling'),
    ConnectCannotLeave(error: final e) => l10n.text(
      'mobileCannotLeave',
      params: {'error': error(e)},
    ),
    ConnectUiNotReady() => l10n.text('mobileUiNotReady'),
    ConnectBadApplianceId() => l10n.text('mobileBadApplianceId'),
    ConnectBadRelayUrl(error: final e) => l10n.text(
      'mobileBadRelayUrl',
      params: {'error': error(e)},
    ),
    ConnectRelayRefused(:final code, :final message) => l10n.text(
      'mobileRelayRefused',
      params: {'code': code, 'message': message},
    ),
    ConnectRelayUnreachable(error: final e) => l10n.text(
      'mobileRelayUnreachable',
      params: {'error': error(e)},
    ),
    ConnectRelayFieldsMissing() => l10n.text('mobileRelayFieldsMissing'),
    ConnectScannerFailed(error: final e) => l10n.text(
      'mobileScannerFailed',
      params: {'error': error(e)},
    ),
    ConnectQrIdentity() => l10n.text('mobileQrIdentity'),
    ConnectAddressMissing() => l10n.text('mobileAddressMissing'),
    ConnectAddressInvalid(:final message) => message,
  };
}
