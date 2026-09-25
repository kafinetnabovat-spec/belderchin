import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:hiddify/features/warp/data/warp_endpoint_scanner.dart';
import 'package:hiddify/features/warp/data/warp_profile_builder.dart';
import 'package:hiddify/features/warp/data/wireguard_handshake.dart';
import 'package:hiddify/features/warp/model/warp_identity.dart';

final _identity = WarpIdentity(
  privateKey: 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=',
  publicKey: 'x',
  peerPublicKey: 'WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns=',
  reserved: const [1, 2, 3],
  addressV4: '172.16.0.2',
  addressV6: '2606:4700:110::2',
  endpointHost: 'engage.cloudflareclient.com',
  createdAt: DateTime.utc(2026, 9, 25),
);

void main() {
  group('buildTargets', () {
    test('samples hosts inside the given IPv4 ranges, skipping IPv6 and network/broadcast', () {
      const hints = WarpHints(enabled: true, endpoints: ['162.159.192.0/24', '2606:4700:d0::/48'], ports: [2408, 500, 8886]);
      final targets = WarpEndpointScanner.buildTargets(hints, count: 40, random: Random(1));
      expect(targets, hasLength(40));
      expect(targets.toSet(), hasLength(40), reason: 'unique');
      for (final t in targets) {
        expect(t.address, startsWith('162.159.192.'));
        final last = int.parse(t.address.split('.').last);
        expect(last, inInclusiveRange(1, 254));
        expect([2408, 500, 8886], contains(t.port));
      }
      expect(targets.where((t) => WarpEndpointScanner.primaryPorts.contains(t.port)).length, greaterThan(15));
    });

    test('returns nothing without usable ranges', () {
      const hints = WarpHints(enabled: true, endpoints: ['2606:4700:d0::/48', 'garbage'], ports: [2408]);
      expect(WarpEndpointScanner.buildTargets(hints), isEmpty);
    });
  });

  group('scan', () {
    test('keeps responding endpoints ordered by RTT and stops early', () async {
      // Local fake WARP responders: answer every initiation with a type-2 message
      // carrying the initiator's sender index; one extra port stays silent.
      final responders = [for (var i = 0; i < 3; i++) await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0)];
      final silent = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      var received = 0;
      for (final responder in responders) {
        responder.listen((event) {
          if (event != RawSocketEvent.read) return;
          final datagram = responder.receive();
          if (datagram == null) return;
          received++;
          final data = datagram.data;
          expect(data.length, WireGuardHandshake.initiationLength);
          expect(data[0], WireGuardHandshake.messageInitiation);
          final sender = ByteData.sublistView(data).getUint32(4, Endian.little);
          final reply = Uint8List(WireGuardHandshake.responseLength)..[0] = WireGuardHandshake.messageResponse;
          ByteData.sublistView(reply).setUint32(8, sender, Endian.little);
          responder.send(reply, datagram.address, datagram.port);
        });
      }
      addTearDown(() {
        for (final r in responders) {
          r.close();
        }
        silent.close();
      });

      final scanner = WarpEndpointScanner(identity: _identity, concurrency: 2, timeout: const Duration(milliseconds: 400));
      final targets = [
        WarpEndpoint('127.0.0.1', silent.port),
        for (final r in responders) WarpEndpoint('127.0.0.1', r.port),
      ];
      final results = await scanner.scan(targets, stopAfter: 2);
      expect(results.length, inInclusiveRange(2, 3));
      expect(results.map((r) => r.endpoint.port), isNot(contains(silent.port)));
      for (var i = 1; i < results.length; i++) {
        expect(results[i].rtt >= results[i - 1].rtt, isTrue);
      }
      expect(received, greaterThanOrEqualTo(2));
    });

    test('returns empty for an empty target list', () async {
      final scanner = WarpEndpointScanner(identity: _identity);
      expect(await scanner.scan(const []), isEmpty);
    });
  });

  group('WarpProfileBuilder', () {
    test('emits a wireguard endpoint the core accepts', () {
      final json = const WarpProfileBuilder().toJson(_identity, const WarpEndpoint('162.159.192.1', 2408));
      final endpoint = (json['endpoints']! as List).single as Map<String, Object?>;
      expect(endpoint['type'], 'wireguard');
      expect(endpoint['address'], ['172.16.0.2/32', '2606:4700:110::2/128']);
      expect(endpoint['private_key'], _identity.privateKey);
      final peer = (endpoint['peers']! as List).single as Map<String, Object?>;
      expect(peer['address'], '162.159.192.1');
      expect(peer['port'], 2408);
      expect(peer['reserved'], [1, 2, 3]);
      expect(peer['allowed_ips'], ['0.0.0.0/0', '::/0']);
      expect(peer['persistent_keepalive_interval'], 25);
    });
  });
}
