import 'dart:async';
import 'dart:io';

import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:meta/meta.dart';

/// Result of probing the tunnel.
@immutable
class HealthResult {
  const HealthResult({required this.succeeded, required this.required, required this.total, required this.latency});

  final int succeeded;
  final int required;
  final int total;

  /// Best (lowest) latency among successful probes, or null.
  final Duration? latency;

  bool get healthy => succeeded >= required;

  @override
  String toString() => 'HealthResult($succeeded/$total ok, need $required, ${latency?.inMilliseconds}ms)';
}

/// Single probe function; returns the latency on success or null on failure.
typedef Probe = Future<Duration?> Function(Uri url, Duration timeout);

/// "N of M" health check. All probes run in parallel through the local mixed
/// proxy of the core, so success proves that traffic actually flows through
/// the tunnel (not just that the core process started).
class HealthChecker {
  HealthChecker({required this.mixedPort, Probe? probe}) : _probe = probe;

  final int mixedPort;
  final Probe? _probe;

  Future<HealthResult> check(HealthCheckConfig config) async {
    final urls = config.urls;
    if (urls.isEmpty) {
      return const HealthResult(succeeded: 0, required: 1, total: 0, latency: null);
    }
    final timeout = config.timeout;
    final probe = _probe ?? _httpProbe;
    final results = await Future.wait(urls.map((u) => probe(u, timeout)));
    final ok = results.whereType<Duration>().toList()..sort();
    final required = config.minSuccess.clamp(1, urls.length);
    return HealthResult(
      succeeded: ok.length,
      required: required,
      total: urls.length,
      latency: ok.isEmpty ? null : ok.first,
    );
  }

  /// A probe is a success when the HTTP status is 204, or 200 with an empty /
  /// tiny body (generate_204 style endpoints). Redirects are NOT followed:
  /// captive portals and DPI boxes answer with 30x/200 pages.
  Future<Duration?> _httpProbe(Uri url, Duration timeout) async {
    final proxy = 'PROXY 127.0.0.1:$mixedPort';
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..userAgent = 'Belderchin-HealthCheck/1'
      ..autoUncompress = false;
    client.findProxy = (_) => proxy;
    final watch = Stopwatch()..start();
    try {
      final request = await client.getUrl(url).timeout(timeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close().timeout(timeout);
      final status = response.statusCode;
      var ok = status == HttpStatus.noContent;
      if (!ok && status == HttpStatus.ok) {
        final bytes = await response.fold<int>(0, (sum, chunk) => sum + chunk.length).timeout(timeout);
        ok = bytes <= 64;
      } else {
        await response.drain<void>().timeout(timeout).catchError((_) {});
      }
      watch.stop();
      return ok ? watch.elapsed : null;
    } on Object {
      return null;
    } finally {
      client.close(force: true);
    }
  }
}
