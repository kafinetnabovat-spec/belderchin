/// Masks addresses and secrets in log text before it is shown or copied.
///
/// Logs never leave the device, but users may paste them into public issue
/// trackers or chats, so anything that identifies a server, an account or a
/// person is replaced with a placeholder.
class LogMasker {
  const LogMasker();

  static final RegExp _ipv4 = RegExp(r'\b(?:\d{1,3}\.){3}\d{1,3}(?::\d{1,5})?\b');
  static final RegExp _ipv6Token = RegExp(r'(?<![\w:.])[0-9a-fA-F:]{3,45}(?![\w:])');
  static final RegExp _url = RegExp(r'\b(?:https?|wss?|vless|vmess|trojan|ss|hysteria2?|hy2|tuic|warp|socks5?)://[^\s"\x27<>]+', caseSensitive: false);
  static final RegExp _host = RegExp(r'\b(?:[a-zA-Z0-9-]{1,63}\.)+(?:com|net|org|io|dev|app|me|xyz|ir|info|site|top|online|cloud|workers|pages|cc|tv|co|sh|link)\b', caseSensitive: false);
  static final RegExp _uuid = RegExp(r'\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b');
  static final RegExp _keyValue = RegExp(
    r'\b(token|key|private_key|privateKey|password|pass|auth|authorization|license|secret|uuid|id|pre_shared_key|psk|client_id)\b(\s*[:=]\s*)("?)([^\s",;&]+)',
    caseSensitive: false,
  );
  static final RegExp _base64Blob = RegExp(r'\b[A-Za-z0-9+/_-]{40,}={0,2}\b');
  static final RegExp _email = RegExp(r'\b[\w.+-]+@[\w-]+\.[\w.-]+\b');

  String mask(String input) {
    var text = input;
    text = text.replaceAllMapped(_keyValue, (m) => '${m[1]}${m[2]}${m[3]}[masked]');
    text = text.replaceAll(_url, '[url]');
    text = text.replaceAll(_email, '[email]');
    text = text.replaceAll(_uuid, '[uuid]');
    text = text.replaceAllMapped(_ipv4, (m) => _isLoopback(m[0]!) ? m[0]! : '[ip]');
    text = text.replaceAllMapped(_ipv6Token, (m) => _looksLikeIpv6(m[0]!) ? '[ipv6]' : m[0]!);
    text = text.replaceAll(_host, '[host]');
    text = text.replaceAll(_base64Blob, '[blob]');
    return text;
  }

  /// Distinguishes IPv6 literals from timestamps such as `12:34:56`: an IPv6
  /// address has a `::`, a hex letter, or at least five groups.
  static bool _looksLikeIpv6(String token) {
    final colons = ':'.allMatches(token).length;
    if (colons < 2 || colons > 7) return false;
    if (token.contains('::')) return token != '::';
    if (RegExp('[a-fA-F]').hasMatch(token)) return true;
    return colons >= 4;
  }

  /// Keeps loopback addresses: they are needed to debug the local proxy port
  /// and identify nobody.
  bool _isLoopback(String address) => address.startsWith('127.') || address.startsWith('0.0.0.0');
}
