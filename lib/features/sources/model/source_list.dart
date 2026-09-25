/// Data model of the Belderchin *source list*: the signed JSON document that
/// tells the app where connection material can be obtained.
///
/// Layers (tried in this order by the auto-connect chain, Phase 4):
///  1. `warp`    – Cloudflare WARP (WireGuard) with endpoint/port hints,
///  2. `workers` – Cloudflare Workers subscription links,
///  3. `backup`  – last-resort subscriptions or inline configs.
///
/// Parsing is strict on purpose: a document that does not match the schema is
/// rejected as a whole (see [SourceListFormatException]) so that a partially
/// valid list can never put the app in a half-configured state.
library;

import 'package:meta/meta.dart';

/// Raised when a JSON document does not match the source list schema.
class SourceListFormatException implements Exception {
  const SourceListFormatException(this.message);

  final String message;

  @override
  String toString() => 'SourceListFormatException: $message';
}

@immutable
class SourceList {
  const SourceList({
    required this.version,
    required this.issuedAt,
    required this.expiresAt,
    required this.minAppVersion,
    required this.mirrors,
    required this.healthCheck,
    required this.warp,
    required this.workers,
    required this.backup,
    this.notes,
  });

  /// Monotonically increasing list version (anti-rollback counter).
  final int version;
  final DateTime issuedAt;
  final DateTime expiresAt;

  /// Optional minimum app version (`X.Y.Z`) able to use this list.
  final AppVersion? minAppVersion;

  /// Additional mirrors advertised by the list itself (https only). They are
  /// merged with the built-in mirrors; they never replace them.
  final List<Uri> mirrors;
  final HealthCheckConfig? healthCheck;
  final WarpHints warp;
  final List<SourceEntry> workers;
  final List<SourceEntry> backup;
  final String? notes;

  bool isExpiredAt(DateTime now) => !expiresAt.isAfter(now);

  /// All subscription-like entries in priority order (workers first).
  List<SourceEntry> get orderedEntries => [...workers, ...backup];

  /// Parses the *payload* object (not the signed envelope).
  factory SourceList.fromJson(Map<String, Object?> json) {
    final version = _readInt(json, 'version');
    if (version < 1) throw const SourceListFormatException('version must be >= 1');
    final issuedAt = _readTimestamp(json, 'issued_at');
    final expiresAt = _readTimestamp(json, 'expires_at');
    if (!expiresAt.isAfter(issuedAt)) {
      throw const SourceListFormatException('expires_at must be after issued_at');
    }
    final minAppVersionRaw = json['min_app_version'];
    AppVersion? minAppVersion;
    if (minAppVersionRaw != null) {
      if (minAppVersionRaw is! String) throw const SourceListFormatException('min_app_version must be a string');
      minAppVersion = AppVersion.tryParse(minAppVersionRaw);
      if (minAppVersion == null) throw const SourceListFormatException('min_app_version must look like X.Y.Z');
    }

    final mirrors = <Uri>[];
    for (final raw in _readList(json, 'mirrors')) {
      if (raw is! String) throw const SourceListFormatException('mirrors must contain strings');
      mirrors.add(_readHttpsUri(raw, 'mirrors'));
    }

    final healthRaw = json['health_check'];
    HealthCheckConfig? healthCheck;
    if (healthRaw != null) {
      if (healthRaw is! Map<String, Object?>) throw const SourceListFormatException('health_check must be an object');
      healthCheck = HealthCheckConfig.fromJson(healthRaw);
    }

    final warpRaw = json['warp'];
    final WarpHints warp;
    if (warpRaw == null) {
      warp = const WarpHints(enabled: false, endpoints: [], ports: []);
    } else if (warpRaw is Map<String, Object?>) {
      warp = WarpHints.fromJson(warpRaw);
    } else {
      throw const SourceListFormatException('warp must be an object');
    }

    final seenIds = <String>{};
    List<SourceEntry> readEntries(String key) {
      final out = <SourceEntry>[];
      for (final raw in _readList(json, key)) {
        if (raw is! Map<String, Object?>) throw SourceListFormatException('$key must contain objects');
        final entry = SourceEntry.fromJson(raw, layer: key);
        if (!seenIds.add(entry.id)) throw SourceListFormatException('duplicate source id "${entry.id}"');
        out.add(entry);
      }
      return out;
    }

    final workers = readEntries('workers');
    final backup = readEntries('backup');
    final notes = json['notes'];
    if (notes != null && notes is! String) throw const SourceListFormatException('notes must be a string');

    return SourceList(
      version: version,
      issuedAt: issuedAt,
      expiresAt: expiresAt,
      minAppVersion: minAppVersion,
      mirrors: List.unmodifiable(mirrors),
      healthCheck: healthCheck,
      warp: warp,
      workers: List.unmodifiable(workers),
      backup: List.unmodifiable(backup),
      notes: notes as String?,
    );
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'issued_at': _formatTimestamp(issuedAt),
    'expires_at': _formatTimestamp(expiresAt),
    if (minAppVersion != null) 'min_app_version': minAppVersion.toString(),
    'mirrors': mirrors.map((m) => m.toString()).toList(),
    if (healthCheck != null) 'health_check': healthCheck!.toJson(),
    'warp': warp.toJson(),
    'workers': workers.map((e) => e.toJson()).toList(),
    'backup': backup.map((e) => e.toJson()).toList(),
    if (notes != null) 'notes': notes,
  };
}

