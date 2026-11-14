// The printable-document MODEL (M9-02): what a printed pattern says, independent of any craft and of
// the PDF library. A craft builds a [PrintDocument] from its own data (knit_print.dart,
// nalbind_print.dart, weave_print.dart), and `pdf_builder.dart` lays it out on pages. Keeping the model
// plain data makes the content testable without parsing a PDF, and lets every craft share one
// layout: title block, a problems box, sections, legends, notes, warnings, charts, drawings and
// photos, with the same page numbering, page sizes and pagination rules.

import 'dart:typed_data';

/// A whole printable document.
class PrintDocument {
  const PrintDocument({
    required this.title,
    required this.kind,
    this.titleFacts = const [],
    this.problemsBox,
    this.sections = const [],
  });

  /// The pattern or project name, the document's main heading (and the PDF title).
  final String title;

  /// What it is, under the title: "Knitting pattern", "Nalbinding project".
  final String kind;

  /// Short facts shown in the title block ("Printed": "2026-11-12", ...).
  final List<PrintFact> titleFacts;

  /// The "this has problems" box printed right under the title, present only when the user chose to
  /// print a pattern that still has errors (the export readiness rule, roadmap M7-05).
  final PrintNotice? problemsBox;

  final List<PrintSection> sections;

  /// Every piece of text the document prints, so the builder can find characters the print font
  /// cannot show (they are flagged on the page, never silently dropped).
  Iterable<String> get allText sync* {
    yield title;
    yield kind;
    for (final f in titleFacts) {
      yield* f.allText;
    }
    if (problemsBox != null) yield* problemsBox!.allText;
    for (final s in sections) {
      yield s.heading;
      for (final b in s.blocks) {
        yield* b.allText;
      }
    }
  }
}

/// One headed section ("Stitch key", "Chart", "Written instructions", ...).
class PrintSection {
  const PrintSection(this.heading, this.blocks);
  final String heading;
  final List<PrintBlock> blocks;
}

/// A label and its value ("Gauge": "18 sts and 24 rows = 4 in").
class PrintFact {
  const PrintFact(this.label, this.value);
  final String label;
  final String value;

  Iterable<String> get allText => [label, value];
}

/// One element of a section.
sealed class PrintBlock {
  const PrintBlock();
  Iterable<String> get allText;
}

/// How a [PrintParagraph] is set.
enum PrintTextStyle {
  /// Normal reading text.
  body,

  /// Smaller, quieter text: explanations and print notes.
  muted,

  /// Bold body text.
  strong,
}

/// Running text. Line breaks in [text] start new paragraphs, so long notes split across pages.
final class PrintParagraph extends PrintBlock {
  const PrintParagraph(this.text, {this.style = PrintTextStyle.body});
  final String text;
  final PrintTextStyle style;

  @override
  Iterable<String> get allText => [text];
}

/// A two-column list of facts.
final class PrintFacts extends PrintBlock {
  const PrintFacts(this.facts);
  final List<PrintFact> facts;

  @override
  Iterable<String> get allText => facts.expand((f) => f.allText);
}

/// An RGBA8 picture, row-major, top row first (the engine's preview buffer shape).
class PrintRaster {
  const PrintRaster({required this.width, required this.height, required this.rgba});
  final int width;
  final int height;
  final Uint8List rgba;

  bool get isEmpty => width == 0 || height == 0;
}

/// An sRGB color.
class PrintColor {
  const PrintColor(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;

  /// "#1A2B3C".
  String get hex =>
      '#${[r, g, b].map((v) => v.toRadixString(16).padLeft(2, '0')).join().toUpperCase()}';

  @override
  bool operator ==(Object other) =>
      other is PrintColor && other.r == r && other.g == g && other.b == b;

  @override
  int get hashCode => Object.hash(r, g, b);
}

/// A small vector symbol a key draws when an entry has no picture or swatch: the marks of a weaving
/// draft, drawn exactly as the draft's grids draw them.
enum PrintMark {
  /// A filled square inside its cell: a threading, tie-up, treadling or lift plan mark.
  filled,

  /// A cell filled to its edges: warp on top in a drawdown.
  solid,

  /// An empty square: weft on top in a drawdown.
  empty,

  /// A square with an X: a sinking-shed tie-up mark.
  cross,

  /// A bracket: a shot group.
  bracket,
}

/// One row of a key: the symbol as it appears on the chart (a picture of it, a color swatch, or a
/// vector mark), its [code] (the abbreviation the instructions use), a [name], and what it means.
/// Text always rides with the symbol, so the key never depends on color alone.
class PrintLegendEntry {
  const PrintLegendEntry({
    required this.code,
    required this.name,
    required this.meaning,
    this.glyph,
    this.swatch,
    this.mark,
    this.notes = const [],
  });

