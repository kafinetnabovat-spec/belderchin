/// Compile-time configuration of the source list bootstrap.
///
/// Mirrors are tried in parallel; the authentic list with the highest version
/// wins. A custom (user-provided) mirror is appended at runtime, see
/// `SourceListStore.customMirror`.
abstract final class SourceListConstants {
  /// Bundled offline copy, always available and verified like any other list.
  static const String bundledAsset = 'assets/sources/sources.signed.json';

  /// Built-in mirrors (https only). Order is also the tie-break order.
  static final List<Uri> builtInMirrors = List.unmodifiable([
    // 1) GitHub raw (this repository, branch main)
    Uri.parse('https://raw.githubusercontent.com/kafinetnabovat-spec/belderchin/main/assets/sources/sources.signed.json'),
    // 2) Cloudflare Pages project serving the same file
    Uri.parse('https://belderchin.pages.dev/sources.signed.json'),
    // 3) jsDelivr CDN view of the repository (Cloudflare/Fastly fronted)
    Uri.parse('https://cdn.jsdelivr.net/gh/kafinetnabovat-spec/belderchin@main/assets/sources/sources.signed.json'),
  ]);

  /// Do not re-fetch more often than this unless forced.
  static const Duration refreshInterval = Duration(hours: 6);

  /// Per-mirror HTTP timeout.
  static const Duration mirrorTimeout = Duration(seconds: 12);

  /// Upper bound for the whole parallel fetch.
  static const Duration overallTimeout = Duration(seconds: 20);

  /// Maximum number of mirrors contacted per refresh (built-in + advertised +
  /// custom), to keep the network footprint bounded.
  static const int maxMirrors = 6;
}
