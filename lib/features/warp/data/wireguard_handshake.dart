import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Minimal WireGuard (Noise_IKpsk2) handshake *initiation* builder and
/// *response* checker, used only to measure whether a WARP endpoint answers.
///
/// No session keys are derived and no data is exchanged: a valid type-2
/// response addressed to our sender index proves the endpoint is reachable
/// and that our registration is accepted. Everything is pure Dart
/// (`package:cryptography`), no native code.
class WireGuardHandshake {
  WireGuardHandshake._();

  static const int initiationLength = 148;
  static const int responseLength = 92;
  static const int messageInitiation = 1;
  static const int messageResponse = 2;
  static const int messageCookieReply = 3;

  static final Uint8List _construction = utf8.encode('Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s');
  static final Uint8List _identifier = utf8.encode('WireGuard v1 zx2c4 Jason@zx2c4.com');
  static final Uint8List _labelMac1 = utf8.encode('mac1----');

  static final Blake2s _hash = Blake2s();
  static final Blake2s _mac16 = Blake2s(hashLengthInBytes: 16);
  static final Chacha20 _aead = Chacha20.poly1305Aead();
  static final X25519 _dh = X25519();

  /// Builds a 148-byte handshake initiation.
  ///
  /// [staticPrivateKey] / [peerPublicKey] are the 32-byte WARP keys, [timestamp]
  /// must be strictly increasing between initiations for the same static key
  /// (WireGuard rejects replays), [ephemeralSeed] may be fixed for tests.
  static Future<Uint8List> buildInitiation({
    required Uint8List staticPrivateKey,
    required Uint8List peerPublicKey,
    required int senderIndex,
    required DateTime timestamp,
    Uint8List? ephemeralSeed,
  }) async {
    final staticPair = await _dh.newKeyPairFromSeed(staticPrivateKey);
    final staticPublic = Uint8List.fromList((await staticPair.extractPublicKey()).bytes);
    final ephemeralPair = ephemeralSeed == null ? await _dh.newKeyPair() : await _dh.newKeyPairFromSeed(ephemeralSeed);
    final ephemeralPublic = Uint8List.fromList((await ephemeralPair.extractPublicKey()).bytes);
    final peer = SimplePublicKey(peerPublicKey, type: KeyPairType.x25519);

    var chaining = await _h(_construction);
    var hash = await _h(_concat([chaining, _identifier]));
    hash = await _h(_concat([hash, peerPublicKey]));

    chaining = (await _kdf(chaining, ephemeralPublic, 1))[0];
    hash = await _h(_concat([hash, ephemeralPublic]));

    final es = await _sharedSecret(ephemeralPair, peer);
    var derived = await _kdf(chaining, es, 2);
    chaining = derived[0];
    final encryptedStatic = await _seal(derived[1], 0, staticPublic, hash);
    hash = await _h(_concat([hash, encryptedStatic]));

    final ss = await _sharedSecret(staticPair, peer);
    derived = await _kdf(chaining, ss, 2);
    chaining = derived[0];
    final encryptedTimestamp = await _seal(derived[1], 0, tai64n(timestamp), hash);

    final message = Uint8List(initiationLength);
    final view = ByteData.sublistView(message);
    message[0] = messageInitiation;
    view.setUint32(4, senderIndex, Endian.little);
    message.setRange(8, 40, ephemeralPublic);
    message.setRange(40, 88, encryptedStatic);
    message.setRange(88, 116, encryptedTimestamp);
    final mac1Key = await _h(_concat([_labelMac1, peerPublicKey]));
    final mac1 = await _mac16.calculateMac(message.sublist(0, 116), secretKey: SecretKey(mac1Key));
    message.setRange(116, 132, mac1.bytes);
    // mac2 stays zero: we never hold a cookie.
    return message;
  }

  /// True when [packet] is a handshake response addressed to [senderIndex].
  static bool isResponseFor(Uint8List packet, int senderIndex) {
    if (packet.length != responseLength) return false;
    if (packet[0] != messageResponse || packet[1] != 0 || packet[2] != 0 || packet[3] != 0) return false;
    final receiverIndex = ByteData.sublistView(packet).getUint32(8, Endian.little);
    return receiverIndex == senderIndex;
  }