  final String code;
  final String name;
  final String meaning;

  /// The symbol drawn exactly as on the chart (one cell, or a cable's span).
  final PrintRaster? glyph;

  /// For a color key: the color.
  final PrintColor? swatch;

  /// A vector mark, used when there is no [glyph] or [swatch].
  final PrintMark? mark;

  /// Extra lines (how a stitch is worked on wrong-side rows, a symbol shared with another stitch).
  final List<String> notes;

  Iterable<String> get allText => [code, name, meaning, ...notes];
}

/// A key: symbols or colors with their abbreviations and meanings.
final class PrintLegend extends PrintBlock {
  const PrintLegend(this.entries);
  final List<PrintLegendEntry> entries;

  @override
  Iterable<String> get allText => entries.expand((e) => e.allText);
}

/// One line of step-by-step instructions: an optional bold [label] ("Row 1 (RS)") and its [text].
class PrintLine {
  const PrintLine(this.text, {this.label, this.flagged = false});
  final String? label;
  final String text;

  /// True when the line says it cannot be worked as authored (printed with a bar in the margin;
  /// the line's own words say what is wrong).
  final bool flagged;
}

/// Instructions, one per line, kept in order.
final class PrintLines extends PrintBlock {
  const PrintLines(this.lines);
  final List<PrintLine> lines;

  @override
  Iterable<String> get allText => lines.expand((l) => [if (l.label != null) l.label!, l.text]);
}

/// How serious a [PrintNotice] is.
enum PrintNoticeLevel {
  /// Something is wrong with the pattern (errors).
  problem,

  /// Something the reader should know before relying on the page (warnings, things the PDF cannot
  /// show exactly).
  caution,
}

/// A boxed notice: a bold [title] (which names the level in words, never color alone), an optional
/// [intro] sentence, then one bullet per line.
final class PrintNotice extends PrintBlock {
  const PrintNotice({required this.level, required this.title, this.intro, this.lines = const []});
  final PrintNoticeLevel level;
  final String title;
  final String? intro;
  final List<String> lines;

  @override
  Iterable<String> get allText => [title, if (intro != null) intro!, ...lines];
}

/// The severity of a [PrintIssue].
enum PrintIssueSeverity { error, warning, note }

/// One validation finding: severity, where it is (a row, "Notation", "Whole pattern"), and what.
class PrintIssue {
  const PrintIssue({required this.severity, required this.where, required this.message});
  final PrintIssueSeverity severity;
  final String where;
  final String message;
}

/// A table of findings; [emptyText] when there are none (an empty list is said, not left blank).
final class PrintIssues extends PrintBlock {
  const PrintIssues(this.issues, {required this.emptyText});
  final List<PrintIssue> issues;
  final String emptyText;

  @override
  Iterable<String> get allText => [
        emptyText,
        ...issues.expand((i) => [i.where, i.message])
      ];
}

/// Which gutter a chart row's number is printed in.
enum PrintSide { left, right }

/// A bracketed region of a chart (a repeat): storage columns [colStart, colEnd) on rows
/// [rowLo]..[rowHi] inclusive (row 0 at the bottom), with a short [label] ("×3", "to end").
class PrintChartBox {
  const PrintChartBox({
    required this.colStart,
    required this.colEnd,
    required this.rowLo,
    required this.rowHi,
    required this.label,
  });
  final int colStart;
  final int colEnd;
  final int rowLo;
  final int rowHi;
  final String label;
}

/// A grid chart: a [raster] of [columns] x [rows] square cells (row 0 at the BOTTOM, column 0 at the
/// left), with printed axis numbers and boxes. A chart larger than a page is split into page-sized
/// parts by the builder, each with its own numbers, never shrunk below a readable cell size.
final class PrintChart extends PrintBlock {
  PrintChart({
    required this.raster,
    required this.columns,
    required this.rows,
    required this.columnNumbers,
    required this.rowNumbers,
    required this.rowNumberSides,
    this.boxes = const [],
    this.startAtRight = false,
    required this.rowsName,
    required this.columnsName,
  })  : assert(columnNumbers.length == columns),
        assert(rowNumbers.length == rows),
        assert(rowNumberSides.length == rows);

  /// The cells, `columns * cellPx` wide and `rows * cellPx` high, top row of pixels = the TOP row.
  final PrintRaster raster;
  final int columns;
  final int rows;

  /// The number printed under each column, by storage column (left to right).
  final List<int> columnNumbers;

  /// The number printed beside each row, by storage row (bottom first).
  final List<int> rowNumbers;

  /// Which gutter each row's number goes in (knitting: right-side rows right, wrong-side left).
  final List<PrintSide> rowNumberSides;

  final List<PrintChartBox> boxes;

  /// When a chart is split across pages, the first part holds the RIGHTMOST columns (a knitting
  /// chart starts at its right edge) instead of the leftmost.
  final bool startAtRight;

