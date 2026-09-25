import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:hiddify/features/sources/data/trusted_keys.dart';
import 'package:hiddify/features/sources/model/signed_envelope.dart';

/// Test-only Ed25519 signer that mirrors `tools/sources/belderchin_sources.py`.
class TestSigner {
  TestSigner._(this.keyId, this._keyPair, this.publicKeyBytes);

  final String keyId;
  final SimpleKeyPair _keyPair;
  final Uint8List publicKeyBytes;

  static Future<TestSigner> create({String keyId = 'test-key'}) async {
    final keyPair = await Ed25519().newKeyPair();
    final publicKey = await keyPair.extractPublicKey();
    return TestSigner._(keyId, keyPair, Uint8List.fromList(publicKey.bytes));
  }

  TrustedKey get trustedKey => TrustedKey(id: keyId, publicKeyHex: _hex(publicKeyBytes));

  /// Signs [payload] (a JSON object) and returns the envelope text.
  Future<String> sign(Map<String, Object?> payload, {String? keyIdOverride}) async {
    final payloadBytes = Uint8List.fromList(utf8.encode(jsonEncode(payload)));
    final envelope = await signBytes(payloadBytes, keyIdOverride: keyIdOverride);
    return envelope.encode();
  }

  Future<SignedEnvelope> signBytes(Uint8List payloadBytes, {String? keyIdOverride}) async {
    final message = Uint8List.fromList([...SignedEnvelope.signingPrefix, ...payloadBytes]);
    final signature = await Ed25519().sign(message, keyPair: _keyPair);
    return SignedEnvelope(
      keyId: keyIdOverride ?? keyId,
      payload: payloadBytes,
      signature: Uint8List.fromList(signature.bytes),
    );
  }

  static String _hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// A schema-valid payload with sensible defaults; override fields as needed.
Map<String, Object?> samplePayload({
  int version = 1,
  String issuedAt = '2026-09-01T00:00:00Z',
  String expiresAt = '2027-03-01T00:00:00Z',
  String? minAppVersion,
  List<String> mirrors = const [],
  List<Map<String, Object?>> workers = const [],
  List<Map<String, Object?>> backup = const [],
}) {
  return {
    'version': version,
    'issued_at': issuedAt,
    'expires_at': expiresAt,
    if (minAppVersion != null) 'min_app_version': minAppVersion,
    'mirrors': mirrors,
    'health_check': {
      'urls': ['http://cp.cloudflare.com/generate_204', 'http://detectportal.firefox.com/success.txt'],
      'min_success': 1,
      'timeout_ms': 5000,
    },
    'warp': {
      'enabled': true,
      'endpoints': ['162.159.192.0/24', '2606:4700:d0::/48'],
      'ports': [2408, 500],
    },
    'workers': workers,
    'backup': backup,
  };
}
