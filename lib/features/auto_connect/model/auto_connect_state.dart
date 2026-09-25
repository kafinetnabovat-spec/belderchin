import 'package:hiddify/features/auto_connect/model/connection_candidate.dart';
import 'package:meta/meta.dart';

/// Sub-step while a single candidate is being tried.
enum TryStage { binding, starting, checking }

/// Why the chain gave up.
enum FailureReason { noCandidates, allFailed, vpnPermissionDenied, cancelled }

/// State machine of the one-button auto-connect flow.
///
/// idle → preparing → trying(1..n) → connected | failed
/// connected → disconnecting → idle
/// connected → reconnecting(backoff) → trying… (watchdog)
@immutable
sealed class AutoConnectState {
  const AutoConnectState();

  bool get isBusy => this is AutoConnectPreparing || this is AutoConnectTrying || this is AutoConnectDisconnecting;

  bool get isConnected => this is AutoConnectConnected;
}

class AutoConnectIdle extends AutoConnectState {
  const AutoConnectIdle();
}

class AutoConnectPreparing extends AutoConnectState {
  const AutoConnectPreparing();
}

class AutoConnectTrying extends AutoConnectState {
  const AutoConnectTrying({
    required this.candidate,
    required this.index,
    required this.total,
    required this.stage,
  });

  final ConnectionCandidate candidate;

  /// 1-based position in the current chain.
  final int index;
  final int total;
  final TryStage stage;

  AutoConnectTrying withStage(TryStage next) => AutoConnectTrying(candidate: candidate, index: index, total: total, stage: next);
}

class AutoConnectConnected extends AutoConnectState {
  const AutoConnectConnected({required this.candidate, required this.since});

  final ConnectionCandidate candidate;
  final DateTime since;
}

class AutoConnectReconnecting extends AutoConnectState {
  const AutoConnectReconnecting({required this.attempt, required this.delay, required this.lastCandidate});

  /// 1-based watchdog attempt number.
  final int attempt;
  final Duration delay;
  final ConnectionCandidate? lastCandidate;
}

class AutoConnectDisconnecting extends AutoConnectState {
  const AutoConnectDisconnecting();
}

class AutoConnectFailed extends AutoConnectState {
  const AutoConnectFailed({required this.reason, this.tried = 0});

  final FailureReason reason;
  final int tried;
}

/// Backoff schedule for the reconnect watchdog: 2s, 4s, 8s, … capped at 60s,
/// with ±25% jitter supplied by the caller (kept pure for testing).
Duration reconnectDelay(int attempt, {double jitter = 0}) {
  assert(attempt >= 1, 'attempt is 1-based');
  assert(jitter >= -1 && jitter <= 1, 'jitter must be in [-1, 1]');
  const base = 2000;
  const cap = 60000;
  final exp = attempt - 1 > 10 ? 10 : attempt - 1;
  var ms = base * (1 << exp);
  if (ms > cap) ms = cap;
  ms = (ms * (1 + 0.25 * jitter)).round();
  return Duration(milliseconds: ms);
}