  /// Names for a part's caption: "Rows 1 to 48, stitches 1 to 34".
  final String rowsName;
  final String columnsName;

  /// Raster pixels per cell.
  int get cellPx => columns == 0 ? 0 : raster.width ~/ columns;

  @override
  Iterable<String> get allText => [rowsName, columnsName, ...boxes.map((b) => b.label)];
}

/// What a vector shape is drawn with; the builder maps each to a print style.
enum PrintInk {
  /// Strong lines (a working thread).
  strong,

  /// The main accent (loops).
  accent,

  /// Light lines (skipped loops, separators).
  faint,

  /// A second accent (arrows).
  highlight,

  /// Text labels.
  label,
}

/// One vector primitive, in points, y growing DOWN from the drawing's top-left corner.
sealed class PrintShape {
  const PrintShape(this.ink);
  final PrintInk ink;
}

final class PrintVectorLine extends PrintShape {
  const PrintVectorLine(this.x1, this.y1, this.x2, this.y2, super.ink);
  final double x1, y1, x2, y2;
}

/// An arc of the ellipse centred on ([cx], [cy]) with radii [rx], [ry], from [startAngle] through
/// [sweepAngle] (radians, clockwise in y-down coordinates).
final class PrintVectorArc extends PrintShape {
  const PrintVectorArc(
      this.cx, this.cy, this.rx, this.ry, this.startAngle, this.sweepAngle, super.ink);
  final double cx, cy, rx, ry, startAngle, sweepAngle;
}

/// Text whose top-left corner is at ([x], [y]).
final class PrintVectorText extends PrintShape {
  const PrintVectorText(this.x, this.y, this.text, {this.size = 9}) : super(PrintInk.label);
  final double x, y;
  final String text;
  final double size;
}

/// A vector drawing ([width] x [height] points). A drawing wider than the page is scaled down to
/// fit when that keeps it readable, otherwise split into strips.
final class PrintDrawing extends PrintBlock {
  const PrintDrawing({
    required this.width,
    required this.height,
    required this.shapes,
    this.faded = false,
    this.label,
    this.caption,
  });
  final double width;
  final double height;
  final List<PrintShape> shapes;

  /// Drawn in lighter ink (a best-effort drawing, which [label] explains).
  final bool faded;

  /// Printed above the drawing, in bold (a warning about it).
  final String? label;

  /// Printed under the drawing.
  final String? caption;

  @override
  Iterable<String> get allText => [
        if (label != null) label!,
        if (caption != null) caption!,
        ...shapes.whereType<PrintVectorText>().map((t) => t.text),
      ];
}

/// A photo: the file's bytes (JPEG, PNG, ...), scaled to fit the page, with a [caption].
final class PrintPhoto extends PrintBlock {
  const PrintPhoto(this.bytes, {required this.caption, required this.unprintable});
  final Uint8List bytes;
  final String caption;

  /// What to print instead when the photo cannot be included (its format is not printable).
  final String unprintable;

  @override
  Iterable<String> get allText => [caption, unprintable];
}

// ---------------------------------------------------------------------------------------------------
// Weaving drafts
// ---------------------------------------------------------------------------------------------------

/// Where a printed book draft puts its tie-up. The other quadrants follow: each layout is Ply's
/// editor layout ([topRight]) reflected left to right ([mirrorX]), top to bottom ([mirrorY]), or
/// both, so every quadrant keeps sharing its axes with its neighbours (book_draft_layout.dart).
enum BookCorner {
  topRight,
  topLeft,
  bottomRight,
  bottomLeft;

  /// The tie-up is on the left: end 1 is at the left (the mirror image of Ply's editor).
  bool get mirrorX => this == topLeft || this == bottomLeft;

  /// The tie-up is at the bottom: the threading is under the drawdown and pick 1 at the bottom.
  bool get mirrorY => this == bottomRight || this == bottomLeft;
}

/// Which way a pass of the weft goes, said relative to end 1 so it reads the same in every layout
/// (the builder draws the arrow that matches the picture).
enum PrintPassDirection {
  /// Not known (no shuttle, no starting side, or after a pick with an unknown shuttle).
  unknown,

  /// The pass starts at the end 1 edge (on Ply's loom, from the right).
  fromEndOne,

