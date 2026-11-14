import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_remote_protocol/skotiq_remote_protocol.dart';

void main() {
  group('RigDiscovery helpers', () {
    test('parses a multicast_dns TXT record', () {
      final txt = RigDiscovery.parseTxtRecord(
        'fingerprint=dc2f26\nname=Skotiq\npairingSupported=true\n'
        'scheme=http\nversion=8.2.1\nbroken\n',
      );
      expect(txt, {
        'fingerprint': 'dc2f26',
        'name': 'Skotiq',
        'pairingSupported': 'true',
        'scheme': 'http',
        'version': '8.2.1',
      });
    });

    test('picks the address on a shared subnet', () async {
      final picked = await RigDiscovery.pickReachableAddress([
        InternetAddress('172.17.0.1'),
        InternetAddress('192.168.1.20'),
      ], localAddresses: () async => [InternetAddress('192.168.1.40')]);
      expect(picked!.address, '192.168.1.20');
    });

    test('names the computer from the SRV target', () {
      expect(
        RigDiscovery.mdnsTargetComputerName('DESKTOP-MMAJGAK.local'),
        'DESKTOP-MMAJGAK',
      );
      expect(RigDiscovery.mdnsTargetComputerName('pi.local.'), 'pi');
      expect(RigDiscovery.mdnsTargetComputerName(''), isNull);
    });
  });

  group('DiscoveredServer.displayName', () {
    DiscoveredServer server({String name = 'Skotiq', String? hostName}) =>
        DiscoveredServer(
          host: '192.168.1.32',
          webPort: 8099,
          name: name,
          hostName: hostName,
        );

    test('prefers the computer name', () {
      expect(
        server(hostName: 'DESKTOP-MMAJGAK').displayName,
        'DESKTOP-MMAJGAK',
      );
    });

    test('ignores the product names old hosts advertised', () {
      expect(server().displayName, '192.168.1.32');
      expect(server(name: 'Skotiq Headless').displayName, '192.168.1.32');
      expect(server(name: 'observatory').displayName, 'observatory');
    });

    test('/api/info fills the host identity', () {
      final merged = EnhancedSkotiqDiscovery.mergeServerInfo(server(), {
        'name': 'DESKTOP-MMAJGAK',
        'hostName': 'DESKTOP-MMAJGAK',
        'hostMode': 'gui',
        'platform': 'windows',
        'version': '8.2.2',
        'lanPairing': true,
        'fingerprint': 'abc',
      });
      expect(merged.hostName, 'DESKTOP-MMAJGAK');
      expect(merged.hostMode, 'gui');
      expect(merged.platform, 'windows');
      expect(merged.lanPairing, isTrue);
      expect(merged.fingerprint, 'abc');
    });
  });

  test('a UDP beacon carries the computer name and host mode', () {
    final server = SkotiqDiscovery.tryParseResponsePacket(
      'SKOTIQ_RESPONSE_V2:${jsonEncode({'protocol': '2', 'name': 'rig', 'webPort': 8099, 'signalingPort': 8099, 'hostName': 'rig', 'hostMode': 'headless'})}',
      '10.0.0.5',
    );
    expect(server!.hostName, 'rig');
    expect(server.hostMode, 'headless');
  });

  group('DiscoveryPortMux', () {
    test('one socket answers both discovery and update probes', () async {
      // Two responders on one port. Before the mux each bound its own socket
      // with reuseAddress, and on Windows the update responder received every
      // unicast discovery probe and dropped it.
      final discovery = await DiscoveryPortMux.acquire(
        port: 0,
        handler: (message, datagram, socket) {
          if (!message.startsWith('SKOTIQ_DISCOVERY_V2:')) return false;
          socket.send(
            utf8.encode('discovery'),
            datagram.address,
            datagram.port,
          );
          return true;
        },
      );
      final update = await DiscoveryPortMux.acquire(
        handler: (message, datagram, socket) {
          if (message != 'SKOTIQ_UPDATE_PUSH') return false;
          socket.send(utf8.encode('update'), datagram.address, datagram.port);
          return true;
        },
      );
      expect(identical(discovery.socket, update.socket), isTrue);
      final port = discovery.socket.port;

      final client = await RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final replies = <String>[];
      final got = Completer<void>();
      client.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = client.receive();
        if (d == null) return;
        replies.add(utf8.decode(d.data));
        if (replies.length == 2 && !got.isCompleted) got.complete();
      });
      client.send(
        utf8.encode('SKOTIQ_DISCOVERY_V2:{}'),
        InternetAddress.loopbackIPv4,
        port,
      );
      client.send(
        utf8.encode('SKOTIQ_UPDATE_PUSH'),
        InternetAddress.loopbackIPv4,
        port,
      );
      await got.future.timeout(const Duration(seconds: 5));
      expect(replies, containsAll(['discovery', 'update']));

      client.close();
      update.release();
      expect(DiscoveryPortMux.leaseCount, 1);
      discovery.release();
      expect(DiscoveryPortMux.leaseCount, 0);
    });
  });
}
