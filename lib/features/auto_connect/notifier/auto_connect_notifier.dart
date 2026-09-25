import 'dart:async';
import 'dart:math';

import 'package:hiddify/core/preferences/general_preferences.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/auto_connect/data/attempt_log.dart';
import 'package:hiddify/features/auto_connect/data/candidate_profile_binder.dart';
import 'package:hiddify/features/auto_connect/data/health_checker.dart';
import 'package:hiddify/features/auto_connect/model/auto_connect_state.dart';
import 'package:hiddify/features/auto_connect/model/connection_candidate.dart';
import 'package:hiddify/features/connection/data/connection_data_providers.dart';
import 'package:hiddify/features/connection/model/connection_failure.dart';
import 'package:hiddify/features/connection/model/connection_status.dart';
import 'package:hiddify/features/connection/notifier/connection_notifier.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:hiddify/features/sources/notifier/source_list_notifier.dart';
import 'package:hiddify/features/warp/notifier/warp_layer.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Health probes used when the signed list does not define its own.
final HealthCheckConfig defaultHealthCheck = HealthCheckConfig(
  urls: [
    Uri.parse('http://cp.cloudflare.com/generate_204'),
    Uri.parse('http://connectivitycheck.gstatic.com/generate_204'),
    Uri.parse('http://detectportal.firefox.com/success.txt'),
  ],
  minSuccess: 2,
  timeout: const Duration(seconds: 6),
);

/// Recent attempts, in memory only. Kept alive so the troubleshooting page can
/// show what happened after a failed chain.
final attemptLogProvider = Provider<AttemptLog>((ref) => AttemptLog());

/// Probe implementation; `null` means real HTTP through the local mixed proxy.
/// Overridden in tests.
final healthProbeProvider = Provider<Probe?>((ref) => null);

final candidateProfileBinderProvider = FutureProvider<CandidateProfileBinder>(
  (ref) async => CandidateProfileBinder(await ref.watch(profileRepositoryProvider.future)),
);

/// Random source for reconnect jitter; overridden in tests for determinism.
final autoConnectRandomProvider = Provider<Random>((ref) => Random());

final autoConnectProvider = NotifierProvider<AutoConnectNotifier, AutoConnectState>(AutoConnectNotifier.new);

/// The one-button flow: refresh the signed list (bounded), then walk the
/// candidate chain WARP → Workers → backup, starting the core for each and
/// accepting the first one whose in-tunnel health check passes.
///
/// It also acts as a watchdog: if the core stops while the user expects to be
/// connected, it retries with exponential backoff and jitter (bounded).
class AutoConnectNotifier extends Notifier<AutoConnectState> with AppLogger {
  static const String lastGoodKey = 'auto_connect.last_good';
  static const Duration refreshBudget = Duration(seconds: 6);
  static const Duration startTimeout = Duration(seconds: 25);
  static const Duration stopTimeout = Duration(seconds: 10);
  static const int maxCandidates = 12;
  static const int maxReconnectAttempts = 6;

  int _session = 0;
  Timer? _reconnectTimer;
  int _reconnectAttempt = 0;
  bool _expectConnected = false;
  @override
  AutoConnectState build() {
    ref.listen<AsyncValue<ConnectionStatus>>(connectionNotifierProvider, _onCoreStatus);
    ref.onDispose(() => _reconnectTimer?.cancel());
    return const AutoConnectIdle();
  }

  // ---------------------------------------------------------------------------
  // Public API

  Future<void> connect() async {
    if (state.isBusy) return;
    _reconnectTimer?.cancel();
    _reconnectAttempt = 0;
    _expectConnected = true;
    await ref.read(Preferences.startedByUser.notifier).update(true);
    await _runChain(++_session);
  }

  Future<void> disconnect() async {
    _expectConnected = false;
    _reconnectTimer?.cancel();
    final session = ++_session;
    await ref.read(Preferences.startedByUser.notifier).update(false);
    state = const AutoConnectDisconnecting();
    await _stopCore();
    if (session == _session) state = const AutoConnectIdle();
  }

  /// Cancels a running chain (button tapped while trying).
  Future<void> cancel() async {
    if (state is! AutoConnectTrying && state is! AutoConnectPreparing) return;
    await disconnect();
    state = const AutoConnectFailed(reason: FailureReason.cancelled);
  }

  Future<void> toggle() async {
    switch (state) {
      case AutoConnectIdle() || AutoConnectFailed():
        await connect();
      case AutoConnectConnected() || AutoConnectReconnecting():
        await disconnect();
      case AutoConnectPreparing() || AutoConnectTrying():
        await cancel();
      case AutoConnectDisconnecting():
        break;
    }
  }