  /// The pass ends at the end 1 edge (on Ply's loom, from the left).
  towardEndOne,
}

/// One pick's shuttle and pass direction, printed beside the treadling. [shuttle] null = the shuttle
/// is not recorded (printed "?").
class PrintPass {
  const PrintPass({this.shuttle, this.direction = PrintPassDirection.unknown});
  final int? shuttle;
  final PrintPassDirection direction;
}

/// A bracket beside the treadling over the book draft's rows [start, end) (0-based rows of the
/// block), with a short [label] ("double shot").
class PrintRowBracket {
  const PrintRowBracket({required this.start, required this.end, required this.label});
  final int start;
  final int end;
  final String label;
}

/// A four-quadrant BOOK DRAFT: threading, tie-up (none for a lift plan), treadling or lift plan, and
/// the structural drawdown, on one shared cell pitch, with axis numbers on every part and the margin
/// annotations beside the treadling (role letters, shuttle and pass, shot-group brackets) and the
/// edge labels under the drawdown. Every quadrant is plain data: the builder only draws it. A draft
/// too large for a page is split into page-sized parts, each repeating the threading for its ends, the
/// treadling for its rows, the tie-up and the numbers; cells are never shrunk below a readable size.
final class PrintBookDraft extends PrintBlock {
  PrintBookDraft({
    required this.ends,
    required this.shafts,
    required this.columns,
    required this.threading,
    required this.tieup,
    this.tieupMark = PrintMark.filled,
    required this.treadling,
    required this.pickNumbers,
    this.drawdown,
    this.corner = BookCorner.topRight,
    this.roles = const [],
    this.passes = const [],
    this.brackets = const [],
    this.highEndEdge,
    this.endOneEdge,
    this.rowsNote,
  })  : assert(threading.length == ends),
        assert(tieup == null || tieup.length == columns),
        assert(pickNumbers.length == treadling.length),
        assert(drawdown == null || drawdown.length == ends * treadling.length),
        assert(roles.isEmpty || roles.length == treadling.length),
        assert(passes.isEmpty || passes.length == treadling.length);

  /// Warp ends (threading and drawdown columns).
  final int ends;

  /// Shafts (threading and tie-up rows).
  final int shafts;

  /// Tie-up and treadling columns: treadles, or shafts for a lift plan.
  final int columns;

  /// Per end (index 0 = end 1), the 1-based shafts it is threaded on.
  final List<List<int>> threading;

  /// Per treadle (index 0 = treadle 1), the 1-based shafts it is tied to; null for a lift plan, whose
  /// tie-up corner stays empty.
  final List<List<int>>? tieup;

  /// How a tie-up mark is drawn: [PrintMark.filled] (the shaft rises) or [PrintMark.cross] (sinks).
  final PrintMark tieupMark;

  /// Per row, the 1-based columns marked (treadles pressed, or shafts raised).
  final List<List<int>> treadling;

  /// Per row, the pick number printed beside it (a pattern-only grid skips the tabby picks' numbers).
  final List<int> pickNumbers;

  /// The interlacement from the engine: `rows * ends` entries, row-major, end index 0 first; 1 = the
  /// warp is on top (drawn black). Null when it could not be drawn (the cells stay empty).
  final Uint8List? drawdown;

  final BookCorner corner;

  /// Per row, a role letter ("" for none); empty = no role column.
  final List<String> roles;

  /// Per row, the shuttle and pass; empty = no shuttle column.
  final List<PrintPass> passes;

  final List<PrintRowBracket> brackets;

  /// Labels for the drawdown's two edges: the edge at the highest end (on Ply's loom the weaver's
  /// left) and the edge at end 1 (the weaver's right). Null = no label.
  final String? highEndEdge;
  final String? endOneEdge;

  /// Added to every part's caption ("pattern picks only").
  final String? rowsNote;

  int get rows => treadling.length;
  bool get isLiftplan => tieup == null;

  @override
  Iterable<String> get allText => [
        ...roles,
        for (final b in brackets) b.label,
        if (highEndEdge != null) highEndEdge!,
        if (endOneEdge != null) endOneEdge!,
        if (rowsNote != null) rowsNote!,
        if (passes.isNotEmpty) '?←→',
      ];
}

/// The COLORED drawdown: every crossing in the color of the thread on top, as the engine draws it,
/// with the warp colors in a band along the threading side and the weft colors along the treadling
/// side. Every end and pick is one square (yarn thickness is not drawn). Split into page-sized parts
/// like a book draft.
final class PrintColorDrawdown extends PrintBlock {
  PrintColorDrawdown({
    required this.ends,
    required this.picks,
    required this.cells,
    required this.warp,
    required this.weft,
    this.corner = BookCorner.topRight,
  })  : assert(cells.length == ends * picks),
        assert(warp.length == ends),
        assert(weft.length == picks);

  final int ends;
  final int picks;

  /// `picks * ends` colors as 0xRRGGBB, row-major, end index 0 first.
  final Uint32List cells;

  /// Per end and per pick, the band color.
  final List<PrintColor> warp;
  final List<PrintColor> weft;

  /// The same layout as the book draft, so end 1 and pick 1 sit on the same sides.
  final BookCorner corner;

  @override
  Iterable<String> get allText => const [];
}
