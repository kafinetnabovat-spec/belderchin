import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/sources/data/source_list_constants.dart';
import 'package:hiddify/features/sources/data/source_list_fetcher.dart';
import 'package:hiddify/features/sources/data/source_list_http.dart';
import 'package:hiddify/features/sources/data/source_list_store.dart';
import 'package:hiddify/features/sources/data/source_list_validator.dart';
import 'package:hiddify/features/sources/data/trusted_keys.dart';
import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// Where the currently active list came from.
enum SourceListOrigin { bundled, cached, remote }

enum SourceListRefreshStatus { idle, running, succeeded, failed }

@immutable
class SourceListState {
  const SourceListState({
    required this.list,
    required this.origin,
    required this.expired,
    required this.requiresNewerApp,
    required this.lastFetchAt,
    this.lastAttempts = const [],
    this.refreshStatus = SourceListRefreshStatus.idle,
  });

  final SourceList list;
  final SourceListOrigin origin;

  /// The active list is past its `expires_at` (still usable, must refresh).
  final bool expired;
  final bool requiresNewerApp;
  final DateTime? lastFetchAt;

  /// Diagnostics of the most recent refresh (for the troubleshooting page).
  final List<MirrorAttempt> lastAttempts;
  final SourceListRefreshStatus refreshStatus;

  SourceListState copyWith({
    SourceList? list,
    SourceListOrigin? origin,
    bool? expired,
    bool? requiresNewerApp,
    DateTime? lastFetchAt,
    List<MirrorAttempt>? lastAttempts,
    SourceListRefreshStatus? refreshStatus,
  }) {
    return SourceListState(
      list: list ?? this.list,
      origin: origin ?? this.origin,
      expired: expired ?? this.expired,
      requiresNewerApp: requiresNewerApp ?? this.requiresNewerApp,
      lastFetchAt: lastFetchAt ?? this.lastFetchAt,
      lastAttempts: lastAttempts ?? this.lastAttempts,
      refreshStatus: refreshStatus ?? this.refreshStatus,
    );
  }
}

// ---------------------------------------------------------------------------
// dependencies (all overridable in tests)

/// Wall clock, injectable for deterministic tests.
final sourceListClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

/// Loads the bundled signed list from the Flutter asset bundle.
final bundledSourceListLoaderProvider = Provider<Future<String> Function()>(
  (ref) => () => rootBundle.loadString(SourceListConstants.bundledAsset),
);

final sourceListValidatorProvider = Provider<SourceListValidator>(
  (ref) => const SourceListValidator(trustedKeys: kTrustedSourceKeys),
);

/// Running app version as understood by `min_app_version` checks.
final sourceListAppVersionProvider = Provider<AppVersion?>((ref) {
  final info = ref.watch(appInfoProvider).valueOrNull;
  return info == null ? null : AppVersion.tryParse(info.version);
});

final sourceListStoreProvider = FutureProvider<SourceListStore>((ref) async {
  final directories = await ref.watch(appDirectoriesProvider.future);
  final preferences = await ref.watch(sharedPreferencesProvider.future);
  return SourceListStore(
    directory: Directory(p.join(directories.baseDir.path, 'sources')),
    preferences: preferences,
  );
});

final sourceListFetcherProvider = Provider<SourceListFetcher>((ref) {
  return SourceListFetcher(
    httpGet: sourceHttpGetFromDio(ref.watch(httpClientProvider)),
    validator: ref.watch(sourceListValidatorProvider),
  );
});

final sourceListProvider = AsyncNotifierProvider<SourceListNotifier, SourceListState>(SourceListNotifier.new);

// ---------------------------------------------------------------------------

/// Owns the active [SourceList].
///
/// Start-up is **offline**: the cached copy and the bundled copy are verified
/// and the newest authentic one becomes active. Network is only touched by
/// [refresh] / [refreshIfDue], which the connection flow calls right before
/// connecting and again once a tunnel is up (so blocked mirrors get a second
/// chance through the tunnel).
class SourceListNotifier extends AsyncNotifier<SourceListState> with AppLogger {
  Completer<SourceListState>? _inflight;

