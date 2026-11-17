// Host-test support for tablet weaving (M10-02): no FFI. The real fixtures are read as plain JSON:
// a `.plytab` document (`fixtures/tablet/documents/`) becomes the editor's document DTO, and an
// oracle's hand-worked tables (`fixtures/tablet/oracle/<name>.expect.json`, transcribed from ADR 0018,
// never from the engine) become the window DTOs a fake repository serves, so the editor is checked
// against the ADR's own numbers.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ply/src/data/tablet_repository.dart';
import 'package:ply/src/models/draft_meta.dart';
import 'package:ply/src/models/native_format.dart';
import 'package:ply/src/rust/tablet_dto.dart';

String fixtureText(String rel) => File('../fixtures/tablet/$rel').readAsStringSync();

TabletHoleKind holeOf(String s) => switch (s) {
      'A' => TabletHoleKind.a,
      'B' => TabletHoleKind.b,
      'C' => TabletHoleKind.c,
      'D' => TabletHoleKind.d,
      _ => throw ArgumentError('hole $s'),
    };

TabletArrangementDto arrangementOf(Map<String, dynamic> a) => TabletArrangementDto(
      nearTop: holeOf(a['near_top'] as String),
      farTop: holeOf(a['far_top'] as String),
      farBottom: holeOf(a['far_bottom'] as String),
      nearBottom: holeOf(a['near_bottom'] as String),
    );

/// A `.plytab` file's document as the bridge would hand it over (read here as JSON, no FFI).
TabletDocumentDto documentFromPlytab(String text) {
  final env = jsonDecode(text) as Map<String, dynamic>;
  final d = env['document'] as Map<String, dynamic>;
  int? idx(Object? v) => v as int?;
  return TabletDocumentDto(
    name: d['name'] as String,
    notes: d['notes'] as String,
    palette: [
      for (final h in d['palette'] as List)
        TabletColorDto(
          r: int.parse((h as String).substring(1, 3), radix: 16),
          g: int.parse(h.substring(3, 5), radix: 16),
          b: int.parse(h.substring(5, 7), radix: 16),
        ),
    ],
    weft: idx(d['weft']),
    cards: [
      for (final c in d['cards'] as List)
        TabletCardDto(
          id: c['id'] as String,
          a: idx(c['threads']['A']),
          b: idx(c['threads']['B']),
          c: idx(c['threads']['C']),
          d: idx(c['threads']['D']),
          threading: c['threading'] == 'S' ? TabletThreadingKind.s : TabletThreadingKind.z,
          start: arrangementOf(c['start'] as Map<String, dynamic>),
        ),
    ],
    packs: [
      for (final p in (d['packs'] as List?) ?? const [])
        TabletPackDto(
          id: p['id'] as String,
          name: p['name'] as String,
          cards: [for (final c in p['cards'] as List) c as String],
        ),
    ],
    turning: [
      for (final s in d['turning'] as List)
        TabletSegmentDto(
          repeat: s['repeat'] as int,
          picks: [
            for (final p in s['picks'] as List)
              TabletPickDto(
                turns: p['turns'] as String,
                releaseTwist: [
                  for (final c in (p['release_twist'] as List?) ?? const []) c as String
                ],
                flip: [for (final c in (p['flip'] as List?) ?? const []) c as String],
                unsupported: [
                  for (final e in ((p['unsupported'] as Map?) ?? const {}).entries)
                    TabletWordsDto(card: e.key as String, text: e.value as String),
                ],
                note: null,
                weft: idx(p['weft']),
              ),
          ],
        ),
    ],
    settings: TabletSettingsDto(
      twistWarningQuarters: d['settings']['twist_warning_quarters'] as int,
      floatWarningPicks: d['settings']['float_warning_picks'] as int,
    ),
  );
}

TabletDocumentDto oracleDocument(String name) =>
    documentFromPlytab(fixtureText('documents/$name.plytab'));

/// The oracle's per-card, per-pick table as window cells.
class Oracle {
  Oracle(String name)
      : _exp = jsonDecode(fixtureText('oracle/$name.expect.json')) as Map<String, dynamic>,
        doc = oracleDocument(name);

