import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/warp/data/warp_registration.dart';

const _reply = '''
{"id":"t.7f3c1c9e-0000-4000-8000-000000000000","type":"a","model":"PC","name":"","key":"PUBKEY=",
 "account":{"id":"acc","account_type":"free","warp_plus":true,"license":"XXXX-XXXX-XXXX"},
 "config":{"client_id":"h9LB","peers":[{"public_key":"bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=",
   "endpoint":{"v4":"162.159.192.3:0","v6":"[2606:4700:d0::a29f:c003]:0","host":"engage.cloudflareclient.com:2408","ports":[2408,500,1701,4500]}}],
   "interface":{"addresses":{"v4":"172.16.0.2","v6":"2606:4700:110:86e2:7b22:861b:5df5:9c96"}},
   "services":{"http_proxy":"172.16.0.1:2480"}},
 "token":"tok","warp_enabled":false,"waitlist_enabled":false,"place":0,"locale":"en-US","enabled":true}
''';

void main() {
  group('WarpRegistration.parseResponse', () {
    test('extracts keys, addresses, reserved bytes and handles', () {
      final identity = WarpRegistration.parseResponse(
        _reply,
        privateKey: 'PRIV=',
        publicKey: 'PUBKEY=',
        createdAt: DateTime.utc(2026, 9, 25),
      );
      expect(identity.peerPublicKey, 'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=');
      expect(identity.reserved, [135, 210, 193]);
      expect(identity.addressV4, '172.16.0.2');
      expect(identity.addressV6, '2606:4700:110:86e2:7b22:861b:5df5:9c96');
      expect(identity.endpointHost, 'engage.cloudflareclient.com');
      expect(identity.deviceId, 't.7f3c1c9e-0000-4000-8000-000000000000');
      expect(identity.accessToken, 'tok');
      expect(identity.privateKey, 'PRIV=');
    });

    test('round-trips through JSON', () {
      final identity = WarpRegistration.parseResponse(_reply, privateKey: 'PRIV=', publicKey: 'PUBKEY=', createdAt: DateTime.utc(2026));
      final copy = identity.toJson();
      expect(copy['private_key'], 'PRIV=');
      expect(copy['reserved'], [135, 210, 193]);
      expect(copy['created_at'], '2026-01-01T00:00:00.000Z');
    });

    test('rejects malformed replies', () {
      expect(
        () => WarpRegistration.parseResponse('nope', privateKey: 'a', publicKey: 'b', createdAt: DateTime.utc(2026)),
        throwsA(isA<WarpRegistrationException>()),
      );
      expect(
        () => WarpRegistration.parseResponse('{"config":{}}', privateKey: 'a', publicKey: 'b', createdAt: DateTime.utc(2026)),
        throwsA(isA<WarpRegistrationException>()),
      );
    });
  });
}
