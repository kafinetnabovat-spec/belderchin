import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/warp/data/warp_endpoint_scanner.dart';
import 'package:hiddify/features/warp/data/warp_store.dart';
import 'package:hiddify/features/warp/model/warp_identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  var now = DateTime.utc(2026, 9, 25, 12);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = DateTime.utc(2026, 9, 25, 12);
  });

  test('identity round-trips and can be cleared', () async {
    final store = WarpStore(prefs, now: () => now);
    expect(store.loadIdentity(), isNull);
    final identity = WarpIdentity(
      privateKey: 'p',
      publicKey: 'q',
      peerPublicKey: 'r',
      reserved: const [9, 8, 7],
      addressV4: '172.16.0.2',
      addressV6: '::2',
      endpointHost: 'engage.cloudflareclient.com',
      createdAt: now,
    );
    await store.saveIdentity(identity);
    expect(store.loadIdentity()?.reserved, [9, 8, 7]);
    await store.clearIdentity();
    expect(store.loadIdentity(), isNull);
  });

  test('endpoints expire after the TTL', () async {
    final store = WarpStore(prefs, now: () => now);
    await store.saveEndpoints([const WarpScanResult(WarpEndpoint('162.159.192.1', 2408), Duration(milliseconds: 30))]);
    expect(store.loadEndpoints()?.single.endpoint.id, '162.159.192.1:2408');
    now = now.add(WarpStore.endpointsTtl + const Duration(minutes: 1));
    expect(store.loadEndpoints(), isNull);
  });

  test('corrupt entries are ignored', () async {
    await prefs.setString(WarpStore.identityKey, '{oops');
    await prefs.setString(WarpStore.endpointsKey, '[]');
    final store = WarpStore(prefs, now: () => now);
    expect(store.loadIdentity(), isNull);
    expect(store.loadEndpoints(), isNull);
  });
}
