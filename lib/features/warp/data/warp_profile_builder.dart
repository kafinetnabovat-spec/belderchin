import 'dart:convert';

import 'package:hiddify/features/warp/data/warp_endpoint_scanner.dart';
import 'package:hiddify/features/warp/model/warp_identity.dart';

/// Produces the sing-box configuration fed to the core for one WARP endpoint.
/// Format verified against hiddify-core v4.1.0 (`endpoints[].type=wireguard`).
class WarpProfileBuilder {
  const WarpProfileBuilder();

  static const int mtu = 1280;
  static const int keepaliveSeconds = 25;

  String build(WarpIdentity identity, WarpEndpoint endpoint) => jsonEncode(toJson(identity, endpoint));

  Map<String, Object?> toJson(WarpIdentity identity, WarpEndpoint endpoint) => {
    'endpoints': [
      {
        'type': 'wireguard',
        'tag': 'WARP',
        'mtu': mtu,
        'address': ['${identity.addressV4}/32', '${identity.addressV6}/128'],
        'private_key': identity.privateKey,
        'peers': [
          {
            'address': endpoint.address,
            'port': endpoint.port,
            'public_key': identity.peerPublicKey,
            'allowed_ips': ['0.0.0.0/0', '::/0'],
            'reserved': identity.reserved,
            'persistent_keepalive_interval': keepaliveSeconds,
          },
        ],
      },
    ],
  };
}
