import 'package:ply/src/rust/nalbind_dto.dart';

// Builders for the notation-reading DTOs the bridge's `analyze_nalbind` returns, so the nalbind
// screen tests can fake a reading without the FFI. The messages below are the engine's real ones
// for these inputs (spans are UTF-16 offsets, as the bridge sends them).

/// A diagnostic whose `text` is the slice of [source] its span selects (as the bridge guarantees).
NotationDiagnosticDto diagnostic(
  String source,
  String code,
  NotationSeverityKind severity,
  int start,
  int end,
  String message,
) =>
    NotationDiagnosticDto(
      code: code,
      severity: severity,
      message: message,
      span: NotationSpanDto(start: start, end: end),
      text: source.substring(start, end),
    );

/// A reading of [source] whose best-effort structure is [stitch].
ParsedNotationDto reading(
  String source,
  NalbindStitchDto stitch, {
  bool strict = false,
  bool accepted = true,
  FidelityKind fidelity = FidelityKind.exact,
  String? normalized,
  List<NotationDiagnosticDto> diagnostics = const [],
  List<OpaqueTokenDto> opaque = const [],
}) =>
    ParsedNotationDto(
      source: source,
      mode: strict ? NotationModeKind.strict : NotationModeKind.lenient,
      accepted: accepted,
      fidelity: fidelity,
      normalized: normalized ?? source,
      stitch: stitch,
      opaque: opaque,
      diagnostics: diagnostics,
    );

/// `UO/XYZ`: the turn has nothing after it and `XYZ` is not notation. The trailing-turn finding
/// comes FIRST in source order, so a list that shows errors first must reorder them.
ParsedNotationDto badReading(NalbindStitchDto bestEffort, {required bool strict}) {
  const src = 'UO/XYZ';
  final turn = strict ? NotationSeverityKind.error : NotationSeverityKind.warning;
  return reading(
    src,
    bestEffort,
    strict: strict,
    accepted: false,
    fidelity: FidelityKind.lossy,
    normalized: 'UO',
    diagnostics: [
      diagnostic(src, 'trailing-turn', turn, 2, 3,
          'turn `/` comes after the last needle step; dropped'),
      diagnostic(src, 'unexpected-character', NotationSeverityKind.error, 3, 6,
          'unexpected characters `XYZ`; kept verbatim as an opaque token'),
    ],
    opaque: const [
      OpaqueTokenDto(text: 'XYZ', span: NotationSpanDto(start: 3, end: 6)),
    ],
  );
}

/// `uo/uoo f1`: accepted, only letter case tidied (three Info notes).
ParsedNotationDto lowercaseReading(NalbindStitchDto stitch, {required bool strict}) {
  const src = 'uo/uoo f1';
  return reading(
    src,
    stitch,
    strict: strict,
    fidelity: FidelityKind.normalized,
    normalized: 'UO/UOO F1',
    diagnostics: [
      diagnostic(src, 'case-normalized', NotationSeverityKind.info, 0, 2,
          'lowercase `uo` is read as uppercase'),
      diagnostic(src, 'case-normalized', NotationSeverityKind.info, 3, 6,
          'lowercase `uoo` is read as uppercase'),
      diagnostic(src, 'case-normalized', NotationSeverityKind.info, 7, 8,
          'lowercase `f` is read as uppercase'),
    ],
  );
}

/// The exact text the feedback list shows for a quoted finding.
String shownFinding(String severity, String quote, String message) =>
    '$severity at "$quote": $message';
