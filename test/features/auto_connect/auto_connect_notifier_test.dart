import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/auto_connect/data/attempt_log.dart';
import 'package:hiddify/features/auto_connect/data/candidate_profile_binder.dart';
import 'package:hiddify/features/auto_connect/model/auto_connect_state.dart';
import 'package:hiddify/features/auto_connect/notifier/auto_connect_notifier.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/data/connection_repository.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';
import 'package:hiddify/features/profile/model/profile_sort_enum.dart';
import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:hiddify/features/sources/notifier/source_list_notifier.dart';
import 'package:hiddify/singbox/model/singbox_config_option.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../sources/test_signing.dart';

// ---------------------------------------------------------------------------
// Fakes

class FakeConnectionRepository implements ConnectionRepository {
  final BehaviorSubject<ConnectionStatus> status = BehaviorSubject.seeded(const Disconnected());

  /// Profile ids whose start must fail, with the failure to return.
  final Map<String, ConnectionFailure> failOnStart = {};
  final List<String> started = [];
  int disconnects = 0;

  @override
  SingboxConfigOption? get configOptionsSnapshot => null;

  @override
  TaskEither<ConnectionFailure, Unit> setup() => TaskEither.of(unit);

  @override
  Stream<ConnectionStatus> watchConnectionStatus() => status.stream;

  @override
  TaskEither<ConnectionFailure, Unit> connect(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      TaskEither(() async {
        started.add(activeProfile.id);
        final failure = failOnStart[activeProfile.id];
        status.add(const Connecting());
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (failure != null) {
          status.add(Disconnected(failure));
          return Left(failure);
        }
        status.add(const Connected());
        return const Right(unit);
      });

  @override
  TaskEither<ConnectionFailure, Unit> disconnect() => TaskEither(() async {
    disconnects++;
    status.add(const Disconnected());
    return const Right(unit);
  });

  @override
  TaskEither<ConnectionFailure, Unit> reconnect(ProfileEntity activeProfile, bool disableMemoryLimit) =>
      connect(activeProfile, disableMemoryLimit);
}

class FakeProfileRepository implements ProfileRepository {
  final List<ProfileEntity> profiles = [];
  int remoteFetches = 0;
  int localAdds = 0;
  String? activeId;

  @override
  Stream<Either<ProfileFailure, List<ProfileEntity>>> watchAll({
    ProfilesSort sort = ProfilesSort.lastUpdate,
    SortMode sortMode = SortMode.ascending,
  }) => Stream.value(Right(List.of(profiles)));

  @override
  TaskEither<ProfileFailure, ProfileEntity?> getById(String id) =>
      TaskEither.of(profiles.where((p) => p.id == id).firstOrNull);

  @override
  TaskEither<ProfileFailure, Unit> setAsActive(String id) => TaskEither(() async {
    activeId = id;
    return const Right(unit);
  });

  @override
  TaskEither<ProfileFailure, Unit> deleteById(String id, bool isActive) => TaskEither(() async {
    profiles.removeWhere((p) => p.id == id);
    return const Right(unit);
  });

  @override
  TaskEither<ProfileFailure, Unit> upsertRemote(String url, {UserOverride? userOverride, CancelToken? cancelToken}) =>
      TaskEither(() async {
        remoteFetches++;
        profiles.removeWhere((p) => p is RemoteProfileEntity && p.url == url);
        profiles.add(
          ProfileEntity.remote(
            id: 'remote-${profiles.length + 1}',
            active: false,
            name: userOverride?.name ?? url,
            url: url,
            lastUpdate: DateTime.now(),
            userOverride: userOverride,
          ),
        );
        return const Right(unit);
      });

  @override
  TaskEither<ProfileFailure, Unit> addLocal(String content, {UserOverride? userOverride}) => TaskEither(() async {
    localAdds++;
    profiles.add(
      ProfileEntity.local(
        id: 'local-${profiles.length + 1}',
        active: false,
        name: userOverride?.name ?? 'local',
        lastUpdate: DateTime.now(),
        userOverride: userOverride,
      ),
    );
    return const Right(unit);
  });

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

class FakeConnectionNotifier extends ConnectionNotifier {
  @override
  Stream<ConnectionStatus> build() => ref.watch(connectionRepositoryProvider).watchConnectionStatus();
}

class FakeSourceListNotifier extends SourceListNotifier {
  FakeSourceListNotifier(this.fixed);

  final SourceListState fixed;
  int refreshCalls = 0;

  @override
  Future<SourceListState> build() async => fixed;

