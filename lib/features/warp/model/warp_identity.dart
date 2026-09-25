import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

/// A WARP device registration: our WireGuard key pair plus what Cloudflare
/// handed back (addresses, peer key, `client_id` → `reserved` bytes).
///
/// Stored locally only. The private key never leaves the device except as the
/// WireGuard handshake requires (it is *not* sent to the registration API —
/// only the public key is).
@immutable
class WarpIdentity {
  const WarpIdentity({
    required this.privateKey,
    required this.publicKey,
    required this.peerPublicKey,
    required this.reserved,
    required this.addressV4,
    required this.addressV6,
    required this.endpointHost,
    required this.createdAt,
    this.deviceId,
    this.accessToken,
  });

  /// Base64 WireGuard keys.
  final String privateKey;
  final String publicKey;
  final String peerPublicKey;

  /// Three bytes derived from `client_id`; sing-box puts them in the reserved
  /// field of every WireGuard packet header.
  final List<int> reserved;

  /// Interface addresses without prefix, e.g. `172.16.0.2`.
  final String addressV4;
  final String addressV6;

  /// `engage.cloudflareclient.com`.
  final String endpointHost;
  final DateTime createdAt;

  /// Optional account handles (not needed for connecting; kept for future
  /// deletion / refresh of the registration).
  final String? deviceId;
  final String? accessToken;

  Uint8List get privateKeyBytes => base64.decode(privateKey);
  Uint8List get peerPublicKeyBytes => base64.decode(peerPublicKey);

  Map<String, Object?> toJson() => {
    'private_key': privateKey,
    'public_key': publicKey,
    'peer_public_key': peerPublicKey,
    'reserved': reserved,
    'address_v4': addressV4,
    'address_v6': addressV6,
    'endpoint_host': endpointHost,
    'created_at': createdAt.toUtc().toIso8601String(),
    if (deviceId != null) 'device_id': deviceId,
    if (accessToken != null) 'access_token': accessToken,
  };

  factory WarpIdentity.fromJson(Map<String, Object?> json) => WarpIdentity(
    privateKey: json['private_key']! as String,
    publicKey: json['public_key']! as String,
    peerPublicKey: json['peer_public_key']! as String,
    reserved: (json['reserved']! as List).cast<int>(),
    addressV4: json['address_v4']! as String,
    addressV6: json['address_v6']! as String,
    endpointHost: json['endpoint_host']! as String,
    createdAt: DateTime.parse(json['created_at']! as String),
    deviceId: json['device_id'] as String?,
    accessToken: json['access_token'] as String?,
  );

  @override
  String toString() => 'WarpIdentity(pub=${publicKey.substring(0, 6)}…, v4=$addressV4)';
}
