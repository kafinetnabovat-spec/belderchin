import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/auto_connect/model/connection_candidate.dart';
import 'package:hiddify/features/sources/model/source_list.dart';

import '../sources/test_signing.dart';

SourceList _list({
  bool warp = true,
  List<Map<String, Object?>> workers = const [],
  List<Map<String, Object?>> backup = const [],
}) {
  final json = samplePayload(workers: workers, backup: backup);
  (json['warp']! as Map<String, Object?>)['enabled'] = warp;
  return SourceList.fromJson(json);
}

Map<String, Object?> _remote(String id, int weight) => {
  'id': id,
  'name': 'Worker $id',
  'url': 'https://$id.example.workers.dev/sub',
  'weight': weight,
};

Map<String, Object?> _inline(String id, int weight) => {
  'id': id,
  'name': 'Backup $id',
  'content': 'vless://00000000-0000-4000-8000-000000000000@example.com:443?security=tls#$id',
  'weight': weight,
};

void main() {
  group('ConnectionCandidate.fromSourceList', () {
    test('orders WARP, then workers by weight desc, then backup', () {
      final list = _list(
        workers: [_remote('w-low', 1), _remote('w-high', 9), _remote('w-mid', 5)],
        backup: [_inline('b1', 0), _inline('b2', 10)],
      );
      final ids = ConnectionCandidate.fromSourceList(list).map((c) => c.id).toList();
      expect(ids, ['warp', 'w-high', 'w-mid', 'w-low', 'b2', 'b1']);
    });

    test('ties keep document order', () {
      final list = _list(workers: [_remote('a', 3), _remote('b', 3), _remote('c', 3)]);
      final ids = ConnectionCandidate.fromSourceList(list).map((c) => c.id).toList();
      expect(ids, ['warp', 'a', 'b', 'c']);
    });

    test('omits WARP when the list disables it', () {
      final list = _list(warp: false, workers: [_remote('a', 1)]);
      final candidates = ConnectionCandidate.fromSourceList(list);
      expect(candidates.map((c) => c.id), ['a']);
      expect(candidates.single.kind, CandidateKind.remoteSubscription);
      expect(candidates.single.layer, CandidateLayer.workers);
    });

    test('maps entry kinds and layers', () {
      final list = _list(workers: [_remote('a', 1)], backup: [_inline('b', 1)]);
      final byId = {for (final c in ConnectionCandidate.fromSourceList(list)) c.id: c};
      expect(byId['warp']!.kind, CandidateKind.warpBuiltIn);
      expect(byId['warp']!.content, ConnectionCandidate.warpBuiltInLink);
      expect(byId['a']!.url, Uri.parse('https://a.example.workers.dev/sub'));
      expect(byId['b']!.kind, CandidateKind.inlineConfig);
      expect(byId['b']!.layer, CandidateLayer.backup);
      expect(byId['b']!.content, startsWith('vless://'));
    });

    test('moves the preferred candidate to the front', () {
      final list = _list(workers: [_remote('a', 5), _remote('b', 1)]);
      final ids = ConnectionCandidate.fromSourceList(list, preferredId: 'b').map((c) => c.id).toList();
      expect(ids, ['b', 'warp', 'a']);
    });

    test('ignores an unknown preferred id', () {
      final list = _list(workers: [_remote('a', 5)]);
      final ids = ConnectionCandidate.fromSourceList(list, preferredId: 'gone').map((c) => c.id).toList();
      expect(ids, ['warp', 'a']);
    });

    test('returns an empty chain for an empty list without WARP', () {
      expect(ConnectionCandidate.fromSourceList(_list(warp: false)), isEmpty);
    });
  });
}
