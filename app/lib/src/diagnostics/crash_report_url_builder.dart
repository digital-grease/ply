/// Builds a pre-filled GitHub Issue Form URL for `.github/ISSUE_TEMPLATE/crash_report.yml` so tapping
/// "Report on GitHub" lands the user on a form that is already filled in. The form field ids
/// (`device`, `app_version`, `report`) match the query parameters here — GitHub renders each value
/// into the matching field on load. Pure Dart; host-testable.
class CrashIssueUrl {
  CrashIssueUrl._();

  static const String base =
      'https://github.com/digital-grease/ply/issues/new?template=crash_report.yml';

  /// Conservative cap before GitHub starts erroring on a long URL.
  static const int maxUrlLength = 7000;

  /// Raw characters of the report head to embed when the full report won't fit.
  static const int truncatedHeadChars = 2000;

  static const String _marker = '\n\n[…truncated — paste the full report (copied to your clipboard) here]';

  /// Build the issue URL. [truncated] is true when the report didn't fit and only its head is embedded
  /// (the caller should put the full report on the clipboard so the user can paste it).
  static ({String url, bool truncated}) build({
    required String device,
    required String appVersion,
    required String report,
  }) {
    final head = '$base'
        '&device=${_enc(device)}'
        '&app_version=${_enc(appVersion)}'
        '&report=';
    final budget = maxUrlLength - head.length;

    final full = _enc(report);
    if (full.length <= budget) {
      return (url: '$head$full', truncated: false);
    }
    final cut = report.length < truncatedHeadChars ? report.length : truncatedHeadChars;
    final headEnc = _enc(report.substring(0, cut) + _marker);
    return (url: '$head$headEnc', truncated: true);
  }

  static String _enc(String value) => Uri.encodeQueryComponent(value);
}
