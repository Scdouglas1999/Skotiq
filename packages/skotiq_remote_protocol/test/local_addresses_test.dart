import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/client.dart';

class _Interface implements NetworkInterface {
  _Interface(this.name, List<String> addresses)
    : addresses = [for (final a in addresses) InternetAddress(a)];

  @override
  final String name;

  @override
  final List<InternetAddress> addresses;

  @override
  int get index => 0;
}

void main() {
  final interfaces = [
    _Interface('lo', ['127.0.0.1', '::1']),
    _Interface('tailscale0', ['fd7a:115c:a1e0::1', '100.101.102.103']),
    _Interface('wlo1', ['fe80::1', '192.168.1.40']),
  ];

  test('the LAN address skips loopback, and tailnet when asked', () {
    expect(
      LocalAddresses.lanIpv4(interfaces, skipTailnet: false),
      '100.101.102.103',
    );
    expect(
      LocalAddresses.lanIpv4(interfaces, skipTailnet: true),
      '192.168.1.40',
    );
    expect(
      LocalAddresses.lanIpv4([
        _Interface('lo', ['127.0.0.1']),
      ], skipTailnet: true),
      isNull,
    );
  });

  test('the tailnet address is the first one, or the first IPv4 one', () {
    expect(
      LocalAddresses.tailnet(interfaces, preferIpv4: false)?.address,
      'fd7a:115c:a1e0::1',
    );
    expect(
      LocalAddresses.tailnet(interfaces, preferIpv4: true)?.address,
      '100.101.102.103',
    );
    expect(
      LocalAddresses.tailnet([
        _Interface('eth0', ['100.63.0.1', '10.0.0.5']),
      ], preferIpv4: true),
      isNull,
    );
  });
}
