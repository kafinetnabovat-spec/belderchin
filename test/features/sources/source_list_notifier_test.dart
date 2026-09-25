import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/sources/data/source_list_constants.dart';
import 'package:hiddify/features/sources/data/source_list_fetcher.dart';
import 'package:hiddify/features/sources/data/source_list_store.dart';
import 'package:hiddify/features/sources/data/source_list_validator.dart';
import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:hiddify/features/sources/notifier/source_list_notifier.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_signing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestSigner signer;
  late SourceListValidator validator;
  late Directory tempDir;
  late SourceListStore store;
  var now = DateTime.utc(2026, 9, 24, 12);

  setUpAll(() async {
    signer = await TestSigner.create();
    validator = SourceListValidator(trustedKeys: [signer.trustedKey]);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = await Directory.systemTemp.createTemp('belderchin_sources_test');
    store = SourceListStore(directory: tempDir, preferences: await SharedPreferences.getInstance());
    now = DateTime.utc(2026, 9, 24, 12);
  });

  tearDown(() async {
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
  });

  ProviderContainer makeContainer({
    required String bundled,
    Map<Uri, String Function()> responses = const {},
  }) {
    final container = ProviderContainer(
      overrides: [
        sourceListStoreProvider.overrideWith((ref) => store),
        sourceListValidatorProvider.overrideWithValue(validator),
        sourceListAppVersionProvider.overrideWithValue(const AppVersion(1, 0, 0)),
        sourceListClockProvider.overrideWithValue(() => now),
        bundledSourceListLoaderProvider.overrideWithValue(() async => bundled),
        sourceListFetcherProvider.overrideWithValue(
          SourceListFetcher(
            httpGet: (url, {required timeout}) async {
              final handler = responses[url];
              if (handler == null) throw Exception('unreachable');
              return handler();
            },
            validator: validator,
            mirrorTimeout: const Duration(seconds: 1),
            overallTimeout: const Duration(seconds: 2),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  final mirror1 = SourceListConstants.builtInMirrors.first;

  test('starts from the bundled list when no cache exists (no network)', () async {
    final bundled = await signer.sign(samplePayload(version: 2));
    final container = makeContainer(bundled: bundled);

    final state = await container.read(sourceListProvider.future);
    expect(state.list.version, 2);
    expect(state.origin, SourceListOrigin.bundled);
    expect(state.expired, isFalse);
    expect(state.lastFetchAt, isNull);
    expect(store.lastAcceptedVersion, 2);
  });

  test('prefers a newer authentic cached list over the bundled one', () async {
    final bundled = await signer.sign(samplePayload(version: 2));
    await store.writeCachedEnvelope(await signer.sign(samplePayload(version: 6)));
    await store.setLastAcceptedVersion(6);

    final state = await makeContainer(bundled: bundled).read(sourceListProvider.future);
    expect(state.list.version, 6);
    expect(state.origin, SourceListOrigin.cached);
  });

  test('uses the bundled list when it is newer than the cache (app update)', () async {
    final bundled = await signer.sign(samplePayload(version: 9));
    await store.writeCachedEnvelope(await signer.sign(samplePayload(version: 6)));
    await store.setLastAcceptedVersion(6);

    final state = await makeContainer(bundled: bundled).read(sourceListProvider.future);
    expect(state.list.version, 9);
    expect(state.origin, SourceListOrigin.bundled);
    expect(store.lastAcceptedVersion, 9);
  });

  test('discards a tampered cache and falls back to the bundled list', () async {
    final bundled = await signer.sign(samplePayload(version: 2));
    final cached = await signer.sign(samplePayload(version: 6));
    await store.writeCachedEnvelope(cached.replaceFirst('"payload":"', '"payload":"eyJ'));

    final state = await makeContainer(bundled: bundled).read(sourceListProvider.future);
    expect(state.list.version, 2);
    expect(state.origin, SourceListOrigin.bundled);
    expect(store.file.existsSync(), isFalse);
  });

  test('discards a rolled-back cache below the accepted floor', () async {
    final bundled = await signer.sign(samplePayload(version: 2));
    await store.writeCachedEnvelope(await signer.sign(samplePayload(version: 3)));
    await store.setLastAcceptedVersion(8);

    final state = await makeContainer(bundled: bundled).read(sourceListProvider.future);
    expect(state.list.version, 2);
    expect(state.origin, SourceListOrigin.bundled);
  });

  test('refresh adopts and persists a newer list from a mirror', () async {
    final bundled = await signer.sign(samplePayload(version: 2));
    final remote = await signer.sign(samplePayload(version: 5));
    final container = makeContainer(bundled: bundled, responses: {mirror1: () => remote});

    await container.read(sourceListProvider.future);
    final state = await container.read(sourceListProvider.notifier).refresh();

    expect(state.list.version, 5);
    expect(state.origin, SourceListOrigin.remote);
    expect(state.refreshStatus, SourceListRefreshStatus.succeeded);
    expect(state.lastFetchAt, now);
    expect(store.lastAcceptedVersion, 5);
    expect(await store.readCachedEnvelope(), isNotNull);
    expect(state.lastAttempts.where((a) => a.succeeded).single.url, mirror1);
  });

  test('refresh keeps the current list when every mirror fails', () async {
    final bundled = await signer.sign(samplePayload(version: 2));
    final container = makeContainer(bundled: bundled);

    await container.read(sourceListProvider.future);
    final state = await container.read(sourceListProvider.notifier).refresh();

    expect(state.list.version, 2);
    expect(state.origin, SourceListOrigin.bundled);
    expect(state.refreshStatus, SourceListRefreshStatus.failed);
    expect(state.lastFetchAt, isNull);
    expect(state.lastAttempts, isNotEmpty);
    expect(state.lastAttempts.map((a) => a.succeeded), everyElement(isFalse));
  });

  test('refresh never downgrades, even if a mirror serves an older signed list', () async {
    final bundled = await signer.sign(samplePayload(version: 7));
    final stale = await signer.sign(samplePayload(version: 3));
    final container = makeContainer(bundled: bundled, responses: {mirror1: () => stale});

    await container.read(sourceListProvider.future);
    final state = await container.read(sourceListProvider.notifier).refresh();

    expect(state.list.version, 7);
    expect(state.refreshStatus, SourceListRefreshStatus.failed);
    expect(state.lastAttempts.singleWhere((a) => a.url == mirror1).error, contains('rollback'));
  });

  test('refreshIfDue respects the refresh interval and forces on expiry', () async {
    final bundled = await signer.sign(samplePayload(version: 2));
    var served = 0;
    final container = makeContainer(
      bundled: bundled,
      responses: {
        mirror1: () {
          served++;
          throw Exception('offline');
        },
      },
    );
    final notifier = container.read(sourceListProvider.notifier);
    await container.read(sourceListProvider.future);

    await notifier.refreshIfDue();
    expect(served, 1, reason: 'never fetched before → due');

    await store.setLastFetchAt(now);
    container.invalidate(sourceListProvider);
    await container.read(sourceListProvider.future);
    await container.read(sourceListProvider.notifier).refreshIfDue();
    expect(served, 1, reason: 'fetched moments ago → not due');

    now = now.add(SourceListConstants.refreshInterval + const Duration(minutes: 1));
    await container.read(sourceListProvider.notifier).refreshIfDue();
    expect(served, 2, reason: 'interval elapsed → due');
  });

  test('an expired active list is flagged and refreshIfDue always fetches', () async {
    final bundled = await signer.sign(samplePayload(issuedAt: '2026-01-01T00:00:00Z', expiresAt: '2026-02-01T00:00:00Z'));
    var served = 0;
    final container = makeContainer(
      bundled: bundled,
      responses: {
        mirror1: () {
          served++;
          throw Exception('offline');
        },
      },
    );
    final state = await container.read(sourceListProvider.future);
    expect(state.expired, isTrue);
    await store.setLastFetchAt(now);
    await container.read(sourceListProvider.notifier).refreshIfDue();
    expect(served, 1);
  });

  test('concurrent refresh calls share one network round', () async {
    final bundled = await signer.sign(samplePayload());
    var served = 0;
    final remote = await signer.sign(samplePayload(version: 2));
    final container = makeContainer(
      bundled: bundled,
      responses: {
        mirror1: () {
          served++;
          return remote;
        },
      },
    );
    await container.read(sourceListProvider.future);
    final notifier = container.read(sourceListProvider.notifier);
    final results = await Future.wait([notifier.refresh(), notifier.refresh(), notifier.refresh()]);
    expect(served, 1);
    expect(results.map((s) => s.list.version), everyElement(2));
  });

  test('mirrorsFor merges built-in, advertised and custom mirrors', () {
    final list = SourceList.fromJson(
      samplePayload(mirrors: ['https://advertised.example.org/s.json', SourceListConstants.builtInMirrors.first.toString()]),
    );
    final mirrors = SourceListNotifier.mirrorsFor(list, customMirror: Uri.parse('https://custom.example.org/s.json'));
    expect(mirrors.take(SourceListConstants.builtInMirrors.length), SourceListConstants.builtInMirrors);
    expect(mirrors.map((m) => m.host), contains('advertised.example.org'));
    expect(mirrors.last.host, 'custom.example.org');
    expect(mirrors.toSet(), hasLength(mirrors.length));
    expect(mirrors.length, lessThanOrEqualTo(SourceListConstants.maxMirrors));
  });

  test('store validates the custom mirror', () async {
    expect(await store.setCustomMirror('http://plain.example.org/x'), isFalse);
    expect(await store.setCustomMirror('not a url'), isFalse);
    expect(await store.setCustomMirror('https://ok.example.org/sources.signed.json'), isTrue);
    expect(store.customMirror!.host, 'ok.example.org');
    expect(await store.setCustomMirror(''), isTrue);
    expect(store.customMirror, isNull);
  });
}