  /// True when [packet] is a cookie reply (endpoint alive but under load).
  static bool isCookieReplyFor(Uint8List packet, int senderIndex) {
    if (packet.length != 64 || packet[0] != messageCookieReply) return false;
    return ByteData.sublistView(packet).getUint32(4, Endian.little) == senderIndex;
  }

  /// Our sender index echoed back by a handshake response or a cookie reply,
  /// or null for anything else.
  static int? receiverIndexOf(Uint8List packet) {
    if (packet.length == responseLength && packet[0] == messageResponse) {
      return ByteData.sublistView(packet).getUint32(8, Endian.little);
    }
    if (packet.length == 64 && packet[0] == messageCookieReply) {
      return ByteData.sublistView(packet).getUint32(4, Endian.little);
    }
    return null;
  }

  /// TAI64N label: 8-byte big-endian seconds offset by 2^62, 4-byte nanoseconds.
  static Uint8List tai64n(DateTime time) {
    final micros = time.toUtc().microsecondsSinceEpoch;
    final seconds = micros ~/ 1000000;
    final nanos = (micros % 1000000) * 1000;
    final out = Uint8List(12);
    final view = ByteData.sublistView(out);
    view.setUint32(0, 0x40000000);
    view.setUint32(4, seconds);
    view.setUint32(8, nanos);
    return out;
  }

  static Future<Uint8List> _h(List<int> data) async => Uint8List.fromList((await _hash.hash(data)).bytes);

  /// RFC 2104 HMAC over BLAKE2s with its 64-byte block, written out by hand:
  /// `package:cryptography`'s generic `Hmac(Blake2s())` does not produce the
  /// standard result (verified against Python's `hmac` module).
  static Future<Uint8List> _hmacOf(Uint8List key, List<int> data) async {
    const block = 64;
    var k = key;
    if (k.length > block) k = await _h(k);
    final padded = Uint8List(block)..setRange(0, k.length, k);
    final ipad = Uint8List(block);
    final opad = Uint8List(block);
    for (var i = 0; i < block; i++) {
      ipad[i] = padded[i] ^ 0x36;
      opad[i] = padded[i] ^ 0x5c;
    }
    final inner = await _h(_concat([ipad, data]));
    return _h(_concat([opad, inner]));
  }

  /// WireGuard KDF_n: HMAC-BLAKE2s chain (HKDF expand with counter bytes).
  static Future<List<Uint8List>> _kdf(Uint8List key, Uint8List input, int n) async {
    final prk = await _hmacOf(key, input);
    final out = <Uint8List>[];
    var previous = Uint8List(0);
    for (var i = 1; i <= n; i++) {
      previous = await _hmacOf(prk, _concat([previous, Uint8List.fromList([i])]));
      out.add(previous);
    }
    return out;
  }

  static Future<Uint8List> _sharedSecret(SimpleKeyPair pair, SimplePublicKey remote) async {
    final secret = await _dh.sharedSecretKey(keyPair: pair, remotePublicKey: remote);
    return Uint8List.fromList(await secret.extractBytes());
  }

  /// ChaCha20-Poly1305 with the WireGuard nonce layout (32 zero bits, LE64 counter).
  static Future<Uint8List> _seal(Uint8List key, int counter, Uint8List plain, Uint8List aad) async {
    final nonce = Uint8List(12);
    ByteData.sublistView(nonce).setUint32(4, counter, Endian.little);
    final box = await _aead.encrypt(plain, secretKey: SecretKey(key), nonce: nonce, aad: aad);
    return _concat([Uint8List.fromList(box.cipherText), Uint8List.fromList(box.mac.bytes)]);
  }

  static Uint8List _concat(List<List<int>> parts) {
    final total = parts.fold<int>(0, (sum, p) => sum + p.length);
    final out = Uint8List(total);
    var offset = 0;
    for (final part in parts) {
      out.setRange(offset, offset + part.length, part);
      offset += part.length;
    }
    return out;
  }
}
