import 'dart:convert';
import 'dart:typed_data';

import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:meta/meta.dart';

/// Wire format produced by `tools/sources/belderchin_sources.py sign`.
///
/// ```json
/// {
///   "format": "belderchin-sources/1",
///   "key_id": "bld-2026-09",
///   "payload": "<base64 of UTF-8 JSON bytes>",
///   "signature": "<base64 of 64-byte Ed25519 signature>"
/// }
/// ```
///
/// The signature covers [signingPrefix] followed by the raw payload bytes.
/// The prefix provides domain separation so a signature made for another
/// purpose with the same key can never be replayed as a source list.
@immutable
class SignedEnvelope {
  const SignedEnvelope({
    required this.keyId,
    required this.payload,
    required this.signature,
  });

  static const String format = 'belderchin-sources/1';
  static final Uint8List signingPrefix = Uint8List.fromList(utf8.encode('belderchin-sources-v1:'));

  /// Maximum accepted document size; a source list is a few kilobytes.
  static const int maxEnvelopeBytes = 256 * 1024;

  final String keyId;
  final Uint8List payload;
  final Uint8List signature;

  /// Bytes that were actually signed: `signingPrefix || payload`.
  Uint8List get signedMessage => Uint8List.fromList([...signingPrefix, ...payload]);

  /// Parses the envelope from its textual JSON form. Throws
  /// [SourceListFormatException] on any structural problem.
  factory SignedEnvelope.parse(String text) {
    if (text.length > maxEnvelopeBytes) {
      throw const SourceListFormatException('envelope too large');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException catch (e) {
      throw SourceListFormatException('envelope is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const SourceListFormatException('envelope must be a JSON object');
    }
    if (decoded['format'] != format) {
      throw SourceListFormatException('unsupported envelope format "${decoded['format']}"');
    }
    final keyId = decoded['key_id'];
    if (keyId is! String || keyId.isEmpty || keyId.length > 64) {
      throw const SourceListFormatException('envelope key_id missing');
    }
    final payload = _readBase64(decoded, 'payload');
    final signature = _readBase64(decoded, 'signature');
    if (signature.length != 64) {
      throw const SourceListFormatException('signature must be 64 bytes');
    }
    if (payload.isEmpty) {
      throw const SourceListFormatException('payload is empty');
    }
    return SignedEnvelope(keyId: keyId, payload: payload, signature: signature);
  }

  /// Decodes the payload as a JSON object (does not verify anything).
  Map<String, Object?> decodePayload() {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(payload));
    } on FormatException catch (e) {
      throw SourceListFormatException('payload is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const SourceListFormatException('payload must be a JSON object');
    }
    return decoded;
  }

  Map<String, Object?> toJson() => {
    'format': format,
    'key_id': keyId,
    'payload': base64Encode(payload),
    'signature': base64Encode(signature),
  };

  String encode() => jsonEncode(toJson());
}

Uint8List _readBase64(Map<String, Object?> json, String key) {
  final raw = json[key];
  if (raw is! String || raw.isEmpty) {
    throw SourceListFormatException('envelope $key missing');
  }
  try {
    return base64Decode(raw.trim());
  } on FormatException {
    throw SourceListFormatException('envelope $key is not valid base64');
  }
}
