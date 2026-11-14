// The printable-document MODEL (M9-02): what a printed pattern says, independent of any craft and of
// the PDF library. A craft builds a [PrintDocument] from its own data (knit_print.dart,
// nalbind_print.dart; weaving next), and `pdf_builder.dart` lays it out on pages. Keeping the model
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

/// One row of a key: the symbol as it appears on the chart (a picture of it, or a color swatch), its
/// [code] (the abbreviation the instructions use), a [name], and what it means. Text always rides
/// with the symbol, so the key never depends on color alone.
class PrintLegendEntry {
  const PrintLegendEntry({
    required this.code,
    required this.name,
    required this.meaning,
    this.glyph,
    this.swatch,
    this.notes = const [],
  });

  final String code;
  final String name;
  final String meaning;

  /// The symbol drawn exactly as on the chart (one cell, or a cable's span).
  final PrintRaster? glyph;

  /// For a color key: the color.
  final PrintColor? swatch;

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