/// One subscription-like connection source (Workers or backup layer).
@immutable
class SourceEntry {
  const SourceEntry({
    required this.id,
    required this.name,
    required this.layer,
    required this.weight,
    this.url,
    this.content,
  }) : assert(url != null || content != null, 'either url or content is required');

  /// Stable identifier, used for local bookkeeping (success/failure memory).
  final String id;

  /// Human readable label (may be shown in the troubleshooting page).
  final String name;

  /// `workers` or `backup`.
  final String layer;

  /// Relative preference inside its layer; higher is tried first. Ties keep
  /// document order.
  final int weight;

  /// Remote subscription URL (https only).
  final Uri? url;

  /// Inline configuration (share links, base64 subscription body or JSON).
  final String? content;

  bool get isRemote => url != null;

  factory SourceEntry.fromJson(Map<String, Object?> json, {required String layer}) {
    final id = _readString(json, 'id');
    if (id.isEmpty || id.length > 64) throw const SourceListFormatException('source id must be 1..64 chars');
    final name = _readString(json, 'name');
    final urlRaw = json['url'];
    final contentRaw = json['content'];
    Uri? url;
    if (urlRaw != null) {
      if (urlRaw is! String) throw SourceListFormatException('source "$id": url must be a string');
      url = _readHttpsUri(urlRaw, 'source "$id"');
    }
    String? content;
    if (contentRaw != null) {
      if (contentRaw is! String || contentRaw.trim().isEmpty) {
        throw SourceListFormatException('source "$id": content must be a non-empty string');
      }
      content = contentRaw;
    }
    if (url == null && content == null) {
      throw SourceListFormatException('source "$id": needs url or content');
    }
    final weightRaw = json['weight'] ?? 1;
    if (weightRaw is! int || weightRaw < 0) {
      throw SourceListFormatException('source "$id": weight must be a non-negative integer');
    }
    return SourceEntry(id: id, name: name, layer: layer, weight: weightRaw, url: url, content: content);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'weight': weight,
    if (url != null) 'url': url.toString(),
    if (content != null) 'content': content,
  };

  @override
  bool operator ==(Object other) =>
      other is SourceEntry &&
      other.id == id &&
      other.name == name &&
      other.layer == layer &&
      other.weight == weight &&
      other.url == url &&
      other.content == content;

  @override
  int get hashCode => Object.hash(id, name, layer, weight, url, content);
}

/// Hints for the WARP layer (consumed by the endpoint scanner in Phase 5).
@immutable
class WarpHints {
  const WarpHints({required this.enabled, required this.endpoints, required this.ports});

  final bool enabled;

  /// IPv4/IPv6 CIDR ranges of Cloudflare WARP endpoints.
  final List<String> endpoints;

  /// UDP ports known to accept WireGuard handshakes.
  final List<int> ports;

  factory WarpHints.fromJson(Map<String, Object?> json) {
    final enabledRaw = json['enabled'] ?? true;
    if (enabledRaw is! bool) throw const SourceListFormatException('warp.enabled must be a boolean');
    final endpoints = <String>[];
    for (final raw in _readList(json, 'endpoints')) {
      if (raw is! String || !_looksLikeCidr(raw)) {
        throw SourceListFormatException('warp.endpoints: invalid CIDR "$raw"');
      }
      endpoints.add(raw);
    }
    final ports = <int>[];
    for (final raw in _readList(json, 'ports')) {
      if (raw is! int || raw < 1 || raw > 65535) throw SourceListFormatException('warp.ports: invalid port "$raw"');
      ports.add(raw);
    }
    return WarpHints(enabled: enabledRaw, endpoints: List.unmodifiable(endpoints), ports: List.unmodifiable(ports));
  }

