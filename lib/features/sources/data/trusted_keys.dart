import 'dart:typed_data';

import 'package:hiddify/core/security/ed25519_verifier.dart';
import 'package:meta/meta.dart';

/// A public key the app trusts for source list signatures.
///
/// Only PUBLIC keys live here. Key rotation: add the new key, ship a release,
/// start signing with the new key, and remove the old key in a later release
/// once no user is expected to still run the old version.
@immutable
class TrustedKey {
  const TrustedKey({required this.id, required this.publicKeyHex});

  final String id;
  final String publicKeyHex;

  Uint8List get publicKey {
    final bytes = tryDecodeHex(publicKeyHex);
    if (bytes == null || bytes.length != Ed25519Verifier.publicKeyLength) {
      throw StateError('trusted key "$id" is malformed');
    }
    return bytes;
  }
}

/// Keys trusted by this build. Generated with
/// `tools/sources/belderchin_sources.py gen-key`.
const List<TrustedKey> kTrustedSourceKeys = [
  TrustedKey(id: 'bld-2026-09', publicKeyHex: '21cbf1c58525c5dacb8fa21a376452006b62788e73cc94fa446ff215162340a7'),
];

/// Small helper to look a key up by id (case-sensitive).
TrustedKey? findTrustedKey(List<TrustedKey> keys, String id) {
  for (final key in keys) {
    if (key.id == id) return key;
  }
  return null;
}
