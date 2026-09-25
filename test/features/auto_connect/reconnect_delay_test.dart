import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/auto_connect/model/auto_connect_state.dart';

void main() {
  group('reconnectDelay', () {
    test('doubles from 2 s and caps at 60 s', () {
      expect(reconnectDelay(1), const Duration(seconds: 2));
      expect(reconnectDelay(2), const Duration(seconds: 4));
      expect(reconnectDelay(3), const Duration(seconds: 8));
      expect(reconnectDelay(5), const Duration(seconds: 32));
      expect(reconnectDelay(6), const Duration(seconds: 60));
      expect(reconnectDelay(40), const Duration(seconds: 60));
    });

    test('applies ±25% jitter', () {
      expect(reconnectDelay(2, jitter: 1), const Duration(seconds: 5));
      expect(reconnectDelay(2, jitter: -1), const Duration(seconds: 3));
      expect(reconnectDelay(6, jitter: 1), const Duration(seconds: 75));
    });
  });

  group('AutoConnectState', () {
    test('busy / connected flags', () {
      expect(const AutoConnectIdle().isBusy, isFalse);
      expect(const AutoConnectPreparing().isBusy, isTrue);
      expect(const AutoConnectDisconnecting().isBusy, isTrue);
      expect(const AutoConnectFailed(reason: FailureReason.allFailed).isConnected, isFalse);
    });
  });
}