  final Map<String, dynamic> _exp;
  final TabletDocumentDto doc;

  int get picks => _exp['picks'] as int;
  List<String> get letters => [for (final l in _exp['palette_letters'] as List) l as String];

  Map<String, dynamic> entry(int card, int pick) =>
      ((_exp['cards'] as List)[card]['picks'] as List)[pick - 1] as Map<String, dynamic>;

  TabletFaceThreadDto _face(String hole, String color) {
    int? colorOf(String l) => l == 'none' ? null : letters.indexOf(l);
    if (hole == 'unknown') return const TabletFaceThreadDto(kind: TabletFaceThreadKind.unknown);
    if (hole.contains(' or ')) {
      final h = hole.split(' or ');
      final c = color.split(' or ');
      return TabletFaceThreadDto(
        kind: TabletFaceThreadKind.ambiguous,
        hole: holeOf(h[0]),
        secondHole: holeOf(h[1]),
        color: colorOf(c[0]),
        secondColor: colorOf(c[1]),
      );
    }
    final h = holeOf(hole.substring(0, 1));
    if (hole.endsWith('empty')) {
      return TabletFaceThreadDto(kind: TabletFaceThreadKind.empty, hole: h);
    }
    final continued = hole.endsWith('continues');
    return TabletFaceThreadDto(
      kind: continued ? TabletFaceThreadKind.continued : TabletFaceThreadKind.thread,
      hole: h,
      color: colorOf(color.split(' ').first),
    );
  }

  TabletCardPickDto cell(int card, int pick) {
    final e = entry(card, pick);
    final pos = (e['position'] as String?)?.split(' ');
    return TabletCardPickDto(
      turn: switch (e['turn']) {
        'F' => TabletTurnKind.forward,
        'B' => TabletTurnKind.backward,
        'I' => TabletTurnKind.idle,
        _ => TabletTurnKind.unsupported,
      },
      released: e['released'] as bool,
      flipped: e['flipped'] as bool,
      position: pos == null
          ? null
          : TabletArrangementDto(
              nearTop: holeOf(pos[0]),
              farTop: holeOf(pos[1]),
              farBottom: holeOf(pos[2]),
              nearBottom: holeOf(pos[3])),
      threading: switch (e['threading']) {
        'S' => TabletThreadingKind.s,
        'Z' => TabletThreadingKind.z,
        _ => null,
      },
      top: _face(e['top'] as String, e['top_color'] as String),
      back: _face(e['back'] as String, e['back_color'] as String),
      twining: switch (e['twining']) {
        'S' => TabletTwiningKind.s,
        'Z' => TabletTwiningKind.z,
        _ => null,
      },
      reversal: e['reversal'] as bool,
      twist: e['twist'] as int?,
      woven: e['woven'] as int?,
    );
  }

  TabletWindowDto window(int first, int last) {
    final cards = doc.cards.length;
    return TabletWindowDto(
      firstPick: first,
      lastPick: last,
      cards: cards,
      rows: [
        for (var p = first; p <= last; p++)
          TabletPickInfoDto(pick: p, segment: 1, step: 1, repeat: 1, allIdle: false),
      ],
      cells: [
        for (var p = first; p <= last; p++)
          for (var c = 0; c < cards; c++) cell(c, p),
      ],
      reviewPending: true,
    );
  }
}

/// An empty report (or one with [diagnostics]), review pending.
TabletReportDto reportWith(List<TabletDiagnosticDto> diagnostics, {int? picks}) {
  int count(TabletSeverityKind s) => diagnostics.where((d) => d.severity == s).length;
  return TabletReportDto(
    diagnostics: diagnostics,
    expandedPicks: picks,
    errors: count(TabletSeverityKind.error),
    warnings: count(TabletSeverityKind.warning),
    unsupported: count(TabletSeverityKind.unsupported),
    infos: count(TabletSeverityKind.info),
    reviewPending: true,
    rulesVersion: 1,
  );
}

