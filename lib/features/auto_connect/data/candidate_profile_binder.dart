import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/auto_connect/model/connection_candidate.dart';
import 'package:hiddify/features/profile/data/profile_repository.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/features/profile/model/profile_failure.dart';

/// Maps auto-connect candidates onto the app's existing profile storage so the
/// upstream connection pipeline (config generation, validation, core start) is
/// reused unchanged.
///
/// * Remote candidates become remote profiles keyed by their URL.
/// * Inline / WARP candidates become local profiles whose name carries a
///   `belderchin:<id>` marker (the parser uses `UserOverride.name` verbatim).
///
/// Nothing is fetched when a fresh enough profile already exists, so a
/// connect attempt normally costs zero extra network requests.
class CandidateProfileBinder {
  CandidateProfileBinder(this._profiles, {Duration maxAge = const Duration(hours: 6), DateTime Function()? now})
    : _maxAge = maxAge,
      _now = now ?? DateTime.now;

  final ProfileRepository _profiles;
  final Duration _maxAge;
  final DateTime Function() _now;

  static String markerFor(ConnectionCandidate candidate) => 'belderchin:${candidate.id}';

  /// Returns the id of a usable profile for [candidate], creating or
  /// refreshing it when needed.
  Future<Either<ProfileFailure, String>> bind(ConnectionCandidate candidate) async {
    final existing = await find(candidate);
    switch (candidate.kind) {
      case CandidateKind.remoteSubscription:
        if (existing != null && !_isStale(existing)) return Right(existing.id);
        final url = candidate.url!.toString();
        final refreshed = await _profiles
            .upsertRemote(url, userOverride: UserOverride(name: markerFor(candidate), isAutoUpdateDisable: true))
            .run();
        if (refreshed.isLeft()) {
          // Offline or blocked: a stale copy is better than nothing.
          if (existing != null) return Right(existing.id);
          return Left(refreshed.getLeft().toNullable()!);
        }
        return _idOf(await find(candidate));
      case CandidateKind.warpScanned:
        // Content depends on the scanned endpoint: replace whatever is stored.
        if (existing != null) await _profiles.deleteById(existing.id, existing.active).run();
        final content = candidate.content;
        if (content == null || content.trim().isEmpty) {
          return const Left(ProfileFailure.invalidConfig('empty candidate content'));
        }
        final added = await _profiles.addLocal(content, userOverride: UserOverride(name: markerFor(candidate))).run();
        if (added.isLeft()) return Left(added.getLeft().toNullable()!);
        return _idOf(await find(candidate));
      case CandidateKind.inlineConfig:
      case CandidateKind.warpBuiltIn:
        if (existing != null) return Right(existing.id);
        final content = candidate.content;
        if (content == null || content.trim().isEmpty) {
          return const Left(ProfileFailure.invalidConfig('empty candidate content'));
        }
        final added = await _profiles.addLocal(content, userOverride: UserOverride(name: markerFor(candidate))).run();
        if (added.isLeft()) return Left(added.getLeft().toNullable()!);
        return _idOf(await find(candidate));
    }
  }

  /// Deletes the profile bound to [candidate] (used when a stored profile is
  /// broken and must be recreated).
  Future<void> unbind(ConnectionCandidate candidate) async {
    final existing = await find(candidate);
    if (existing == null) return;
    await _profiles.deleteById(existing.id, existing.active).run();
  }

  Either<ProfileFailure, String> _idOf(ProfileEntity? profile) =>
      profile == null ? const Left(ProfileFailure.notFound()) : Right(profile.id);

  bool _isStale(ProfileEntity profile) => _now().difference(profile.lastUpdate) > _maxAge;

  /// Finds the profile currently bound to [candidate], if any.
  Future<ProfileEntity?> find(ConnectionCandidate candidate) async {
    final all = await _profiles.watchAll().first;
    final list = all.getOrElse((_) => const <ProfileEntity>[]);
    final marker = markerFor(candidate);
    final url = candidate.url?.toString();
    for (final profile in list) {
      switch (profile) {
        case RemoteProfileEntity(url: final profileUrl) when url != null:
          if (profileUrl == url) return profile;
        case LocalProfileEntity(:final name) when url == null:
          if (name == marker) return profile;
        default:
          continue;
      }
    }
    return null;
  }
}
