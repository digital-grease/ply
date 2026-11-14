// The fonts printed PDFs are set in: Fira Sans Regular and Bold (SIL Open Font License 1.1; the
// license is `assets/fonts/OFL.txt`), bundled as app assets so making a PDF never fetches a font.
// Chosen because it covers Latin (with the Nordic and Central European letters nalbinding and
// knitting names use), Greek and Cyrillic, the multiplication sign of a repeat label, arrows, and
// en dashes, and because its "l" (tailed), "I" and "1" are distinct, which matters in stitch
// abbreviations like m1l and in Hansen notation like F1. See ADR 0011.

import 'package:flutter/services.dart' show AssetBundle, ByteData, rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart' show TtfParser;
import 'package:pdf/widgets.dart' as pw;

/// The loaded print fonts.
class PlyPdfFonts {
  PlyPdfFonts._(ByteData regular, ByteData bold)
      : this._parsed(regular, bold, TtfParser(regular), TtfParser(bold));

  PlyPdfFonts._parsed(ByteData regular, ByteData bold, TtfParser r, TtfParser b)
      : regular = pw.TtfFont(regular),
        bold = pw.TtfFont(bold),
        _regularMetrics = r,
        _supported = {...r.charToGlyphIndexMap.keys}.intersection({...b.charToGlyphIndexMap.keys});

  /// Build from the two font files' bytes (tests read them straight from `assets/fonts`).
  factory PlyPdfFonts.fromBytes({required ByteData regular, required ByteData bold}) =>
      PlyPdfFonts._(regular, bold);

  /// Load the bundled fonts from [bundle] (the app's asset bundle by default).
  static Future<PlyPdfFonts> load([AssetBundle? bundle]) async {
    final b = bundle ?? rootBundle;
    return PlyPdfFonts._(await b.load(regularAsset), await b.load(boldAsset));
  }

  static const regularAsset = 'assets/fonts/FiraSans-Regular.ttf';
  static const boldAsset = 'assets/fonts/FiraSans-Bold.ttf';

  final pw.Font regular;
  final pw.Font bold;

  /// Code points both weights can draw.
  final Set<int> _supported;

  /// The regular weight's glyph metrics, for measuring text before a page exists.
  final TtfParser _regularMetrics;

  /// The advance width of [s] in points at [size] in the regular weight. Used to size the margins of
  /// a weaving draft's grids at layout time (a character the font lacks counts as half an em).
  double textWidth(String s, double size) {
    var w = 0.0;
    for (final r in s.runes) {
      final g = _regularMetrics.charToGlyphIndexMap[r];
      w += (g == null ? null : _regularMetrics.glyphInfoMap[g]?.advanceWidth) ?? 0.5;
    }
    return w * size;
  }

  /// Whether [rune] prints as itself (white space and control characters always do: nothing is
  /// drawn for them).
  bool supports(int rune) => rune <= 0x20 || _isSpace(rune) || _supported.contains(rune);

  /// The distinct characters in [texts] the fonts cannot draw, in first-seen order. They would print
  /// as empty boxes, so the document says which they are.
  List<String> unsupportedIn(Iterable<String> texts) {
    final seen = <int>{};
    final missing = <String>[];
    for (final t in texts) {
      for (final r in t.runes) {
        if (!supports(r) && seen.add(r)) missing.add(String.fromCharCode(r));
      }
    }
    return missing;
  }

  static bool _isSpace(int r) =>
      r == 0x7F ||
      r == 0xA0 ||
      (r >= 0x2000 && r <= 0x200F) ||
      r == 0x202F ||
      r == 0x205F ||
      r == 0x3000 ||
      r == 0xFEFF;
}

/// The print fonts, loaded once per app run. Tests override it with fonts read from disk.
final plyPdfFontsProvider = FutureProvider<PlyPdfFonts>((_) => PlyPdfFonts.load());