  @override
  Future<SourceListState> refreshIfDue() async {
    refreshCalls++;
    return fixed;
  }

  @override
  Future<SourceListState> refresh() async => fixed;
}

class FixedRandom implements Random {
  FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => true;

  @override
  int nextInt(int max) => 0;
}

// ---------------------------------------------------------------------------

SourceListState _sources({bool warp = true, List<Map<String, Object?>> workers = const []}) {
  final json = samplePayload(workers: workers);
  (json['warp']! as Map<String, Object?>)['enabled'] = warp;
  return SourceListState(
    list: SourceList.fromJson(json),
    origin: SourceListOrigin.bundled,
    expired: false,
    requiresNewerApp: false,
    lastFetchAt: null,
  );
}

Map<String, Object?> _worker(String id, int weight) => {
  'id': id,
  'name': 'Worker $id',
  'url': 'https://$id.example.workers.dev/sub',
  'weight': weight,
};

void main() {
  late FakeConnectionRepository connection;
  late FakeProfileRepository profiles;
  late FakeSourceListNotifier sources;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    connection = FakeConnectionRepository();
    profiles = FakeProfileRepository();
  });

  Future<ProviderContainer> makeContainer({
    required SourceListState list,
    required Set<String> healthyMarkers,
    double jitter = 0,
  }) async {
    sources = FakeSourceListNotifier(list);
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWith((ref) => SharedPreferences.getInstance()),
        connectionRepositoryProvider.overrideWithValue(connection),
        connectionNotifierProvider.overrideWith(FakeConnectionNotifier.new),
        profileRepositoryProvider.overrideWith((ref) => profiles),
        sourceListProvider.overrideWith(() => sources),
        candidateProfileBinderProvider.overrideWith((ref) => CandidateProfileBinder(profiles)),
        autoConnectRandomProvider.overrideWithValue(FixedRandom((jitter + 1) / 2)),
        // The probe "succeeds" only when the active profile belongs to a healthy candidate.
        healthProbeProvider.overrideWithValue((url, timeout) async {
          final active = profiles.profiles.where((p) => p.id == profiles.activeId).firstOrNull;
          final ok = active != null && healthyMarkers.contains(active.name);
          return ok ? const Duration(milliseconds: 42) : null;
        }),
      ],
    );
    addTearDown(container.dispose);
    await container.read(sharedPreferencesProvider.future);
    container.listen(connectionNotifierProvider, (_, _) {});
    return container;
  }

  group('AutoConnectNotifier', () {
    test('connects with the first healthy candidate and remembers it', () async {
      final container = await makeContainer(
        list: _sources(workers: [_worker('a', 5), _worker('b', 1)]),
        healthyMarkers: {'belderchin:a'},
      );
      final notifier = container.read(autoConnectProvider.notifier);
      final seen = <AutoConnectState>[];
      container.listen(autoConnectProvider, (_, next) => seen.add(next));

      await notifier.connect();

      final state = container.read(autoConnectProvider);
      expect(state, isA<AutoConnectConnected>());
      expect((state as AutoConnectConnected).candidate.id, 'a');
      expect(seen.whereType<AutoConnectPreparing>(), hasLength(1));
      // WARP was tried first (index 1 of 3) and found unhealthy, then "a".
      expect(seen.whereType<AutoConnectTrying>().map((s) => s.candidate.id).toSet(), {'warp', 'a'});
      expect(profiles.localAdds, 1, reason: 'WARP profile created once');
      expect(profiles.remoteFetches, 1, reason: 'only worker a was fetched');
      expect(connection.started, hasLength(2));
      expect(sources.refreshCalls, greaterThanOrEqualTo(1));
      expect(container.read(Preferences.startedByUser), isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(AutoConnectNotifier.lastGoodKey), 'a');

      final log = container.read(attemptLogProvider).records;
      expect(log.map((r) => r.outcome), [AttemptOutcome.unhealthy, AttemptOutcome.success]);
      expect(log.last.latency, const Duration(milliseconds: 42));
    });

    test('tries the remembered route first on the next connect', () async {
      SharedPreferences.setMockInitialValues({AutoConnectNotifier.lastGoodKey: 'b'});
      final container = await makeContainer(
        list: _sources(workers: [_worker('a', 5), _worker('b', 1)]),
        healthyMarkers: {'belderchin:b'},
      );
      await container.read(autoConnectProvider.notifier).connect();
      expect((container.read(autoConnectProvider) as AutoConnectConnected).candidate.id, 'b');
      expect(connection.started, hasLength(1), reason: 'b was tried first and succeeded');
    });

    test('fails after every candidate is unhealthy and leaves the core stopped', () async {
      final container = await makeContainer(list: _sources(workers: [_worker('a', 1)]), healthyMarkers: {});
      await container.read(autoConnectProvider.notifier).connect();
      final state = container.read(autoConnectProvider);
      expect(state, isA<AutoConnectFailed>());
      expect((state as AutoConnectFailed).reason, FailureReason.allFailed);
      expect(state.tried, 2);
      expect(connection.status.value, const Disconnected());
    });

    test('skips a candidate whose core start fails and continues down the chain', () async {
      final container = await makeContainer(
        list: _sources(workers: [_worker('a', 1)]),
        healthyMarkers: {'belderchin:a'},
      );
      connection.failOnStart['local-1'] = const ConnectionFailure.invalidConfig('bad warp');
      await container.read(autoConnectProvider.notifier).connect();
      expect((container.read(autoConnectProvider) as AutoConnectConnected).candidate.id, 'a');
      final log = container.read(attemptLogProvider).records;
      expect(log.first.outcome, AttemptOutcome.startFailed);
      expect(profiles.profiles.where((p) => p.name == 'belderchin:warp'), isEmpty, reason: 'broken profile removed');
    });

    test('stops immediately when the VPN permission is denied', () async {
      final container = await makeContainer(
        list: _sources(workers: [_worker('a', 1), _worker('b', 1)]),
        healthyMarkers: {'belderchin:a'},
      );
      connection.failOnStart['local-1'] = const ConnectionFailure.missingVpnPermission();
      await container.read(autoConnectProvider.notifier).connect();
      final state = container.read(autoConnectProvider) as AutoConnectFailed;
      expect(state.reason, FailureReason.vpnPermissionDenied);
      expect(connection.started, hasLength(1));
    });

    test('reports noCandidates for an empty list', () async {
      final container = await makeContainer(list: _sources(warp: false), healthyMarkers: {});
      await container.read(autoConnectProvider.notifier).connect();
      expect((container.read(autoConnectProvider) as AutoConnectFailed).reason, FailureReason.noCandidates);
      expect(connection.started, isEmpty);
    });

    test('disconnect stops the core and clears startedByUser', () async {
      final container = await makeContainer(list: _sources(), healthyMarkers: {'belderchin:warp'});
      final notifier = container.read(autoConnectProvider.notifier);
      await notifier.connect();
      expect(container.read(autoConnectProvider), isA<AutoConnectConnected>());
      await notifier.disconnect();
      expect(container.read(autoConnectProvider), isA<AutoConnectIdle>());
      expect(connection.status.value, const Disconnected());
      expect(container.read(Preferences.startedByUser), isFalse);
    });

    test('schedules a backoff reconnect when the core stops unexpectedly', () async {
      final container = await makeContainer(list: _sources(), healthyMarkers: {'belderchin:warp'});
      final notifier = container.read(autoConnectProvider.notifier);
      await notifier.connect();
      expect(container.read(autoConnectProvider), isA<AutoConnectConnected>());

      connection.status.add(const Disconnected());
      await Future<void>.delayed(Duration.zero);

      final state = container.read(autoConnectProvider);
      expect(state, isA<AutoConnectReconnecting>());
      expect((state as AutoConnectReconnecting).attempt, 1);
      expect(state.delay, const Duration(seconds: 2));
      expect(state.lastCandidate?.id, 'warp');
    });

    test('adopts a tunnel that was started outside the flow (always-on / boot)', () async {
      SharedPreferences.setMockInitialValues({AutoConnectNotifier.lastGoodKey: 'a'});
      final container = await makeContainer(list: _sources(workers: [_worker('a', 1)]), healthyMarkers: {});
      await container.read(sourceListProvider.future);
      container.listen(autoConnectProvider, (_, _) {});
      expect(container.read(autoConnectProvider), isA<AutoConnectIdle>());

      connection.status.add(const Connected());
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final state = container.read(autoConnectProvider);
      expect(state, isA<AutoConnectConnected>());
      expect((state as AutoConnectConnected).candidate.id, 'a');
      expect(connection.started, isEmpty);
    });

    test('does not reconnect after a user-initiated disconnect', () async {
      final container = await makeContainer(list: _sources(), healthyMarkers: {'belderchin:warp'});
      final notifier = container.read(autoConnectProvider.notifier);
      await notifier.connect();
      await notifier.disconnect();
      connection.status.add(const Disconnected());
      await Future<void>.delayed(Duration.zero);
      expect(container.read(autoConnectProvider), isA<AutoConnectIdle>());
    });
  });
}