  Map<String, Object?> toJson() => {'enabled': enabled, 'endpoints': endpoints, 'ports': ports};
}

/// Connectivity probe configuration used by the in-tunnel health check.
@immutable
class HealthCheckConfig {
  const HealthCheckConfig({required this.urls, required this.minSuccess, required this.timeout});

  final List<Uri> urls;

  /// Minimum number of probes that must succeed ("N of M").
  final int minSuccess;
  final Duration timeout;

  factory HealthCheckConfig.fromJson(Map<String, Object?> json) {
    final urls = <Uri>[];
    for (final raw in _readList(json, 'urls')) {
      if (raw is! String) throw const SourceListFormatException('health_check.urls must contain strings');
      final uri = Uri.tryParse(raw);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https') || uri.host.isEmpty) {
        throw SourceListFormatException('health_check.urls: invalid url "$raw"');
      }
      urls.add(uri);
    }
    if (urls.isEmpty) throw const SourceListFormatException('health_check.urls must not be empty');
    final minSuccessRaw = json['min_success'] ?? 1;
    if (minSuccessRaw is! int || minSuccessRaw < 1 || minSuccessRaw > urls.length) {
      throw const SourceListFormatException('health_check.min_success must be within 1..urls.length');
    }
    final timeoutRaw = json['timeout_ms'] ?? 5000;
    if (timeoutRaw is! int || timeoutRaw < 500 || timeoutRaw > 60000) {
      throw const SourceListFormatException('health_check.timeout_ms must be within 500..60000');
    }
    return HealthCheckConfig(
      urls: List.unmodifiable(urls),
      minSuccess: minSuccessRaw,
      timeout: Duration(milliseconds: timeoutRaw),
    );
  }

  Map<String, Object?> toJson() => {
    'urls': urls.map((u) => u.toString()).toList(),
    'min_success': minSuccess,
    'timeout_ms': timeout.inMilliseconds,
  };
}

/// Minimal `major.minor.patch` version used for `min_app_version` checks.
@immutable
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static final RegExp _pattern = RegExp(r'^(\d+)\.(\d+)\.(\d+)');

  /// Accepts `1.2.3`, `1.2.3+45` and `1.2.3-beta` (suffixes are ignored).
  static AppVersion? tryParse(String input) {
    final match = _pattern.firstMatch(input.trim());
    if (match == null) return null;
    return AppVersion(int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!));
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  bool operator <(AppVersion other) => compareTo(other) < 0;
  bool operator >=(AppVersion other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      other is AppVersion && other.major == major && other.minor == minor && other.patch == patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

// ---------------------------------------------------------------------------
// strict JSON helpers

int _readInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! int) throw SourceListFormatException('$key must be an integer');
  return value;
}

String _readString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw SourceListFormatException('$key must be a string');
  return value;
}

List<Object?> _readList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return const [];
  if (value is! List<Object?>) throw SourceListFormatException('$key must be a list');
  return value;
}

final RegExp _timestampPattern = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$');

DateTime _readTimestamp(Map<String, Object?> json, String key) {
  final raw = _readString(json, key);
  if (!_timestampPattern.hasMatch(raw)) {
    throw SourceListFormatException('$key must be a UTC timestamp like 2026-01-31T12:00:00Z');
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw SourceListFormatException('$key is not a valid timestamp');
  return parsed.toUtc();
}

String _formatTimestamp(DateTime value) {
  final utc = value.toUtc();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${utc.year.toString().padLeft(4, '0')}-${two(utc.month)}-${two(utc.day)}'
      'T${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}Z';
}

Uri _readHttpsUri(String raw, String context) {
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw SourceListFormatException('$context: "$raw" is not an https url');
  }
  return uri;
}

final RegExp _cidrPattern = RegExp(r'^[0-9a-fA-F:.]+/\d{1,3}$');

bool _looksLikeCidr(String value) {
  if (!_cidrPattern.hasMatch(value)) return false;
  final parts = value.split('/');
  final address = parts[0];
  final prefix = int.parse(parts[1]);
  try {
    if (address.contains(':')) {
      return prefix <= 128 && Uri.parseIPv6Address(address).length == 16;
    }
    return prefix <= 32 && Uri.parseIPv4Address(address).length == 4;
  } on FormatException {
    return false;
  }
}
