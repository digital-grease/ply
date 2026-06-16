/// Redacts likely-sensitive content from logs and crash reports BEFORE they are shown or shared, so a
/// report a user copies into a public issue can't leak their data. Conservative and irreversible —
/// matched spans become `[REDACTED]`. Ply logs little that is sensitive, so this is defense in depth
/// (e.g. an optional Ravelry key, a home-directory username embedded in a file path).
class LogScrubber {
  LogScrubber._();

  static const String redacted = '[REDACTED]';

  // The home-directory user segment in absolute paths (/home/<user>/…, /Users/<user>/…). The rest of
  // the path is kept (it aids debugging and isn't identifying).
  static final RegExp _homeUser = RegExp(r'(/(?:home|Users)/)([^/\s]+)');

  static final List<RegExp> _patterns = [
    // Email addresses.
    RegExp(r'[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}'),
    // Long hex runs (>= 16) — tokens, hashes, raw keys (matches the Signet export-scrub threshold).
    RegExp(r'\b[A-Fa-f0-9]{16,}\b'),
    // Long base64-ish runs (>= 32) — e.g. a Basic-auth credential, were one ever logged.
    RegExp(r'\b[A-Za-z0-9+/]{32,}={0,2}\b'),
  ];

  /// Return [text] with sensitive spans replaced by [redacted].
  static String scrub(String text) {
    var out = text.replaceAllMapped(_homeUser, (m) => '${m[1]}$redacted');
    for (final p in _patterns) {
      out = out.replaceAll(p, redacted);
    }
    return out;
  }
}