  /// Forgets the sticky "last good route" so the next connect starts from the
  /// top of the list again.
  Future<void> forgetPreferred() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    await prefs.remove(lastGoodKey);
  }

  // ---------------------------------------------------------------------------
  // Chain

  Future<void> _runChain(int session) async {
    state = const AutoConnectPreparing();
    final log = ref.read(attemptLogProvider);

    // 1. Signed route list (bounded refresh; offline copy is always available).
    final sources = ref.read(sourceListProvider.notifier);
    var listState = await sources.refreshIfDue().timeout(refreshBudget, onTimeout: () => ref.read(sourceListProvider.future));
    if (session != _session) return;
    listState = ref.read(sourceListProvider).valueOrNull ?? listState;

    // 2. Make sure nothing is running: the WARP scan and the health probes
    //    must see the real network, not a previous tunnel.
    await _stopCore();
    if (session != _session) return;

    final prefs = await ref.read(sharedPreferencesProvider.future);
    final preferred = prefs.getString(lastGoodKey);
    List<ConnectionCandidate>? warpCandidates;
    if (listState.list.warp.enabled) {
      warpCandidates = await ref.read(warpLayerProvider).candidates(listState.list.warp);
      if (session != _session) return;
    }
    var candidates = ConnectionCandidate.fromSourceList(
      listState.list,
      preferredId: preferred,
      warpCandidates: warpCandidates,
    );
    if (candidates.length > maxCandidates) candidates = candidates.sublist(0, maxCandidates);
    if (candidates.isEmpty) {
      state = const AutoConnectFailed(reason: FailureReason.noCandidates);
      return;
    }

    final health = listState.list.healthCheck ?? defaultHealthCheck;
    final binder = await ref.read(candidateProfileBinderProvider.future);
    final checker = HealthChecker(mixedPort: ref.read(ConfigOptions.mixedPort), probe: ref.read(healthProbeProvider));

    var tried = 0;
    var scannedWarpFailures = 0;
    final scannedWarpTotal = candidates.where((c) => c.kind == CandidateKind.warpScanned).length;
    for (var i = 0; i < candidates.length; i++) {
      final candidate = candidates[i];
      if (session != _session) return;
      if (i > 0 && candidates[i - 1].kind == CandidateKind.warpScanned) {
        // Reaching this point means the previous scanned endpoint failed.
        scannedWarpFailures++;
        if (scannedWarpFailures == scannedWarpTotal) unawaited(ref.read(warpLayerProvider).invalidateEndpoints());
      }
      tried++;
      state = AutoConnectTrying(candidate: candidate, index: i + 1, total: candidates.length, stage: TryStage.binding);
      final startedAt = DateTime.now();

      // 2a. Candidate → profile (cached when fresh).
      final bound = await binder.bind(candidate);
      if (session != _session) return;
      if (bound.isLeft()) {
        loggy.warning('bind failed for ${candidate.id}: ${bound.getLeft().toNullable()}');
        log.add(_record(candidate, startedAt, AttemptOutcome.bindFailed, detail: _describe(bound.getLeft().toNullable())));
        continue;
      }
      final profileId = bound.getRight().toNullable()!;

      // 2b. Start the core with that profile.
      state = (state as AutoConnectTrying).withStage(TryStage.starting);
      final startFailure = await _startCore(profileId, session);
      if (session != _session) return;
      if (startFailure != null) {
        if (startFailure is MissingVpnPermission) {
          log.add(_record(candidate, startedAt, AttemptOutcome.startFailed, detail: 'vpn permission denied'));
          _expectConnected = false;
          state = AutoConnectFailed(reason: FailureReason.vpnPermissionDenied, tried: tried);
          return;
        }
        loggy.warning('start failed for ${candidate.id}: $startFailure');
        log.add(_record(candidate, startedAt, AttemptOutcome.startFailed, detail: _describe(startFailure)));
        await _stopCore();
        if (startFailure is InvalidConfig) await binder.unbind(candidate);
        continue;
      }
      final connected = await _waitFor((s) => s is Connected || s is Disconnected, startTimeout);
      if (session != _session) return;
      if (connected is! Connected) {
        log.add(_record(candidate, startedAt, AttemptOutcome.startTimeout));
        await _stopCore();
        continue;
      }

      // 2c. Real traffic through the tunnel.
      state = (state as AutoConnectTrying).withStage(TryStage.checking);
      final result = await checker.check(health);
      if (session != _session) return;
      if (!result.healthy) {
        loggy.info('health check failed for ${candidate.id}: $result');
        log.add(_record(candidate, startedAt, AttemptOutcome.unhealthy, detail: '${result.succeeded}/${result.total} probes'));
        await _stopCore();
        continue;
      }

      log.add(_record(candidate, startedAt, AttemptOutcome.success, latency: result.latency));
      await prefs.setString(lastGoodKey, candidate.id);
      _reconnectAttempt = 0;
      state = AutoConnectConnected(candidate: candidate, since: DateTime.now());
      // A second, in-tunnel chance for mirrors that were blocked before connecting.
      unawaited(sources.refreshIfDue());
      return;
    }

    _expectConnected = false;
    await _stopCore();
    if (session == _session) state = AutoConnectFailed(reason: FailureReason.allFailed, tried: tried);
  }

  Future<ConnectionFailure?> _startCore(String profileId, int session) async {
    final profiles = await ref.read(profileRepositoryProvider.future);
    final activated = await profiles.setAsActive(profileId).run();
    if (activated.isLeft()) return const ConnectionFailure.invalidConfig('cannot activate profile');
    final profile = (await profiles.getById(profileId).run()).getOrElse((_) => null);
    if (profile == null) return const ConnectionFailure.invalidConfig('profile vanished');
    if (session != _session) return const ConnectionFailure.unexpected('cancelled');
    final result = await ref
        .read(connectionRepositoryProvider)
        .connect(profile, ref.read(Preferences.disableMemoryLimit))
        .run();
    return result.fold((failure) => failure, (_) => null);
  }

  Future<void> _stopCore() async {
    final current = await _currentStatus();
    if (current is Disconnected) return;
    await ref.read(connectionRepositoryProvider).disconnect().run();
    await _waitFor((s) => s is Disconnected, stopTimeout);
  }

  Future<ConnectionStatus?> _currentStatus() async {
    final value = ref.read(connectionNotifierProvider).valueOrNull;
    if (value != null) return value;
    return _waitFor((_) => true, const Duration(seconds: 2));
  }

  Future<ConnectionStatus?> _waitFor(bool Function(ConnectionStatus) test, Duration timeout) async {
    try {
      return await ref
          .read(connectionRepositoryProvider)
          .watchConnectionStatus()
          .firstWhere(test)
          .timeout(timeout);
    } on TimeoutException {
      return null;
    } on Object catch (e) {
      loggy.warning('status stream error', e);
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Watchdog (Phase 6)

  void _onCoreStatus(AsyncValue<ConnectionStatus>? previous, AsyncValue<ConnectionStatus> next) {
    final status = next.valueOrNull;
    if (status is Connected && (state is AutoConnectIdle || state is AutoConnectFailed)) {
      // The tunnel was started outside this flow (always-on VPN, boot receiver,
      // app process restarted while the service kept running): adopt it so the
      // button reflects reality and offers "disconnect".
      unawaited(_adoptExternalConnection());
      return;
    }
    if (status is! Disconnected) return;
    if (!_expectConnected) return;
    if (state is! AutoConnectConnected) return;
    if (!ref.read(Preferences.startedByUser)) return;
    _scheduleReconnect((state as AutoConnectConnected).candidate);
  }

  Future<void> _adoptExternalConnection() async {
    final prefs = await ref.read(sharedPreferencesProvider.future);
    final lastGood = prefs.getString(lastGoodKey);
    final list = ref.read(sourceListProvider).valueOrNull?.list;
    ConnectionCandidate? candidate;
    if (list != null && lastGood != null) {
      candidate = ConnectionCandidate.fromSourceList(list).where((c) => c.id == lastGood).firstOrNull;
    }
    if (state is! AutoConnectIdle && state is! AutoConnectFailed) return;
    _expectConnected = true;
    state = AutoConnectConnected(
      candidate: candidate ?? ConnectionCandidate.warpBuiltIn,
      since: DateTime.now(),
    );
  }

  void _scheduleReconnect(ConnectionCandidate lastCandidate) {
    _reconnectTimer?.cancel();
    _reconnectAttempt++;
    if (_reconnectAttempt > maxReconnectAttempts) {
      loggy.warning('giving up after $maxReconnectAttempts reconnect attempts');
      _expectConnected = false;
      state = const AutoConnectFailed(reason: FailureReason.allFailed);
      return;
    }
    final jitter = ref.read(autoConnectRandomProvider).nextDouble() * 2 - 1;
    final delay = reconnectDelay(_reconnectAttempt, jitter: jitter);
    loggy.info('core stopped unexpectedly; reconnect #$_reconnectAttempt in ${delay.inMilliseconds} ms');
    state = AutoConnectReconnecting(attempt: _reconnectAttempt, delay: delay, lastCandidate: lastCandidate);
    final session = ++_session;
    _reconnectTimer = Timer(delay, () {
      if (session != _session || !_expectConnected) return;
      unawaited(_runChain(session));
    });
  }

  // ---------------------------------------------------------------------------

  AttemptRecord _record(
    ConnectionCandidate candidate,
    DateTime startedAt,
    AttemptOutcome outcome, {
    String? detail,
    Duration? latency,
  }) => AttemptRecord(
    at: startedAt,
    candidateId: candidate.id,
    candidateName: candidate.name,
    layer: candidate.layer,
    outcome: outcome,
    detail: detail,
    latency: latency,
  );

  /// Short, address-free description of a failure for the attempt log.
  String? _describe(Object? failure) {
    if (failure == null) return null;
    final name = failure.runtimeType.toString();
    return name.replaceAll('Failure', '').replaceAll('Profile', '').replaceAll('Connection', '');
  }
}
