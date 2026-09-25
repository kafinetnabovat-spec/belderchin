import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/security/ed25519_verifier.dart';

void main() {
  const verifier = Ed25519Verifier();

  late Uint8List publicKey;
  late Uint8List signature;
  final message = Uint8List.fromList(utf8.encode('belderchin test message'));

  setUpAll(() async {
    final keyPair = await Ed25519().newKeyPair();
    publicKey = Uint8List.fromList((await keyPair.extractPublicKey()).bytes);
    signature = Uint8List.fromList((await Ed25519().sign(message, keyPair: keyPair)).bytes);
  });

  test('accepts a genuine signature', () async {
    expect(await verifier.verify(message: message, signature: signature, publicKey: publicKey), isTrue);
  });

  test('rejects a modified message', () async {
    final tampered = Uint8List.fromList(message)..[0] ^= 0x01;
    expect(await verifier.verify(message: tampered, signature: signature, publicKey: publicKey), isFalse);
  });

  test('rejects a modified signature', () async {
    final tampered = Uint8List.fromList(signature)..[10] ^= 0x80;
    expect(await verifier.verify(message: message, signature: tampered, publicKey: publicKey), isFalse);
  });

  test('rejects a different public key', () async {
    final other = await Ed25519().newKeyPair();
    final otherPublic = Uint8List.fromList((await other.extractPublicKey()).bytes);
    expect(await verifier.verify(message: message, signature: signature, publicKey: otherPublic), isFalse);
  });

  test('malformed lengths never throw', () async {
    expect(await verifier.verify(message: message, signature: Uint8List(63), publicKey: publicKey), isFalse);
    expect(await verifier.verify(message: message, signature: signature, publicKey: Uint8List(31)), isFalse);
    expect(await verifier.verify(message: message, signature: Uint8List(0), publicKey: Uint8List(0)), isFalse);
  });

  test('tryDecodeHex handles valid and invalid input', () {
    expect(tryDecodeHex('00ff10'), equals([0x00, 0xff, 0x10]));
    expect(tryDecodeHex('00FF'), equals([0x00, 0xff]));
    expect(tryDecodeHex('abc'), isNull);
    expect(tryDecodeHex('zz'), isNull);
    expect(tryDecodeHex(''), isNull);
  });
}
