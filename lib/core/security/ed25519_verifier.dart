import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Thin wrapper around the pure-Dart Ed25519 implementation of
/// `package:cryptography`. Only *verification* is exposed on purpose: the app
/// never holds a signing key.
class Ed25519Verifier {
  const Ed25519Verifier();

  static const int publicKeyLength = 32;
  static const int signatureLength = 64;

  /// Returns `true` when [signature] is a valid Ed25519 signature of
  /// [message] under [publicKey]. Malformed inputs never throw; they simply
  /// verify as `false`.
  Future<bool> verify({
    required List<int> message,
    required List<int> signature,
    required List<int> publicKey,
  }) async {
    if (publicKey.length != publicKeyLength || signature.length != signatureLength) {
      return false;
    }
    try {
      final algorithm = Ed25519();
      final key = SimplePublicKey(Uint8List.fromList(publicKey), type: KeyPairType.ed25519);
      return await algorithm.verify(
        Uint8List.fromList(message),
        signature: Signature(Uint8List.fromList(signature), publicKey: key),
      );
    } on Exception {
      return false;
    }
  }
}

/// Decodes a lowercase/uppercase hex string into bytes, returning `null` when
/// the input is not valid hex.
Uint8List? tryDecodeHex(String hex) {
  final trimmed = hex.trim();
  if (trimmed.isEmpty || trimmed.length.isOdd) return null;
  final out = Uint8List(trimmed.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    final byte = int.tryParse(trimmed.substring(i * 2, i * 2 + 2), radix: 16);
    if (byte == null) return null;
    out[i] = byte;
  }
  return out;
}
