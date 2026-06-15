import 'draft_meta.dart';

/// An in-memory pairing of a saved knitting pattern's sidecar metadata with its on-disk files —
/// the knit analog of [DraftEntry], built by the repository's `listKnits()`.
///
/// Reuses the craft-agnostic [DraftMeta] (its `craft` is `'Knitting'` here) so the sidecar matches
/// `ply_common::ProjectMeta` exactly as the weave one does — no parallel meta class.
class KnitEntry {
  const KnitEntry({
    required this.id,
    required this.meta,
    required this.patternPath,
    this.thumbPath,
  });

  /// The uuid stem shared by `<id>.plyknit`, `<id>.json`, and `<id>.png`.
  final String id;

  /// The decoded sidecar metadata (`meta.craft == 'Knitting'`).
  final DraftMeta meta;

  /// Absolute path to the `<id>.plyknit` native JSON (always present — the list skips entries whose
  /// `.plyknit` is missing).
  final String patternPath;

  /// Absolute path to the `<id>.png` thumbnail, or null if not generated yet.
  final String? thumbPath;
}
