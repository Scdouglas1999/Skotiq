import 'dart:io';

import 'tailnet_detector.dart';

/// The addresses this machine's network interfaces say it is reached on.
///
/// Each reader lists the interfaces itself (with the loopback and address
/// family it needs) and asks these which address to use.
abstract final class LocalAddresses {
  /// The first IPv4 address of [interfaces] that is not a loopback address,
  /// and with [skipTailnet] not a Tailscale address either. Interface names
  /// do not decide it: Linux names Wi-Fi `wlo1`.
  static String? lanIpv4(
    List<NetworkInterface> interfaces, {
    required bool skipTailnet,
  }) {
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.type != InternetAddressType.IPv4 || address.isLoopback) {
          continue;
        }
        if (skipTailnet &&
            TailnetDetector.isTailscaleInterfaceAddress(address)) {
          continue;
        }
        return address.address;
      }
    }
    return null;
  }

  /// The first Tailscale address of [interfaces] in interface order, of
  /// address family [type].
  static InternetAddress? tailnet(
    List<NetworkInterface> interfaces, {
    InternetAddressType type = InternetAddressType.any,
  }) {
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (type != InternetAddressType.any && address.type != type) continue;
        if (!address.isLoopback &&
            TailnetDetector.isTailscaleInterfaceAddress(address)) {
          return address;
        }
      }
    }
    return null;
  }
}
