import '../rust/api.dart';
import '../rust/nalbind_dto.dart';

/// The one place the app touches the generated bridge symbols for `ply-nalbind` — the nalbind analog
/// of [DraftRepository] / [KnitRepository]. The reference screen + notation playground depend on this,
/// never on `api.dart` directly. v1 is read-only (a stitch reference + diagram), so there is no
/// persistence yet (no project model — see `docs/NALBIND_DESIGN.md`).
class NalbindRepository {
  NalbindRepository();

  /// The curated builtin stitch dictionary (~12 stitches).
  Future<List<NalbindStitchDto>> builtins() => nalbindBuiltin();

  /// Parse a Hansen-notation string into an anonymous stitch (the notation playground). Throws on an
  /// unrecognized character (the bridge returns the parse message).
  Future<NalbindStitchDto> parse(String notation) => parseNalbind(notation: notation);

  /// The canonical Hansen string for a stitch.
  Future<String> printNotation(NalbindStitchDto dto) => printNalbind(dto: dto);

  /// The per-stitch structural loop diagram (a vector model the painter draws).
  Future<DiagramDto> diagram(NalbindStitchDto dto) => nalbindDiagram(dto: dto);

  /// Validate a stitch; empty list = clean.
  Future<List<NalbindIssueDto>> validate(NalbindStitchDto dto) => validateNalbind(dto: dto);

  /// A stitch + its diagram together (the reference list shows both).
  Future<({NalbindStitchDto stitch, DiagramDto diagram})> withDiagram(NalbindStitchDto s) async =>
      (stitch: s, diagram: await diagram(s));
}
