import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/sources/model/source_list.dart';

import 'test_signing.dart';

void main() {
  group('SourceList.fromJson', () {
    test('parses a full document', () {
      final list = SourceList.fromJson(
        samplePayload(
          version: 7,
          minAppVersion: '1.2.3',
          mirrors: ['https://example.org/sources.signed.json'],
          workers: [
            {'id': 'w1', 'name': 'Worker one', 'url': 'https://w1.example.workers.dev/sub', 'weight': 10},
          ],
          backup: [
            {'id': 'b1', 'name': 'Inline', 'content': 'vless://uuid@host:443?security=tls#x'},
          ],
        ),
      );
      expect(list.version, 7);
      expect(list.issuedAt, DateTime.utc(2026, 9));
      expect(list.expiresAt, DateTime.utc(2027, 3));
      expect(list.minAppVersion, const AppVersion(1, 2, 3));
      expect(list.mirrors.single.host, 'example.org');
      expect(list.healthCheck!.urls, hasLength(2));
      expect(list.healthCheck!.minSuccess, 1);
      expect(list.healthCheck!.timeout, const Duration(seconds: 5));
      expect(list.warp.enabled, isTrue);
      expect(list.warp.endpoints, contains('2606:4700:d0::/48'));
      expect(list.warp.ports, [2408, 500]);
      expect(list.workers.single.isRemote, isTrue);
      expect(list.workers.single.layer, 'workers');
      expect(list.backup.single.isRemote, isFalse);
      expect(list.orderedEntries.map((e) => e.id), ['w1', 'b1']);
      expect(list.isExpiredAt(DateTime.utc(2027, 2)), isFalse);
      expect(list.isExpiredAt(DateTime.utc(2027, 3)), isTrue);
    });

    test('round-trips through toJson', () {
      final original = SourceList.fromJson(
        samplePayload(
          workers: [
            {'id': 'w1', 'name': 'Worker one', 'url': 'https://w1.example.workers.dev/sub', 'weight': 3},
          ],
        ),
      );
      final copy = SourceList.fromJson(original.toJson());
      expect(copy.toJson(), original.toJson());
      expect(copy.workers, original.workers);
    });

    test('defaults are applied for optional sections', () {
      final list = SourceList.fromJson(const {
        'version': 1,
        'issued_at': '2026-09-01T00:00:00Z',
        'expires_at': '2026-10-01T00:00:00Z',
      });
      expect(list.warp.enabled, isFalse);
      expect(list.workers, isEmpty);
      expect(list.backup, isEmpty);
      expect(list.mirrors, isEmpty);
      expect(list.healthCheck, isNull);
      expect(list.minAppVersion, isNull);
    });

    void expectRejected(Map<String, Object?> json, String reason) {
      expect(
        () => SourceList.fromJson(json),
        throwsA(isA<SourceListFormatException>().having((e) => e.message, 'message', contains(reason))),
      );
    }

    test('rejects structural problems', () {
      expectRejected(samplePayload()..remove('version'), 'version');
      expectRejected(samplePayload()..['version'] = '3', 'version');
      expectRejected(samplePayload(version: 0), 'version');
      expectRejected(samplePayload(issuedAt: '2026-09-01 00:00:00'), 'issued_at');
      expectRejected(samplePayload(issuedAt: '2026-09-01T00:00:00+03:30'), 'issued_at');
      expectRejected(samplePayload(expiresAt: '2026-08-01T00:00:00Z'), 'expires_at must be after');
      expectRejected(samplePayload(minAppVersion: 'latest'), 'min_app_version');
      expectRejected(samplePayload(mirrors: ['http://insecure.example.org/x']), 'https');
      expectRejected(samplePayload()..['workers'] = 'nope', 'workers must be a list');
      expectRejected(samplePayload()..['notes'] = 5, 'notes');
    });

    test('rejects bad source entries', () {
      expectRejected(
        samplePayload(
          workers: [
            {'id': 'w1', 'name': 'a'},
          ],
        ),
        'needs url or content',
      );
      expectRejected(
        samplePayload(
          workers: [
            {'id': 'w1', 'name': 'a', 'url': 'http://plain.example.org/sub'},
          ],
        ),
        'https',
      );
      expectRejected(
        samplePayload(
          workers: [
            {'id': 'dup', 'name': 'a', 'url': 'https://a.example.org/sub'},
          ],
          backup: [
            {'id': 'dup', 'name': 'b', 'url': 'https://b.example.org/sub'},
          ],
        ),
        'duplicate source id',
      );
      expectRejected(
        samplePayload(
          workers: [
            {'id': 'w1', 'name': 'a', 'url': 'https://a.example.org/sub', 'weight': -1},
          ],
        ),
        'weight',
      );
      expectRejected(
        samplePayload(
          backup: [
            {'id': 'b1', 'name': 'a', 'content': '   '},
          ],
        ),
        'content',
      );
    });

    test('rejects bad warp and health check sections', () {
      final badCidr = samplePayload();
      (badCidr['warp']! as Map<String, Object?>)['endpoints'] = ['162.159.192.0/33'];
      expectRejected(badCidr, 'CIDR');

      final badCidr6 = samplePayload();
      (badCidr6['warp']! as Map<String, Object?>)['endpoints'] = ['2606:4700:zz::/48'];
      expectRejected(badCidr6, 'CIDR');

      final badPort = samplePayload();
      (badPort['warp']! as Map<String, Object?>)['ports'] = [70000];
      expectRejected(badPort, 'port');

      final badMinSuccess = samplePayload();
      (badMinSuccess['health_check']! as Map<String, Object?>)['min_success'] = 3;
      expectRejected(badMinSuccess, 'min_success');

      final emptyUrls = samplePayload();
      (emptyUrls['health_check']! as Map<String, Object?>)['urls'] = <String>[];
      expectRejected(emptyUrls, 'urls');

      final badTimeout = samplePayload();
      (badTimeout['health_check']! as Map<String, Object?>)['timeout_ms'] = 10;
      expectRejected(badTimeout, 'timeout_ms');
    });
  });

  group('AppVersion', () {
    test('parses and compares', () {
      expect(AppVersion.tryParse('1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('1.2.3+45'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('1.2.3-beta.1'), const AppVersion(1, 2, 3));
      expect(AppVersion.tryParse('1.2'), isNull);
      expect(AppVersion.tryParse('v1.2.3'), isNull);
      expect(const AppVersion(1, 0, 0) < const AppVersion(1, 0, 1), isTrue);
      expect(const AppVersion(1, 10, 0) >= const AppVersion(1, 9, 9), isTrue);
      expect(const AppVersion(2, 0, 0) >= const AppVersion(1, 99, 99), isTrue);
      expect(const AppVersion(1, 2, 3).toString(), '1.2.3');
    });
  });
}
