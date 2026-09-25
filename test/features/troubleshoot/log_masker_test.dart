import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/troubleshoot/data/log_masker.dart';

void main() {
  const masker = LogMasker();

  test('masks public IPv4/IPv6 but keeps loopback', () {
    final out = masker.mask('dial 162.159.192.1:2408 via 127.0.0.1:12334 and 2606:4700:d0::a29f:c001');
    expect(out, contains('127.0.0.1:12334'));
    expect(out, isNot(contains('162.159.192.1')));
    expect(out, isNot(contains('2606:4700')));
  });

  test('masks share links, urls and hosts', () {
    final out = masker.mask('added vless://11111111-2222-4333-8444-555555555555@my.server.example.com:443?x=1#tag from https://foo.workers.dev/sub');
    expect(out, isNot(contains('vless://')));
    expect(out, isNot(contains('workers.dev')));
    expect(out, isNot(contains('11111111-2222')));
  });

  test('masks key/value secrets', () {
    final out = masker.mask('private_key=abcDEF123 token: "secret-value" password=hunter2 client_id=[1,2,3]');
    expect(out, isNot(contains('abcDEF123')));
    expect(out, isNot(contains('secret-value')));
    expect(out, isNot(contains('hunter2')));
    expect(out, contains('[masked]'));
  });

  test('masks emails, uuids and long base64 blobs', () {
    final out = masker.mask('user a.b@mail.example uuid 0f8fad5b-d9cb-469f-a165-70867728950e blob QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVphYmNkZWZnaGlqa2xtbm9wcXJzdHV2d3h5eg==');
    expect(out, contains('[email]'));
    expect(out, contains('[uuid]'));
    expect(out, contains('[blob]'));
    expect(out, isNot(contains('0f8fad5b')));
  });

  test('does not treat timestamps as IPv6', () {
    const line = '2026-09-25 12:34:56 INFO ready at 12:34:56.789';
    expect(masker.mask(line), line);
    expect(masker.mask('addr 2001:db8::1 and fe80::1%eth0 and 2606:4700:0:0:0:0:0:1'), isNot(contains('db8')));
  });

  test('leaves ordinary log lines readable', () {
    const line = 'INFO[0001] inbound/mixed[mixed-in]: tcp server started at 127.0.0.1:12334';
    expect(masker.mask(line), line);
  });
}
