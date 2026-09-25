import 'dart:async';

import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/auto_connect/model/connection_candidate.dart';
import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:hiddify/features/warp/data/warp_endpoint_scanner.dart';
import 'package:hiddify/features/warp/data/warp_profile_builder.dart';
import 'package:hiddify/features/warp/data/warp_registration.dart';
import 'package:hiddify/features/warp/data/warp_store.dart';
import 'package:hiddify/features/warp/model/warp_identity.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

/// Registration function; overridden in tests.
final warpRegistrationProvider = Provider<Future<WarpIdentity> Function()>((ref) => () => WarpRegistration().register());

/// Scanner factory; overridden in tests.
final warpScannerProvider = Provider<Future<List<WarpScanResult>> Function(WarpIdentity, WarpHints)>((ref) {
  return (identity, hints) {
    final scanner = WarpEndpointScanner(identity: identity);
    return scanner.scan(WarpEndpointScanner.buildTargets(hints));
  };
});

final warpStoreProvider = FutureProvider<WarpStore>((ref) async => WarpStore(await ref.watch(sharedPreferencesProvider.future)));

final warpLayerProvider = Provider<WarpLayer>(WarpLayer.new);

/// Turns the WARP layer of the signed list into concrete candidates:
/// the best scanned endpoints (each a WireGuard profile with our own
/// registration) followed by the core's built-in WARP endpoint as a fallback.
///
/// Network use: one registration per device (cached forever), and a scan only
/// when there is no fresh cached result or the cached endpoints just failed.
class WarpLayer with AppLogger {
  WarpLayer(this._ref);

  final Ref _ref;

  static const int maxScannedCandidates = 2;
  static const Duration registrationBudget = Duration(seconds: 15);
  static const Duration scanBudget = Duration(seconds: 12);

  Completer<List<ConnectionCandidate>>? _inflight;

  Future<List<ConnectionCandidate>> candidates(WarpHints hints, {bool forceRescan = false}) {
    final inflight = _inflight;
    if (inflight != null) return inflight.future;
    final completer = Completer<List<ConnectionCandidate>>();
    _inflight = completer;
    _candidates(hints, forceRescan: forceRescan).then(completer.complete).catchError((Object e, StackTrace s) {
      loggy.warning('warp layer failed', e, s);
      completer.complete(const [ConnectionCandidate.warpBuiltIn]);
    }).whenComplete(() => _inflight = null);
    return completer.future;
  }

  Future<List<ConnectionCandidate>> _candidates(WarpHints hints, {required bool forceRescan}) async {
    final store = await _ref.read(warpStoreProvider.future);
    var identity = store.loadIdentity();
    if (identity == null) {
      try {
        identity = await _ref.read(warpRegistrationProvider)().timeout(registrationBudget);
        await store.saveIdentity(identity);
        loggy.info('registered new WARP identity');
      } on Object catch (e) {
        loggy.warning('WARP registration unavailable: $e');
        return const [ConnectionCandidate.warpBuiltIn];
      }
    }

    var endpoints = forceRescan ? null : store.loadEndpoints();
    if (endpoints == null || endpoints.isEmpty) {
      try {
        endpoints = await _ref.read(warpScannerProvider)(identity, hints).timeout(scanBudget, onTimeout: () => const []);
      } on Object catch (e) {
        loggy.warning('WARP scan failed: $e');
        endpoints = const [];
      }
      if (endpoints.isNotEmpty) await store.saveEndpoints(endpoints);
      loggy.info('WARP scan: ${endpoints.length} responding endpoints');
    }

    const builder = WarpProfileBuilder();
    return [
      for (final result in endpoints.take(maxScannedCandidates))
        ConnectionCandidate(
          id: 'warp:${result.endpoint.id}',
          name: 'WARP',
          layer: CandidateLayer.warp,
          kind: CandidateKind.warpScanned,
          weight: 0,
          content: builder.build(identity, result.endpoint),
        ),
      ConnectionCandidate.warpBuiltIn,
    ];
  }

  /// Drops the cached endpoints so the next chain scans again.
  Future<void> invalidateEndpoints() async {
    final store = await _ref.read(warpStoreProvider.future);
    await store.clearEndpoints();
  }

  /// Drops the registration too (e.g. when every endpoint rejects it).
  Future<void> reset() async {
    final store = await _ref.read(warpStoreProvider.future);
    await store.clearEndpoints();
    await store.clearIdentity();
  }
}
