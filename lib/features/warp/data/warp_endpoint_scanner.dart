import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:hiddify/features/warp/data/wireguard_handshake.dart';
import 'package:hiddify/features/warp/model/warp_identity.dart';
import 'package:meta/meta.dart';

@immutable
class WarpEndpoint {
  const WarpEndpoint(this.address, this.port);

  final String address;
  final int port;

  String get id => '$address:$port';

  Map<String, Object?> toJson() => {'address': address, 'port': port};

  factory WarpEndpoint.fromJson(Map<String, Object?> json) =>
      WarpEndpoint(json['address']! as String, json['port']! as int);

  @override
  bool operator ==(Object other) => other is WarpEndpoint && other.address == address && other.port == port;

  @override
  int get hashCode => Object.hash(address, port);

  @override
  String toString() => id;
}

@immutable
class WarpScanResult {
  const WarpScanResult(this.endpoint, this.rtt);

  final WarpEndpoint endpoint;
  final Duration rtt;

  Map<String, Object?> toJson() => {...endpoint.toJson(), 'rtt_ms': rtt.inMilliseconds};

  factory WarpScanResult.fromJson(Map<String, Object?> json) =>
      WarpScanResult(WarpEndpoint.fromJson(json), Duration(milliseconds: json['rtt_ms']! as int));
}

/// Sends a real WireGuard handshake initiation to candidate WARP endpoints and
/// keeps the ones that answer, ordered by round-trip time.
///
/// Light by design: one UDP socket, bounded concurrency, short timeout, and it
/// stops early once [stopAfter] endpoints have answered. A handshake response
/// proves the endpoint is reachable *for this registration* on the current
/// network, which is exactly what the WireGuard tunnel will need.
class WarpEndpointScanner {
  WarpEndpointScanner({
    required this.identity,
    this.concurrency = 8,
    this.timeout = const Duration(milliseconds: 1500),
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random();

  final WarpIdentity identity;
  final int concurrency;
  final Duration timeout;
  final DateTime Function() _now;
  final Random _random;

  /// Well-known WARP ports get half of the probe budget.
  static const List<int> primaryPorts = [2408, 500, 1701, 4500];

  /// Builds a randomised target list from the IPv4 ranges/ports of the signed
  /// list (IPv6 is skipped: mobile networks in the target region rarely have it).
  static List<WarpEndpoint> buildTargets(WarpHints hints, {int count = 48, Random? random}) {
    final rnd = random ?? Random();
    final ranges = hints.endpoints.where((c) => !c.contains(':')).map(_Cidr.tryParse).whereType<_Cidr>().toList();
    if (ranges.isEmpty) return const [];
    final ports = hints.ports.isEmpty ? primaryPorts : hints.ports;
    final primaries = ports.where(primaryPorts.contains).toList();
    final out = <WarpEndpoint>{};
    var guard = 0;
    while (out.length < count && guard++ < count * 10) {
      final range = ranges[rnd.nextInt(ranges.length)];
      final usePrimary = primaries.isNotEmpty && (rnd.nextBool() || ports.length == primaries.length);
      final port = usePrimary ? primaries[rnd.nextInt(primaries.length)] : ports[rnd.nextInt(ports.length)];
      out.add(WarpEndpoint(range.randomHost(rnd), port));
    }
    return out.toList();
  }

  Future<List<WarpScanResult>> scan(List<WarpEndpoint> targets, {int stopAfter = 4}) async {
    if (targets.isEmpty) return const [];
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final pending = <int, _Probe>{};
    final results = <WarpScanResult>[];
    var stop = false;

    final subscription = socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      final index = WireGuardHandshake.receiverIndexOf(datagram.data);
      if (index == null) return;
      final probe = pending.remove(index);
      if (probe == null) return;
      probe.complete(probe.watch.elapsed);
    });

    try {
      final queue = List.of(targets);
      var nextIndex = 0x40000000 + _random.nextInt(0x3fffffff);
      var timestamp = _now().toUtc();

      Future<void> worker() async {
        while (queue.isNotEmpty && !stop) {
          final target = queue.removeAt(0);
          final index = nextIndex++;
          // Strictly increasing timestamps: WireGuard drops replays per key.
          timestamp = timestamp.add(const Duration(microseconds: 1));
          final Uint8List message;
          final InternetAddress address;
          try {
            address = InternetAddress(target.address);
            message = await WireGuardHandshake.buildInitiation(
              staticPrivateKey: identity.privateKeyBytes,
              peerPublicKey: identity.peerPublicKeyBytes,
              senderIndex: index,
              timestamp: timestamp,
            );
          } on Object {
            continue;
          }
          final probe = _Probe();
          pending[index] = probe;
          final sent = socket.send(message, address, target.port);
          if (sent != message.length) {
            pending.remove(index);
            continue;
          }
          final rtt = await probe.future.timeout(timeout, onTimeout: () => null);
          pending.remove(index);
          if (rtt != null) {
            results.add(WarpScanResult(target, rtt));
            if (results.length >= stopAfter) stop = true;
          }
        }
      }

      await Future.wait(List.generate(concurrency, (_) => worker()));
    } finally {
      await subscription.cancel();
      socket.close();
    }
    results.sort((a, b) => a.rtt.compareTo(b.rtt));
    return results;
  }
}

class _Probe {
  final Completer<Duration?> _completer = Completer();
  final Stopwatch watch = Stopwatch()..start();

  Future<Duration?> get future => _completer.future;

  void complete(Duration rtt) {
    if (!_completer.isCompleted) _completer.complete(rtt);
  }
}

class _Cidr {
  const _Cidr(this.base, this.prefix);

  final int base;
  final int prefix;

  static _Cidr? tryParse(String text) {
    final parts = text.split('/');
    if (parts.length != 2) return null;
    final octets = parts[0].split('.');
    final prefix = int.tryParse(parts[1]);
    if (octets.length != 4 || prefix == null || prefix < 8 || prefix > 32) return null;
    var base = 0;
    for (final o in octets) {
      final v = int.tryParse(o);
      if (v == null || v < 0 || v > 255) return null;
      base = (base << 8) | v;
    }
    final mask = prefix == 0 ? 0 : (0xffffffff << (32 - prefix)) & 0xffffffff;
    return _Cidr(base & mask, prefix);
  }

  /// Random host address, avoiding the network and broadcast addresses.
  String randomHost(Random random) {
    final size = 1 << (32 - prefix);
    final offset = size <= 2 ? 0 : 1 + random.nextInt(size - 2);
    final ip = base + offset;
    return '${(ip >> 24) & 255}.${(ip >> 16) & 255}.${(ip >> 8) & 255}.${ip & 255}';
  }
}
