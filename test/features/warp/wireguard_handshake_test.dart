import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/warp/data/wireguard_handshake.dart';

Uint8List _bytes(int from) => Uint8List.fromList(List.generate(32, (i) => from + i));

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String hex) =>
    Uint8List.fromList([for (var i = 0; i < hex.length; i += 2) int.parse(hex.substring(i, i + 2), radix: 16)]);

void main() {
  group('WireGuardHandshake', () {
    test('initiation matches an independent reference implementation byte for byte', () async {
      // Vector produced with Python (hashlib.blake2s / hmac / cryptography X25519 + ChaCha20Poly1305)
      // for static key 01..20, peer key derived from 21..40, ephemeral seed 41..60.
      const peerPublicHex = '5869aff450549732cbaaed5e5df9b30a6da31cb0e5742bad5ad4a1a768f1a67b';
      const expected =
          '010000000df0ad0b64b101b1d0be5a8704bd078f9895001fc03e8e9f9522f188dd128d9846d48466158a0e4ca242d151ca97ab90159a98b67e616625e68b4065d357376b6598e644ad7d678c0295d22de4cb43d5135581ed36346bfa7311c0e82662329351c64961993f608f559767d1ad39402aa85c1e17f27462bf0468e5a5f665cb0200000000000000000000000000000000';
      final message = await WireGuardHandshake.buildInitiation(
        staticPrivateKey: _bytes(1),
        peerPublicKey: _fromHex(peerPublicHex),
        senderIndex: 0x0badf00d,
        timestamp: DateTime.utc(2026, 9, 25, 7, 0, 0, 123, 456),
        ephemeralSeed: _bytes(65),
      );
      expect(message.length, WireGuardHandshake.initiationLength);
      expect(_hex(message), expected);
    });

    test('tai64n encodes seconds offset by 2^62 and nanoseconds big-endian', () {
      expect(_hex(WireGuardHandshake.tai64n(DateTime.utc(2026, 9, 25, 7, 0, 0, 123, 456))), '400000006ab61bf0075bca00');
      expect(_hex(WireGuardHandshake.tai64n(DateTime.utc(1970))), '400000000000000000000000');
    });

    test('recognises responses and cookie replies addressed to us', () {
      final response = Uint8List(92)..[0] = 2;
      ByteData.sublistView(response).setUint32(8, 0x11223344, Endian.little);
      expect(WireGuardHandshake.isResponseFor(response, 0x11223344), isTrue);
      expect(WireGuardHandshake.isResponseFor(response, 0x11223345), isFalse);
      expect(WireGuardHandshake.receiverIndexOf(response), 0x11223344);

      final cookie = Uint8List(64)..[0] = 3;
      ByteData.sublistView(cookie).setUint32(4, 7, Endian.little);
      expect(WireGuardHandshake.isCookieReplyFor(cookie, 7), isTrue);
      expect(WireGuardHandshake.receiverIndexOf(cookie), 7);

      expect(WireGuardHandshake.receiverIndexOf(Uint8List(92)..[0] = 1), isNull);
      expect(WireGuardHandshake.receiverIndexOf(Uint8List(91)..[0] = 2), isNull);
      expect(WireGuardHandshake.isResponseFor(Uint8List(92)..[0] = 2..[1] = 1, 0), isFalse);
    });
  });
}
