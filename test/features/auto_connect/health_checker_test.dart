import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/auto_connect/data/health_checker.dart';
import 'package:hiddify/features/sources/model/source_list.dart';

HealthCheckConfig _config(int urls, int minSuccess) => HealthCheckConfig(
  urls: [for (var i = 0; i < urls; i++) Uri.parse('http://probe$i.test/generate_204')],
  minSuccess: minSuccess,
  timeout: const Duration(seconds: 1),
);

void main() {
  group('HealthChecker', () {
    test('is healthy when at least N of M probes succeed', () async {
      final checker = HealthChecker(
        mixedPort: 12334,
        probe: (url, _) async => url.host == 'probe1.test' ? null : const Duration(milliseconds: 120),
      );
      final result = await checker.check(_config(3, 2));
      expect(result.healthy, isTrue);
      expect(result.succeeded, 2);
      expect(result.total, 3);
      expect(result.latency, const Duration(milliseconds: 120));
    });

    test('is unhealthy when fewer than N probes succeed', () async {
      final checker = HealthChecker(
        mixedPort: 12334,
        probe: (url, _) async => url.host == 'probe0.test' ? const Duration(milliseconds: 50) : null,
      );
      final result = await checker.check(_config(3, 2));
      expect(result.healthy, isFalse);
      expect(result.succeeded, 1);
    });

    test('clamps min_success into [1, urls.length]', () async {
      final checker = HealthChecker(mixedPort: 1, probe: (_, _) async => const Duration(milliseconds: 1));
      expect((await checker.check(_config(2, 10))).required, 2);
      expect((await checker.check(_config(2, 0))).required, 1);
    });

    test('reports the best latency among successes', () async {
      var call = 0;
      final checker = HealthChecker(
        mixedPort: 1,
        probe: (_, _) async => Duration(milliseconds: [300, 90, 200][call++ % 3]),
      );
      final result = await checker.check(_config(3, 1));
      expect(result.latency, const Duration(milliseconds: 90));
    });

    test('never healthy without urls', () async {
      final checker = HealthChecker(mixedPort: 1, probe: (_, _) async => Duration.zero);
      final result = await checker.check(const HealthCheckConfig(urls: [], minSuccess: 1, timeout: Duration(seconds: 1)));
      expect(result.healthy, isFalse);
    });

    test('a probe that throws surfaces the error to the caller', () {
      final checker = HealthChecker(
        mixedPort: 1,
        probe: (url, _) {
          if (url.host == 'probe0.test') throw StateError('boom');
          return Future.value(const Duration(milliseconds: 10));
        },
      );
      expect(() => checker.check(_config(2, 2)), throwsStateError);
    });
  });
}
