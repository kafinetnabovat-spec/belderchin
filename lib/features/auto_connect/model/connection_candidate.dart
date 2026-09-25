import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:meta/meta.dart';

/// Which layer of the signed source list a candidate comes from. The order of
/// the enum is the default try-order of the auto-connect chain.
enum CandidateLayer { warp, workers, backup }

/// How the candidate's configuration is obtained.
enum CandidateKind {
  /// Built-in WARP endpoint of the core (`warp://` share link, self-registering).
  warpBuiltIn,

  /// Remote subscription URL (Cloudflare Workers or backup subscription).
  remoteSubscription,

  /// Inline configuration text shipped inside the source list.
  inlineConfig,
}

/// One thing the auto-connect chain can try.
@immutable
class ConnectionCandidate {
  const ConnectionCandidate({
    required this.id,
    required this.name,
    required this.layer,
    required this.kind,
    required this.weight,
    this.url,
    this.content,
  });

  /// Stable id (source entry id, or `warp` for the built-in WARP layer).
  final String id;
  final String name;
  final CandidateLayer layer;
  final CandidateKind kind;
  final int weight;
  final Uri? url;
  final String? content;

  /// Share link understood by the core's parser: the built-in WARP endpoint
  /// registers itself and picks an endpoint automatically. Phase 5 replaces
  /// this with scanned endpoints and a locally registered WireGuard profile.
  static const String warpBuiltInLink = 'warp://p1@auto#WARP';

  static const ConnectionCandidate warpBuiltIn = ConnectionCandidate(
    id: 'warp',
    name: 'WARP',
    layer: CandidateLayer.warp,
    kind: CandidateKind.warpBuiltIn,
    weight: 0,
    content: warpBuiltInLink,
  );

  /// Builds the ordered candidate list from a source list: WARP (if enabled),
  /// then Workers, then backup. Inside a layer higher `weight` comes first and
  /// ties keep document order. If [preferredId] is given and present, that
  /// candidate is moved to the front (sticky last-known-good route).
  static List<ConnectionCandidate> fromSourceList(SourceList list, {String? preferredId}) {
    final out = <ConnectionCandidate>[];
    if (list.warp.enabled) out.add(warpBuiltIn);
    out.addAll(_layer(list.workers, CandidateLayer.workers));
    out.addAll(_layer(list.backup, CandidateLayer.backup));
    if (preferredId != null) {
      final index = out.indexWhere((c) => c.id == preferredId);
      if (index > 0) {
        final preferred = out.removeAt(index);
        out.insert(0, preferred);
      }
    }
    return List.unmodifiable(out);
  }

  static Iterable<ConnectionCandidate> _layer(List<SourceEntry> entries, CandidateLayer layer) {
    final indexed = entries.asMap().entries.toList()
      ..sort((a, b) {
        final byWeight = b.value.weight.compareTo(a.value.weight);
        return byWeight != 0 ? byWeight : a.key.compareTo(b.key);
      });
    return indexed.map(
      (e) => ConnectionCandidate(
        id: e.value.id,
        name: e.value.name,
        layer: layer,
        kind: e.value.isRemote ? CandidateKind.remoteSubscription : CandidateKind.inlineConfig,
        weight: e.value.weight,
        url: e.value.url,
        content: e.value.content,
      ),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ConnectionCandidate &&
      other.id == id &&
      other.name == name &&
      other.layer == layer &&
      other.kind == kind &&
      other.weight == weight &&
      other.url == url &&
      other.content == content;

  @override
  int get hashCode => Object.hash(id, name, layer, kind, weight, url, content);

  @override
  String toString() => 'ConnectionCandidate($id, ${layer.name}, ${kind.name})';
}
