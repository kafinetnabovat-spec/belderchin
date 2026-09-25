import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/sources/data/source_list_validator.dart';
import 'package:hiddify/features/sources/data/trusted_keys.dart';
import 'package:hiddify/features/sources/model/signed_envelope.dart';
import 'package:hiddify/features/sources/model/source_list.dart';

import 'test_signing.dart';

void main() {
  late TestSigner signer;
  late SourceListValidator validator;
  final now = DateTime.utc(2026, 9, 24, 12);

  setUpAll(() async {
    signer = await TestSigner.create(keyId: 'unit-key');
    validator = SourceListValidator(trustedKeys: [signer.trustedKey]);
  });

  Future<SourceListValidation> validate(String text, {int? previousVersion, AppVersion? appVersion}) =>
      validator.validate(text, now: now, previousVersion: previousVersion, appVersion: appVersion);

  test('accepts a genuine, current list', () async {
    final text = await signer.sign(samplePayload(version: 4));
    final result = await validate(text, previousVersion: 3, appVersion: const AppVersion(1, 0, 0));
    expect(result, isA<SourceListAccepted>());
    final accepted = result as SourceListAccepted;
    expect(accepted.list.version, 4);
    expect(accepted.expired, isFalse);
    expect(accepted.requiresNewerApp, isFalse);
    expect(accepted.envelope.keyId, 'unit-key');
  });

  test('rejects a tampered payload (signature mismatch)', () async {
    final envelope = SignedEnvelope.parse(await signer.sign(samplePayload(version: 4)));
    final tamperedPayload = Uint8List.fromList(utf8.encode(jsonEncode(samplePayload(version: 5))));
    final tampered = SignedEnvelope(keyId: envelope.keyId, payload: tamperedPayload, signature: envelope.signature);
    final result = await validate(tampered.encode());
    expect(result, isA<SourceListRejected>());
    expect((result as SourceListRejected).reason, SourceListRejection.badSignature);
  });

  test('rejects a single flipped bit in the payload', () async {
    final envelope = SignedEnvelope.parse(await signer.sign(samplePayload(version: 4)));
    final flipped = Uint8List.fromList(envelope.payload)..[3] ^= 0x01;
    final tampered = SignedEnvelope(keyId: envelope.keyId, payload: flipped, signature: envelope.signature);
    final result = await validate(tampered.encode());
    expect((result as SourceListRejected).reason, SourceListRejection.badSignature);
  });

  test('signature is bound to the domain prefix, not the bare payload', () async {
    final payloadBytes = Uint8List.fromList(utf8.encode(jsonEncode(samplePayload())));
    final envelope = await signer.signBytes(payloadBytes);
    expect(envelope.signedMessage.length, SignedEnvelope.signingPrefix.length + payloadBytes.length);
    final bareVerifies = await validator.verifier.verify(
      message: payloadBytes,
      signature: envelope.signature,
      publicKey: signer.publicKeyBytes,
    );
    expect(bareVerifies, isFalse);
  });

  test('rejects an unknown key id', () async {
    final text = await signer.sign(samplePayload(), keyIdOverride: 'someone-else');
    final result = await validate(text);
    expect((result as SourceListRejected).reason, SourceListRejection.unknownKey);
  });

  test('rejects a list signed by an untrusted key with a trusted key id', () async {
    final impostor = await TestSigner.create(keyId: 'unit-key');
    final text = await impostor.sign(samplePayload(version: 9));
    final result = await validate(text);
    expect((result as SourceListRejected).reason, SourceListRejection.badSignature);
  });

  test('rejects malformed envelopes', () async {
    for (final text in [
      '',
      'not json',
      '[]',
      '{"format":"other/1","key_id":"unit-key","payload":"AA==","signature":"AA=="}',
      '{"format":"belderchin-sources/1","payload":"AA==","signature":"AA=="}',
      '{"format":"belderchin-sources/1","key_id":"unit-key","payload":"@@","signature":"AA=="}',
      '{"format":"belderchin-sources/1","key_id":"unit-key","payload":"AA==","signature":"AA=="}',
    ]) {
      final result = await validate(text);
      expect(result, isA<SourceListRejected>(), reason: text);
      expect((result as SourceListRejected).reason, SourceListRejection.malformed, reason: text);
    }
  });

  test('rejects an oversized envelope without parsing it', () async {
    final huge = '{"format":"belderchin-sources/1","key_id":"unit-key","payload":"${'A' * (300 * 1024)}"}';
    final result = await validate(huge);
    expect((result as SourceListRejected).reason, SourceListRejection.malformed);
    expect(result.detail, contains('too large'));
  });

  test('rejects a genuine signature over an invalid schema', () async {
    final text = await signer.sign({'version': 'one'});
    final result = await validate(text);
    expect((result as SourceListRejected).reason, SourceListRejection.malformed);
  });

  test('rejects issued_at far in the future but tolerates clock skew', () async {
    final farFuture = await signer.sign(samplePayload(issuedAt: '2026-09-27T12:00:00Z', expiresAt: '2027-01-01T00:00:00Z'));
    final result = await validate(farFuture);
    expect((result as SourceListRejected).reason, SourceListRejection.issuedInFuture);

    final slightlyAhead = await signer.sign(samplePayload(issuedAt: '2026-09-25T10:00:00Z', expiresAt: '2027-01-01T00:00:00Z'));
    expect(await validate(slightlyAhead), isA<SourceListAccepted>());
  });

  test('rejects rollback to an older version', () async {
    final text = await signer.sign(samplePayload(version: 3));
    final result = await validate(text, previousVersion: 4);
    expect((result as SourceListRejected).reason, SourceListRejection.rollback);
    expect(await validate(text, previousVersion: 3), isA<SourceListAccepted>());
  });

  test('accepts an expired list but flags it', () async {
    final text = await signer.sign(samplePayload(issuedAt: '2026-01-01T00:00:00Z', expiresAt: '2026-06-01T00:00:00Z'));
    final result = await validate(text);
    expect(result, isA<SourceListAccepted>());
    expect((result as SourceListAccepted).expired, isTrue);
  });

  test('flags lists that require a newer app', () async {
    final text = await signer.sign(samplePayload(minAppVersion: '2.0.0'));
    final result = await validate(text, appVersion: const AppVersion(1, 5, 0));
    expect((result as SourceListAccepted).requiresNewerApp, isTrue);
    final ok = await validate(text, appVersion: const AppVersion(2, 0, 0));
    expect((ok as SourceListAccepted).requiresNewerApp, isFalse);
  });

  test('supports key rotation: several trusted keys', () async {
    final newSigner = await TestSigner.create(keyId: 'unit-key-2');
    final multi = SourceListValidator(trustedKeys: [signer.trustedKey, newSigner.trustedKey]);
    final oldText = await signer.sign(samplePayload());
    final newText = await newSigner.sign(samplePayload(version: 2));
    expect(await multi.validate(oldText, now: now), isA<SourceListAccepted>());
    expect(await multi.validate(newText, now: now), isA<SourceListAccepted>());
  });

  test('embedded production keys are well formed', () {
    expect(kTrustedSourceKeys, isNotEmpty);
    for (final key in kTrustedSourceKeys) {
      expect(key.publicKey, hasLength(32), reason: key.id);
    }
  });
}
