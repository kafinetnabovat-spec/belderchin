import 'dart:convert';

import 'package:hiddify/features/warp/data/warp_endpoint_scanner.dart';
import 'package:hiddify/features/warp/model/warp_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Local persistence for the WARP layer: the device registration and the
/// last scan result (with a TTL). Nothing here ever leaves the device.
class WarpStore {
  WarpStore(this._prefs, {DateTime Function()? now}) : _now = now ?? DateTime.now;

  static const String identityKey = 'warp.identity';
  static const String endpointsKey = 'warp.endpoints';
  static const Duration endpointsTtl = Duration(hours: 12);

  final SharedPreferences _prefs;
  final DateTime Function() _now;

  WarpIdentity? loadIdentity() {
    final raw = _prefs.getString(identityKey);
    if (raw == null) return null;
    try {
      return WarpIdentity.fromJson(jsonDecode(raw) as Map<String, Object?>);
    } on Object {
      return null;
    }
  }

  Future<void> saveIdentity(WarpIdentity identity) => _prefs.setString(identityKey, jsonEncode(identity.toJson()));

  Future<void> clearIdentity() => _prefs.remove(identityKey);

  /// Cached endpoints, newest scan first by RTT; null when missing or expired.
  List<WarpScanResult>? loadEndpoints() {
    final raw = _prefs.getString(endpointsKey);
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, Object?>;
      final scannedAt = DateTime.parse(json['scanned_at']! as String);
      if (_now().difference(scannedAt) > endpointsTtl) return null;
      return (json['endpoints']! as List)
          .cast<Map<String, Object?>>()
          .map(WarpScanResult.fromJson)
          .toList();
    } on Object {
      return null;
    }
  }

  Future<void> saveEndpoints(List<WarpScanResult> results) => _prefs.setString(
    endpointsKey,
    jsonEncode({
      'scanned_at': _now().toUtc().toIso8601String(),
      'endpoints': results.map((r) => r.toJson()).toList(),
    }),
  );

  Future<void> clearEndpoints() => _prefs.remove(endpointsKey);
}
