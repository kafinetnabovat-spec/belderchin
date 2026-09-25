import 'dart:typed_data';

import 'package:hiddify/core/security/ed25519_verifier.dart';
import 'package:meta/meta.dart';

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

const List<TrustedKey> kTrustedSourceKeys = [
  // کلید قدیمی - برای سازگاری با APK های قبلی
  TrustedKey(id: 'bld-2026-09', publicKeyHex: '21cbf1c58525c5dacb8fa21a376452006b62788e73cc94fa446ff215162340a7'),
  // کلید جدید - برای امضای سورس v2 با لینک زئوس
  TrustedKey(id: 'bld-2026-09-2', publicKeyHex: 'fc2969f325a9ad65d53f7c5ddf951de92e0dc503a140458aa2718fd2f781cbf6'),
];

TrustedKey? findTrustedKey(List<TrustedKey> keys, String id) {
  for (final key in keys) {
    if (key.id == id) return key;
  }
  return null;
}
