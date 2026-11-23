// The address the daemon prints for phones on the same network.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_desktop/host/host_server.dart' show pickLanAddress;

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
  test('a Wi-Fi interface named wlo1 is a LAN interface', () {
    expect(
      pickLanAddress([
        _Interface('lo', ['127.0.0.1']),
        _Interface('wlo1', ['192.168.1.40']),
      ]),
      '192.168.1.40',
    );
  });

  test('loopback interfaces are skipped on Linux and Windows', () {
    expect(
      pickLanAddress([
        _Interface('lo', ['127.0.0.1']),
        _Interface('Loopback Pseudo-Interface 1', ['127.0.0.1']),
        _Interface('Ethernet', ['fe80::1', '10.0.0.5']),
      ]),
      '10.0.0.5',
    );
    expect(
      pickLanAddress([
        _Interface('lo', ['127.0.0.1']),
      ]),
      isNull,
    );
  });
}