TabletLocationDto location(TabletLocationKind kind,
        {int? card,
        int? pick,
        int? segment,
        int? step,
        List<int> cards = const [],
        int? firstPick,
        int? lastPick,
        TabletHoleKind? hole,
        TabletFaceKind? face}) =>
    TabletLocationDto(
      kind: kind,
      card: card,
      hole: hole,
      cards: Uint32List.fromList(cards),
      cardsTotal: cards.length,
      packs: Uint32List(0),
      packsTotal: 0,
      listings: 0,
      segment: segment,
      step: step,
      pick: pick,
      face: face,
      firstPick: firstPick,
      lastPick: lastPick,
      omittedCount: 0,
    );

TabletDiagnosticDto diagnostic(
        String code, TabletSeverityKind severity, String message, TabletLocationDto location,
        {String? remediation}) =>
    TabletDiagnosticDto(
        code: code,
        severity: severity,
        location: location,
        message: message,
        remediation: remediation);

Future<ui.Image> onePixelImage() {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
      Uint8List.fromList(const [0, 0, 0, 255]), 1, 1, ui.PixelFormat.rgba8888, completer.complete);
  return completer.future;
}

/// A repository with no FFI: the engine calls answer from an [Oracle] (or canned values), and the
/// persistence calls are recorded instead of touching disk.
class FakeTabletRepo extends TabletRepository {
  FakeTabletRepo({this.oracle, TabletReportDto? report, this.stored})
      : report = report ?? reportWith(const []);

  final Oracle? oracle;
  TabletReportDto report;

  /// What [readBand] returns.
  TabletDocumentDto? stored;
  Object? readError;

  int saves = 0;
  TabletDocumentDto? savedDoc;
  DraftMeta? savedMeta;
  String? savedId;
  NativeFormatException? refuseNextSave;
  final List<(int, int)> windows = [];

  @override
  Future<TabletReportDto> validate(TabletDocumentDto doc) async => report;

  @override
  Future<bool> reviewPending() async => true;

  @override
  Future<int> schemaVersion() async => 1;

  @override
  Future<int?> documentVersion(String text) async => plytabSchemaVersion(text);

  /// When set, every window throws it (a band the engine refuses).
  Object? windowError;

  @override
  Future<List<TabletCheckpointDto>> checkpoints(TabletDocumentDto doc) async => const [];

  @override
  Future<TabletWindowDto> window(TabletDocumentDto doc, int first, int last,
      {TabletCheckpointDto? checkpoint}) async {
    windows.add((first, last));
    final e = windowError;
    if (e != null) throw e;
    final o = oracle;
    if (o == null) throw StateError('no oracle');
    return o.window(first, last);
  }

  @override
  Future<TabletRasterDto> renderFace(TabletDocumentDto doc, int first, int last,
          {required TabletFaceKind face,
          required int cellPx,
          bool letters = false,
          TabletCheckpointDto? checkpoint}) async =>
      TabletRasterDto(
        width: doc.cards.length * cellPx,
        height: (last - first + 1) * cellPx,
        cellPx: cellPx,
        firstPick: first,
        lastPick: last,
        cards: doc.cards.length,
        rgba: Uint8List(0),
        reviewPending: true,
      );

  @override
  Future<ui.Image> decode(TabletRasterDto r) => onePixelImage();

  @override
  Future<TabletDocumentDto> readBand(String id) async {
    final e = readError;
    if (e != null) throw e;
    return stored ?? oracle!.doc;
  }

  @override
  Future<TabletEntry> openBand(String id) async => TabletEntry(
        id: id,
        meta: DraftMeta(
            name: 'Saved band',
            craft: kTabletCraft,
            savedAt: DateTime.utc(2026, 11, 16),
            lastOpened: DateTime.utc(2026, 11, 16)),
        bandPath: '/nowhere/$id.plytab',
      );

  @override
  Future<String> saveBand(
      {required TabletDocumentDto doc, required DraftMeta meta, String? id}) async {
    saves++;
    final refusal = refuseNextSave;
    if (refusal != null) {
      refuseNextSave = null;
      throw refusal;
    }
    savedDoc = doc;
    savedMeta = meta;
    savedId = id;
    return id ?? 'new-band';
  }
}
