import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Local persistence for the source list bootstrap.
///
/// * The last accepted **signed envelope** is stored verbatim so it can be
///   re-verified on every start (a tampered cache is simply ignored).
/// * Small bookkeeping values live in shared preferences.
class SourceListStore {
  SourceListStore({required Directory directory, required SharedPreferences preferences})
    : _directory = directory,
      _preferences = preferences;

  static const String fileName = 'sources.signed.json';
  static const String _keyLastAcceptedVersion = 'sources.last_accepted_version';
  static const String _keyLastFetchAt = 'sources.last_fetch_at';
  static const String _keyCustomMirror = 'sources.custom_mirror';

  final Directory _directory;
  final SharedPreferences _preferences;

  File get file => File(p.join(_directory.path, fileName));

  /// Returns the cached envelope text or `null` when absent/unreadable.
  Future<String?> readCachedEnvelope() async {
    try {
      if (!file.existsSync()) return null;
      return await file.readAsString();
    } on FileSystemException {
      return null;
    }
  }

  /// Atomically replaces the cached envelope (write to temp file, then rename).
  Future<void> writeCachedEnvelope(String envelopeText) async {
    if (!_directory.existsSync()) {
      await _directory.create(recursive: true);
    }
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(envelopeText, flush: true);
    await tmp.rename(file.path);
  }

  Future<void> clearCache() async {
    try {
      if (file.existsSync()) await file.delete();
    } on FileSystemException {
      // ignore: nothing else to do, the cache is best-effort
    }
  }

  /// Highest list version ever accepted on this device (anti-rollback floor).
  int? get lastAcceptedVersion => _preferences.getInt(_keyLastAcceptedVersion);

  Future<void> setLastAcceptedVersion(int version) async {
    final current = lastAcceptedVersion;
    if (current == null || version > current) {
      await _preferences.setInt(_keyLastAcceptedVersion, version);
    }
  }

  DateTime? get lastFetchAt {
    final raw = _preferences.getInt(_keyLastFetchAt);
    return raw == null ? null : DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
  }

  Future<void> setLastFetchAt(DateTime value) =>
      _preferences.setInt(_keyLastFetchAt, value.toUtc().millisecondsSinceEpoch);

  /// Optional user-provided mirror (advanced settings). Must be https.
  Uri? get customMirror {
    final raw = _preferences.getString(_keyCustomMirror);
    if (raw == null || raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
    return uri;
  }

  /// Stores (or clears, when `null`) the custom mirror. Returns `false` when
  /// the value is rejected (non-https or unparsable).
  Future<bool> setCustomMirror(String? raw) async {
    final trimmed = raw?.trim() ?? '';
    if (trimmed.isEmpty) {
      await _preferences.remove(_keyCustomMirror);
      return true;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    await _preferences.setString(_keyCustomMirror, uri.toString());
    return true;
  }
}