  @override
  Future<SourceListState> build() async {
    final store = await ref.watch(sourceListStoreProvider.future);
    final validator = ref.watch(sourceListValidatorProvider);
    final appVersion = ref.watch(sourceListAppVersionProvider);
    final now = ref.watch(sourceListClockProvider)();
    final loadBundled = ref.watch(bundledSourceListLoaderProvider);

    SourceListAccepted? bundled;
    try {
      final text = await loadBundled();
      final result = await validator.validate(text, now: now, appVersion: appVersion);
      switch (result) {
        case SourceListAccepted():
          bundled = result;
        case SourceListRejected():
          loggy.error('bundled source list rejected: $result');
      }
    } on Exception catch (e) {
      loggy.error('bundled source list unreadable', e);
    }

    SourceListAccepted? cached;
    final cachedText = await store.readCachedEnvelope();
    if (cachedText != null) {
      final result = await validator.validate(
        cachedText,
        now: now,
        previousVersion: store.lastAcceptedVersion,
        appVersion: appVersion,
      );
      switch (result) {
        case SourceListAccepted():
          cached = result;
        case SourceListRejected():
          loggy.warning('cached source list rejected, discarding: $result');
          await store.clearCache();
      }
    }

    final SourceListAccepted chosen;
    final SourceListOrigin origin;
    if (cached != null && (bundled == null || cached.list.version >= bundled.list.version)) {
      chosen = cached;
      origin = SourceListOrigin.cached;
    } else if (bundled != null) {
      chosen = bundled;
      origin = SourceListOrigin.bundled;
    } else {
      throw StateError('no authentic source list available');
    }
    await store.setLastAcceptedVersion(chosen.list.version);
    loggy.info(
      'active source list v${chosen.list.version} (${origin.name}, '
      'workers=${chosen.list.workers.length}, backup=${chosen.list.backup.length}, '
      'expired=${chosen.expired})',
    );
    return SourceListState(
      list: chosen.list,
      origin: origin,
      expired: chosen.expired,
      requiresNewerApp: chosen.requiresNewerApp,
      lastFetchAt: store.lastFetchAt,
    );
  }

  /// Refreshes only when the last fetch is older than
  /// [SourceListConstants.refreshInterval] or the active list is expired.
  Future<SourceListState> refreshIfDue() async {
    final current = await future;
    final now = ref.read(sourceListClockProvider)();
    final last = current.lastFetchAt;
    final due = current.expired || last == null || now.difference(last) >= SourceListConstants.refreshInterval;
    if (!due) return current;
    return refresh();
  }

  /// Contacts the mirrors and adopts a newer authentic list if one is found.
  /// Never throws; failures are reported through [SourceListState.refreshStatus]
  /// and [SourceListState.lastAttempts]. Concurrent calls share one request.
  Future<SourceListState> refresh() async {
    final inflight = _inflight;
    if (inflight != null) return inflight.future;
    final completer = Completer<SourceListState>();
    _inflight = completer;
    try {
      final result = await _refresh();
      completer.complete(result);
      return result;
    } on Exception catch (e, s) {
      loggy.error('source list refresh crashed', e, s);
      final current = state.valueOrNull ?? await future;
      final next = current.copyWith(refreshStatus: SourceListRefreshStatus.failed);
      state = AsyncData(next);
      completer.complete(next);
      return next;
    } finally {
      _inflight = null;
    }
  }

  Future<SourceListState> _refresh() async {
    final current = await future;
    final store = await ref.read(sourceListStoreProvider.future);
    final fetcher = ref.read(sourceListFetcherProvider);
    final appVersion = ref.read(sourceListAppVersionProvider);
    final now = ref.read(sourceListClockProvider)();

    state = AsyncData(current.copyWith(refreshStatus: SourceListRefreshStatus.running));

    final floor = max(current.list.version, store.lastAcceptedVersion ?? 0);
    final result = await fetcher.fetch(
      mirrors: mirrorsFor(current.list, customMirror: store.customMirror),
      now: now,
      previousVersion: floor,
      appVersion: appVersion,
    );
    for (final attempt in result.attempts) {
      loggy.debug('mirror ${attempt.url.host}: $attempt');
    }

    final best = result.best;
    if (best == null) {
      loggy.warning('source list refresh failed on all ${result.attempts.length} mirrors');
      final next = current.copyWith(lastAttempts: result.attempts, refreshStatus: SourceListRefreshStatus.failed);
      state = AsyncData(next);
      return next;
    }

    await store.setLastFetchAt(now);
    if (best.list.version > current.list.version || current.origin != SourceListOrigin.remote) {
      await store.writeCachedEnvelope(best.envelope.encode());
      await store.setLastAcceptedVersion(best.list.version);
    }
    final adoptNewer = best.list.version >= current.list.version;
    final next = SourceListState(
      list: adoptNewer ? best.list : current.list,
      origin: adoptNewer ? SourceListOrigin.remote : current.origin,
      expired: adoptNewer ? best.expired : current.expired,
      requiresNewerApp: adoptNewer ? best.requiresNewerApp : current.requiresNewerApp,
      lastFetchAt: now,
      lastAttempts: result.attempts,
      refreshStatus: SourceListRefreshStatus.succeeded,
    );
    loggy.info('source list refreshed: v${next.list.version} (was v${current.list.version})');
    state = AsyncData(next);
    return next;
  }

  /// Built-in mirrors, then mirrors advertised by the active list, then the
  /// user's custom mirror. Deduplicated, https only, bounded by
  /// [SourceListConstants.maxMirrors].
  @visibleForTesting
  static List<Uri> mirrorsFor(SourceList list, {Uri? customMirror}) {
    final out = <Uri>[];
    void add(Uri uri) {
      if (uri.scheme != 'https' || uri.host.isEmpty) return;
      if (!out.contains(uri) && out.length < SourceListConstants.maxMirrors) out.add(uri);
    }

    SourceListConstants.builtInMirrors.forEach(add);
    list.mirrors.forEach(add);
    if (customMirror != null) add(customMirror);
    return out;
  }
}
