// Maintainer tool: registers a throw-away WARP identity, scans the endpoint
// ranges of the bundled source list with real WireGuard handshakes and prints
// the responders ordered by RTT.
//
//   dart run tools/warp/handshake_probe.dart [count]
//
// Nothing is stored. Requires network access.
import 'dart:convert';
import 'dart:io';

import 'package:hiddify/features/sources/model/source_list.dart';
import 'package:hiddify/features/warp/data/warp_endpoint_scanner.dart';
import 'package:hiddify/features/warp/data/warp_profile_builder.dart';
import 'package:hiddify/features/warp/data/warp_registration.dart';

Future<void> main(List<String> args) async {
  final count = args.isEmpty ? 48 : int.parse(args.first);
  final identity = await WarpRegistration().register();
  stdout.writeln('registered: $identity reserved=${identity.reserved}');
  final list = SourceList.fromJson(jsonDecode(File('assets/sources/sources.json').readAsStringSync()) as Map<String, Object?>);
  final targets = WarpEndpointScanner.buildTargets(list.warp, count: count);
  final watch = Stopwatch()..start();
  final results = await WarpEndpointScanner(identity: identity).scan(targets);
  stdout.writeln('scanned ${targets.length} targets in ${watch.elapsedMilliseconds} ms, ${results.length} responded:');
  for (final r in results) {
    stdout.writeln('  ${r.endpoint}  ${r.rtt.inMilliseconds} ms');
  }
  if (results.isNotEmpty) {
    stdout.writeln('profile for best endpoint:');
    stdout.writeln(const WarpProfileBuilder().build(identity, results.first.endpoint).replaceAll(identity.privateKey, '<private key>'));
  }
}
