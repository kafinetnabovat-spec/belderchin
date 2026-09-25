import 'package:hiddify/core/security/ed25519_verifier.dart';
import 'package:hiddify/features/sources/data/trusted_keys.dart';
import 'package:hiddify/features/sources/model/signed_envelope.dart';
import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:meta/meta.dart';

/// Why a signed source list was rejected.
enum SourceListRejection {
  /// Envelope or payload does not match the schema.
  malformed,

  /// `key_id` is not one of the embedded trusted keys.
  unknownKey,

  /// Ed25519 signature does not verify.
  badSignature,

  /// `issued_at` lies in the future (beyond the accepted clock skew).
  issuedInFuture,

  /// `version` is lower than a list that was already accepted.
  rollback,
}

/// Outcome of [SourceListValidator.validate].
@immutable
sealed class SourceListValidation {
  const SourceListValidation();
}

class SourceListAccepted extends SourceListValidation {
  const SourceListAccepted({
    required this.list,
    required this.envelope,
    required this.expired,
    required this.requiresNewerApp,
  });

  final SourceList list;
  final SignedEnvelope envelope;

  /// The list is authentic but past `expires_at`. Callers may still use it as
  /// a last resort (availability beats freshness for a censorship-circumvention
  /// tool) but must try to refresh and must surface the condition to the user.
  final bool expired;

  /// `min_app_version` is higher than the running app.
  final bool requiresNewerApp;
}

class SourceListRejected extends SourceListValidation {
  const SourceListRejected(this.reason, this.detail);

  final SourceListRejection reason;
  final String detail;

  @override
  String toString() => 'SourceListRejected(${reason.name}: $detail)';
}

/// Verifies a signed source list end to end:
///
/// 1. structural parse of the envelope,
/// 2. key lookup among the embedded trusted keys,
/// 3. Ed25519 signature over `prefix || payload`,
/// 4. strict schema parse of the payload,
/// 5. temporal sanity (`issued_at` not in the future beyond [clockSkew]),
/// 6. anti-rollback against [previousVersion].
///
/// Expiry does **not** reject (see [SourceListAccepted.expired]).
class SourceListValidator {
  const SourceListValidator({
    required this.trustedKeys,
    this.verifier = const Ed25519Verifier(),
    this.clockSkew = const Duration(hours: 36),
  });

  final List<TrustedKey> trustedKeys;
  final Ed25519Verifier verifier;

  /// Tolerated difference between the signer's clock and the device clock.
  /// Devices in the target region frequently have wrong clocks, so this is
  /// generous; the signature is what actually protects integrity.
  final Duration clockSkew;

  Future<SourceListValidation> validate(
    String envelopeText, {
    required DateTime now,
    int? previousVersion,
    AppVersion? appVersion,
  }) async {
    final SignedEnvelope envelope;
    try {
      envelope = SignedEnvelope.parse(envelopeText);
    } on SourceListFormatException catch (e) {
      return SourceListRejected(SourceListRejection.malformed, e.message);
    }

    final key = findTrustedKey(trustedKeys, envelope.keyId);
    if (key == null) {
      return SourceListRejected(SourceListRejection.unknownKey, 'key "${envelope.keyId}" is not trusted');
    }

    final ok = await verifier.verify(
      message: envelope.signedMessage,
      signature: envelope.signature,
      publicKey: key.publicKey,
    );
    if (!ok) {
      return const SourceListRejected(SourceListRejection.badSignature, 'signature verification failed');
    }

    final SourceList list;
    try {
      list = SourceList.fromJson(envelope.decodePayload());
    } on SourceListFormatException catch (e) {
      return SourceListRejected(SourceListRejection.malformed, e.message);
    }

    if (list.issuedAt.isAfter(now.toUtc().add(clockSkew))) {
      return SourceListRejected(
        SourceListRejection.issuedInFuture,
        'issued_at ${list.issuedAt.toIso8601String()} is in the future',
      );
    }
    if (previousVersion != null && list.version < previousVersion) {
      return SourceListRejected(
        SourceListRejection.rollback,
        'version ${list.version} is older than accepted version $previousVersion',
      );
    }

    final minApp = list.minAppVersion;
    final requiresNewerApp = minApp != null && appVersion != null && appVersion < minApp;
    return SourceListAccepted(
      list: list,
      envelope: envelope,
      expired: list.isExpiredAt(now.toUtc()),
      requiresNewerApp: requiresNewerApp,
    );
  }
}
