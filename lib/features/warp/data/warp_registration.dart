import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:hiddify/features/warp/model/warp_identity.dart';

class WarpRegistrationException implements Exception {
  const WarpRegistrationException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => 'WarpRegistrationException($statusCode): $message';
}

/// Registers a new WARP device with Cloudflare's public client API — the
/// same call every official WARP client performs. Only a freshly generated
/// public key and a random install id are sent. The reply carries the
/// interface addresses, the peer key and the `client_id`.
///
/// This is the only network request of the WARP layer besides the WireGuard
/// traffic itself, and it happens once per device (the result is cached).
class WarpRegistration {
  WarpRegistration({HttpClient? client, DateTime Function()? now}) : _client = client, _now = now ?? DateTime.now;

  static final Uri apiUrl = Uri.parse('https://api.cloudflareclient.com/v0a2158/reg');
  static const String clientVersion = 'a-6.10-2158';
  static const Duration timeout = Duration(seconds: 15);

  final HttpClient? _client;
  final DateTime Function() _now;

  Future<WarpIdentity> register() async {
    final pair = await X25519().newKeyPair();
    final privateKey = base64.encode(await pair.extractPrivateKeyBytes());
    final publicKey = base64.encode((await pair.extractPublicKey()).bytes);
    final now = _now().toUtc();
    final body = jsonEncode({
      'key': publicKey,
      'install_id': _randomId(22),
      'fcm_token': '',
      'tos': now.toIso8601String(),
      'model': 'PC',
      'serial_number': '',
      'locale': 'en_US',
    });

    final client = _client ?? (HttpClient()..connectionTimeout = timeout);
    try {
      final request = await client.postUrl(apiUrl).timeout(timeout);
      request.headers
        ..set(HttpHeaders.userAgentHeader, 'okhttp/3.12.1')
        ..set(HttpHeaders.contentTypeHeader, 'application/json; charset=UTF-8')
        ..set(HttpHeaders.acceptHeader, 'application/json')
        ..set('CF-Client-Version', clientVersion);
      request.add(utf8.encode(body));
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw WarpRegistrationException('registration rejected', statusCode: response.statusCode);
      }
      final identity = parseResponse(text, privateKey: privateKey, publicKey: publicKey, createdAt: now);
      // A fresh device starts with `warp_enabled: false`; the endpoints only
      // answer handshakes once it is switched on (same as the official client).
      await _enableWarp(client, identity);
      return identity;
    } on WarpRegistrationException {
      rethrow;
    } on Exception catch (e) {
      throw WarpRegistrationException('registration failed: ${e.runtimeType}');
    } finally {
      if (_client == null) client.close(force: true);
    }
  }

  Future<void> _enableWarp(HttpClient client, WarpIdentity identity) async {
    final id = identity.deviceId;
    final token = identity.accessToken;
    if (id == null || token == null) throw const WarpRegistrationException('registration reply lacks id/token');
    final request = await client.patchUrl(apiUrl.replace(path: '${apiUrl.path}/$id')).timeout(timeout);
    request.headers
      ..set(HttpHeaders.userAgentHeader, 'okhttp/3.12.1')
      ..set(HttpHeaders.contentTypeHeader, 'application/json; charset=UTF-8')
      ..set(HttpHeaders.acceptHeader, 'application/json')
      ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
      ..set('CF-Client-Version', clientVersion);
    request.add(utf8.encode(jsonEncode({'warp_enabled': true})));
    final response = await request.close().timeout(timeout);
    await response.drain<void>().timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WarpRegistrationException('enabling warp rejected', statusCode: response.statusCode);
    }
  }

  /// Parses the `/reg` reply. Public for tests.
  static WarpIdentity parseResponse(
    String text, {
    required String privateKey,
    required String publicKey,
    required DateTime createdAt,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const WarpRegistrationException('registration reply is not JSON');
    }
    if (decoded is! Map<String, Object?>) throw const WarpRegistrationException('registration reply is not an object');
    final config = decoded['config'];
    if (config is! Map<String, Object?>) throw const WarpRegistrationException('missing config');
    final clientId = config['client_id'];
    final interface = config['interface'];
    final peers = config['peers'];
    if (clientId is! String || interface is! Map<String, Object?> || peers is! List || peers.isEmpty) {
      throw const WarpRegistrationException('incomplete config');
    }
    final addresses = interface['addresses'];
    final peer = peers.first;
    if (addresses is! Map<String, Object?> || peer is! Map<String, Object?>) {
      throw const WarpRegistrationException('incomplete config');
    }
    final v4 = addresses['v4'];
    final v6 = addresses['v6'];
    final peerKey = peer['public_key'];
    final endpoint = peer['endpoint'];
    if (v4 is! String || v6 is! String || peerKey is! String) throw const WarpRegistrationException('incomplete peer');
    var host = 'engage.cloudflareclient.com';
    if (endpoint is Map<String, Object?> && endpoint['host'] is String) {
      host = (endpoint['host']! as String).split(':').first;
    }
    final reserved = base64.decode(clientId);
    if (reserved.length != 3) throw const WarpRegistrationException('unexpected client_id length');
    return WarpIdentity(
      privateKey: privateKey,
      publicKey: publicKey,
      peerPublicKey: peerKey,
      reserved: List.unmodifiable(reserved),
      addressV4: v4.split('/').first,
      addressV6: v6.split('/').first,
      endpointHost: host,
      createdAt: createdAt,
      deviceId: decoded['id'] as String?,
      accessToken: decoded['token'] as String?,
    );
  }

  static String _randomId(int length) {
    const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(length, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }
}
