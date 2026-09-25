import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/sources/data/source_list_fetcher.dart';
import 'package:hiddify/features/sources/data/source_list_validator.dart';

import 'test_signing.dart';

void main() {
  late TestSigner signer;
  late SourceListValidator validator;
  final now = DateTime.utc(2026, 9, 24, 12);

  final m1 = Uri.parse('https://mirror-one.example.org/sources.signed.json');
  final m2 = Uri.parse('https://mirror-two.example.org/sources.signed.json');
  final m3 = Uri.parse('https://mirror-three.example.org/sources.signed.json');
  final m4 = Uri.parse('https://mirror-four.example.org/sources.signed.json');

  setUpAll(() async {
    signer = await TestSigner.create();
    validator = SourceListValidator(trustedKeys: [signer.trustedKey]);
  });

  SourceListFetcher fetcher(Map<Uri, FutureOr<String> Function()> responses, {Duration? mirrorTimeout}) {
    return SourceListFetcher(
      httpGet: (url, {required timeout}) async {
        final handler = responses[url];
        if (handler == null) throw Exception('unexpected url $url');
        return handler();
      },
      validator: validator,
      mirrorTimeout: mirrorTimeout ?? const Duration(seconds: 2),
      overallTimeout: const Duration(seconds: 5),
    );
  }

  test('keeps the newest authentic list among all mirrors', () async {
    final v3 = await signer.sign(samplePayload(version: 3));
    final v5 = await signer.sign(samplePayload(version: 5));
    final result = await fetcher({
      m1: () => v3,
      m2: () => throw Exception('connection refused'),
      m3: () => v5,
    }).fetch(mirrors: [m1, m2, m3], now: now);

    expect(result.succeeded, isTrue);
    expect(result.best!.list.version, 5);
    expect(result.attempts, hasLength(3));
    expect(result.attempts.where((a) => a.succeeded).map((a) => a.version), containsAll([3, 5]));
    final failed = result.attempts.singleWhere((a) => !a.succeeded);
    expect(failed.url, m2);
    expect(failed.error, contains('connection refused'));
  });

  test('ignores tampered and rolled-back responses', () async {
    final good = await signer.sign(samplePayload(version: 4));
    final tampered = good.replaceFirst('"signature":"', '"signature":"AAAA');
    final old = await signer.sign(samplePayload(version: 2));
    final result = await fetcher({m1: () => tampered, m2: () => old, m3: () => good}).fetch(
      mirrors: [m1, m2, m3],
      now: now,
      previousVersion: 3,
    );
    expect(result.best!.list.version, 4);
    final errors = result.attempts.where((a) => !a.succeeded).map((a) => a.error!).toList();
    expect(errors, hasLength(2));
    expect(errors.join(' '), contains('rollback'));
  });

  test('reports total failure without throwing', () async {
    final result = await fetcher({
      m1: () => throw Exception('dns failure'),
      m2: () => 'garbage',
    }).fetch(mirrors: [m1, m2], now: now);
    expect(result.succeeded, isFalse);
    expect(result.best, isNull);
    expect(result.attempts.map((a) => a.succeeded), everyElement(isFalse));
  });

  test('applies the per-mirror timeout', () async {
    final good = await signer.sign(samplePayload());
    final result = await fetcher({
      m1: () => Future<String>.delayed(const Duration(seconds: 3), () => good),
      m2: () => good,
    }, mirrorTimeout: const Duration(milliseconds: 100)).fetch(mirrors: [m1, m2], now: now);
    expect(result.best!.list.version, 1);
    final slow = result.attempts.singleWhere((a) => a.url == m1);
    expect(slow.succeeded, isFalse);
    expect(slow.error, 'timeout');
  });

  test('deduplicates mirrors, drops non-https ones and bounds the count', () async {
    final good = await signer.sign(samplePayload());
    var calls = 0;
    final result = await fetcher({
      m1: () {
        calls++;
        return good;
      },
      m2: () {
        calls++;
        return good;
      },
      m3: () {
        calls++;
        return good;
      },
      m4: () {
        calls++;
        return good;
      },
    }).fetch(mirrors: [m1, m1, Uri.parse('http://plain.example.org/x'), m2, m3, m4, m1], now: now);
    expect(calls, 4);
    expect(result.attempts, hasLength(4));
  });

  test('returns an empty result when no usable mirror is configured', () async {
    final result = await fetcher({}).fetch(mirrors: [Uri.parse('http://plain.example.org/x')], now: now);
    expect(result.succeeded, isFalse);
    expect(result.attempts, isEmpty);
  });
}
