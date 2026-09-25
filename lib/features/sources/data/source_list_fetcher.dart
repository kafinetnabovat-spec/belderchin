import 'dart:async';

import 'package:hiddify/features/sources/data/source_list_constants.dart';
import 'package:hiddify/features/sources/data/source_list_validator.dart';
import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:meta/meta.dart';

/// Minimal HTTP abstraction so the fetcher can be unit-tested without Dio.
/// Implementations must throw on non-2xx responses.
typedef SourceHttpGet = Future<String> Function(Uri url, {required Duration timeout});

/// Diagnostic record of one mirror attempt (shown on the troubleshooting page;
/// mirror URLs are public and contain no secrets).
@immutable
class MirrorAttempt {
  const MirrorAttempt({
    required this.url,
    required this.elapsed,
    this.version,
    this.error,
  });

  final Uri url;
  final Duration elapsed;

  /// Version of the authentic list served by this mirror, if any.
  final int? version;

  /// Human readable failure reason (transport error or rejection).
  final String? error;

  bool get succeeded => error == null && version != null;

  @override
  String toString() =>
      'MirrorAttempt(${url.host}, ${elapsed.inMilliseconds}ms, ${succeeded ? 'v$version' : 'error: $error'})';
}

@immutable
class SourceListFetchResult {
  const SourceListFetchResult({required this.best, required this.attempts});

  /// The authentic list with the highest version among all mirrors, or `null`.
  final SourceListAccepted? best;
  final List<MirrorAttempt> attempts;

  bool get succeeded => best != null;
}

/// Downloads the signed list from several mirrors in parallel and keeps the
/// newest authentic copy. Every response is verified with
/// [SourceListValidator]; transport layer trust (TLS, CDN) is irrelevant for
/// integrity because only the Ed25519 signature is trusted.
class SourceListFetcher {
  const SourceListFetcher({
    required this.httpGet,
    required this.validator,
    this.mirrorTimeout = SourceListConstants.mirrorTimeout,
    this.overallTimeout = SourceListConstants.overallTimeout,
  });

  final SourceHttpGet httpGet;
  final SourceListValidator validator;
  final Duration mirrorTimeout;
  final Duration overallTimeout;

  Future<SourceListFetchResult> fetch({
    required List<Uri> mirrors,
    required DateTime now,
    int? previousVersion,
    AppVersion? appVersion,
  }) async {
    final unique = <Uri>[];
    for (final mirror in mirrors) {
      if (mirror.scheme == 'https' && !unique.contains(mirror)) unique.add(mirror);
      if (unique.length >= SourceListConstants.maxMirrors) break;
    }
    if (unique.isEmpty) {
      return const SourceListFetchResult(best: null, attempts: []);
    }

    final futures = unique.map((mirror) => _attempt(mirror, now, previousVersion, appVersion)).toList();
    final results = await Future.wait(futures).timeout(
      overallTimeout,
      onTimeout: () => [
        for (final mirror in unique) (attempt: MirrorAttempt(url: mirror, elapsed: overallTimeout, error: 'overall timeout'), accepted: null),
      ],
    );

    SourceListAccepted? best;
    final attempts = <MirrorAttempt>[];
    for (final result in results) {
      attempts.add(result.attempt);
      final accepted = result.accepted;
      if (accepted == null) continue;
      if (best == null || accepted.list.version > best.list.version) {
        best = accepted;
      }
    }
    return SourceListFetchResult(best: best, attempts: attempts);
  }

  Future<({MirrorAttempt attempt, SourceListAccepted? accepted})> _attempt(
    Uri mirror,
    DateTime now,
    int? previousVersion,
    AppVersion? appVersion,
  ) async {
    final stopwatch = Stopwatch()..start();
    final String body;
    try {
      body = await httpGet(mirror, timeout: mirrorTimeout).timeout(mirrorTimeout + const Duration(seconds: 2));
    } on Exception catch (e) {
      return (attempt: MirrorAttempt(url: mirror, elapsed: stopwatch.elapsed, error: _describe(e)), accepted: null);
    }

    final validation = await validator.validate(
      body,
      now: now,
      previousVersion: previousVersion,
      appVersion: appVersion,
    );
    stopwatch.stop();
    switch (validation) {
      case SourceListAccepted():
        return (
          attempt: MirrorAttempt(url: mirror, elapsed: stopwatch.elapsed, version: validation.list.version),
          accepted: validation,
        );
      case SourceListRejected():
        return (
          attempt: MirrorAttempt(
            url: mirror,
            elapsed: stopwatch.elapsed,
            error: '${validation.reason.name}: ${validation.detail}',
          ),
          accepted: null,
        );
    }
  }

  /// Keeps diagnostics short and free of response bodies.
  static String _describe(Exception e) {
    if (e is TimeoutException) return 'timeout';
    final text = e.toString();
    final firstLine = text.split('\n').first;
    return firstLine.length > 160 ? '${firstLine.substring(0, 160)}…' : firstLine;
  }
}
