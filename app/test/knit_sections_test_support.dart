import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ply/src/models/knit_sections.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto, SeverityKind, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';

// Host-side helpers for the knitting section tests. Host tests cannot load the engine, so this reads
// a `.plyknit` file's document (the engine's serde shape, schema version 6) straight into the bridge
// DTOs, and rebuilds the engine's construction result from a fixture's hand-derived oracle. Reading
// every field of the shared fixtures this way also proves the Dart DTOs can carry each of them.

/// The section acceptance fixtures (repo-root `fixtures/knitting/sections/`, shared with Rust).
const List<String> kSectionFixtures = [
  'shoulder-short-rows-flat',
  'neckline-hold-flat',
  'ledger-problems-flat',
  'sock-heel-flap-round',
  'sock-short-row-heel-round',
  'round-problems',
  'mitten-thumb-round',
  'yoke-sweater-round',
  'pieces-problems',
  'raglan-top-down-round',
];

String sectionFixtureText(String name, String ext) =>
    File('../fixtures/knitting/sections/$name.$ext').readAsStringSync();

Map<String, dynamic> sectionOracle(String name) =>
    jsonDecode(sectionFixtureText(name, 'expect.json')) as Map<String, dynamic>;

/// The pattern in a current `.plyknit` envelope, as the bridge would hand it to the app.
KnitPatternDto patternFromPlyknit(String text) {
  final env = jsonDecode(text) as Map<String, dynamic>;
  final d = env['document'] as Map<String, dynamic>;
  final gauge = d['gauge'] as Map<String, dynamic>;
  final chart = d['chart'] as Map<String, dynamic>;
  return KnitPatternDto(
    name: d['name'] as String,
    construction: d['construction'] == 'Flat' ? ConstructionKind.flat : ConstructionKind.inTheRound,
    firstRowSide: _side(d['first_row_side'] as String)!,
    castOn: d['cast_on'] as int?,
    gauge: GaugeDto(
      sts: (gauge['sts'] as num).toDouble(),
      rows: (gauge['rows'] as num).toDouble(),
      unit: gauge['unit'] == 'Inches' ? UnitKind.inches : UnitKind.centimeters,
    ),
    palette: [
      for (final c in d['palette'] as List)
        ColorDto(r: c['r'] as int, g: c['g'] as int, b: c['b'] as int),
    ],
    legend: StitchLegendDto(stitches: [
      for (final s in (d['legend'] as Map)['stitches'] as List)
        StitchDefDto(
          symbol: s['symbol'] as String,
          consumes: s['consumes'] as int,
          produces: s['produces'] as int,
          wsVariant: s['ws_variant'] as int?,
          cable: s['cable'] == null
              ? null
              : CableDefDto(
                  front: s['cable']['front'] as int,
                  back: s['cable']['back'] as int,
                  direction: s['cable']['direction'] == 'Right' ? CrossKind.right : CrossKind.left,
                  frontPurl: s['cable']['front_purl'] as bool,
                  backPurl: s['cable']['back_purl'] as bool,
                ),
          macroRows: s['macro_rows'] as int,
        ),
    ]),
    chart: ChartDto(
      width: chart['width'] as int,
      rows: [
        for (final r in chart['rows'] as List)
          RowDto(
            cells: [
              for (final c in r['cells'] as List)
                CellDto(stitch: c['stitch'] as int, color: c['color'] as int?),
            ],
            repeats: [
              for (final sp in r['repeats'] as List)
                RepeatSpanDto(
                  start: sp['start'] as int,
                  end: sp['end'] as int,
                  count: sp['count'] == 'ToEnd'
                      ? const RepeatDto.toEnd()
                      : RepeatDto.times(count: (sp['count'] as Map)['Times'] as int),
                ),
            ],
          ),
      ],
    ),
    notes: d['notes'] as String,
    sections: [
      for (final s in d['sections'] as List)
        KnitSectionDto(
          id: s['id'] as String,
          name: s['name'] as String,
          notes: s['notes'] as String,
          construction: _construction(s['construction'] as String?),
          piece: s['piece'] as String?,
          steps: [
            for (final st in s['steps'] as List)
              KnitStepDto(id: st['id'] as String, action: _action(st['action'])),
          ],
        ),
    ],
    pieces: [
      for (final x in d['pieces'] as List? ?? const [])
        KnitPieceDto(id: x['id'] as String, name: x['name'] as String),
    ],
  );
}

ConstructionKind? _construction(String? c) => switch (c) {
      'Flat' => ConstructionKind.flat,
      'InTheRound' => ConstructionKind.inTheRound,
      _ => null,
    };

SideKind? _side(String? s) => switch (s) {
      'Rs' => SideKind.rs,
      'Ws' => SideKind.ws,
      _ => null,
    };

WorkStitchKind _stitch(String s) => switch (s) {
      'Knit' => WorkStitchKind.knit,
      'Purl' => WorkStitchKind.purl,
      _ => WorkStitchKind.inPattern,
    };

KnitStepActionDto _action(Object? json) {
  if (json is! Map || json.length != 1) throw FormatException('not a step action: $json');
  final kind = json.keys.single as String;
  final v = json[kind] as Map<String, dynamic>;
  switch (kind) {
    case 'ChartRows':
      return KnitStepActionDto.chartRows(first: v['first'] as int, last: v['last'] as int);
    case 'Work':
      final to = v['to'];
      return KnitStepActionDto.work(
        stitch: _stitch(v['stitch'] as String),
        to: to == 'End'
            ? const WorkToDto.end()
            : (to as Map).containsKey('Last')
                ? WorkToDto.last(count: to['Last'] as int)
                : WorkToDto.count(count: to['Count'] as int),
        resolveTurns: v['resolve_turns'] as bool,
      );
    case 'ShortRow':
      final to = v['to'] as Map;
      final dec = v['decrease'] as Map?;
      return KnitStepActionDto.shortRow(
        stitch: _stitch(v['stitch'] as String),
        to: switch (to.keys.single) {
          'Last' => TurnAtDto.last(count: to['Last'] as int),
          'Count' => TurnAtDto.count(count: to['Count'] as int),
          'BeforeGap' => TurnAtDto.beforeGap(count: to['BeforeGap'] as int),
          _ => TurnAtDto.pastGap(count: to['PastGap'] as int),
        },
        method: switch (v['method']) {
          'WrapAndTurn' => TurnMethodKind.wrapAndTurn,
          'German' => TurnMethodKind.german,
          _ => TurnMethodKind.unspecified,
        },
        resolveTurns: v['resolve_turns'] as bool,
        decrease: dec == null
            ? null
            : TurnDecreaseDto(
                kind: switch (dec['kind']) {
                  'K2tog' => DecreaseKind.k2Tog,
                  'Ssk' => DecreaseKind.ssk,
                  'P2tog' => DecreaseKind.p2Tog,
                  _ => DecreaseKind.ssp,
                },
                after: dec['after'] as int),
      );
    case 'CastOn':
      return KnitStepActionDto.castOn(count: v['count'] as int);
    case 'BindOff':
      return KnitStepActionDto.bindOff(
          count: v['count'] as int?, resolveTurns: v['resolve_turns'] as bool);
    case 'Hold':
      return KnitStepActionDto.hold(count: v['count'] as int?, name: v['name'] as String);
    case 'Resume':
      return KnitStepActionDto.resume(
          hold: v['hold'] as String, facing: _side(v['facing'] as String?));
    case 'Opaque':
      return KnitStepActionDto.opaque(
          text: v['text'] as String, stitchChange: v['stitch_change'] as int?);
    case 'JoinRound':
      return const KnitStepActionDto.joinRound();
    case 'RoundStart':
      return const KnitStepActionDto.roundStart();
    case 'WorkFlat':
      return KnitStepActionDto.workFlat(
          count: v['count'] as int, name: v['name'] as String, slipEdges: v['slip_edges'] as bool);
    case 'Rows':
      return KnitStepActionDto.rows(count: v['count'] as int, text: v['text'] as String);
    case 'Shape':
      final until = v['until'] as Map;
      return KnitStepActionDto.shape(
        change: v['change'] as int,
        every: v['every'] as int,
        until: until.containsKey('Times')
            ? ShapeUntilDto.times(count: until['Times'] as int)
            : ShapeUntilDto.remain(count: until['Remain'] as int),
        groups: [for (final g in v['groups'] as List) g as String],
        text: v['text'] as String,
      );
    case 'PickUp':
      final along = v['along'] as Map;
      return KnitStepActionDto.pickUp(
        count: v['count'] as int,
        along: along.containsKey('Piece')
            ? PickUpAlongDto.piece(step: along['Piece'] as String)
            : PickUpAlongDto.edge(text: along['Edge'] as String),
        group: v['group'] as String?,
      );
    case 'Groups':
      return KnitStepActionDto.groups(groups: [
        for (final g in v['groups'] as List)
          NeedleGroupDto(
              name: g['name'] as String, count: g['count'] as int, notes: g['notes'] as String),
      ]);
    case 'Close':
      return KnitStepActionDto.close(
          method:
              v['method'] == 'Graft' ? CloseMethodKind.graft : CloseMethodKind.threeNeedleBindOff,
          holds: [for (final h in v['holds'] as List? ?? const []) h as String]);
    case 'Join':
      final source = v['source'] as Map;
      return KnitStepActionDto.join(
        source: source.containsKey('Piece')
            ? JoinSourceDto.piece(piece: source['Piece'] as String)
            : JoinSourceDto.held(hold: source['Held'] as String),
        stitch: _stitch(v['stitch'] as String),
        resolveTurns: v['resolve_turns'] as bool,
      );
  }
  throw FormatException('a step kind this build does not know: $kind');
}

/// A written line's row label, as the engine writes them.
final _label = RegExp(r'^(Row \d+ \((?:RS|WS)\)|Round \d+|Short row \d+(?: \((?:RS|WS)\))?'
    r'|Next row(?: \((?:RS|WS)\))?|Next rnd|Next \d+ rows(?: \(first row (?:RS|WS)\))?'
    r'|Next \d+ rnds|Not checked by Ply): (.*)$');

/// The engine's validation of a fixture, from its oracle.
List<KnitIssueDto> oracleIssues(Map<String, dynamic> oracle) => [
      for (final i in oracle['issues'] as List)
        KnitIssueDto(
          severity: i['severity'] == 'error' ? SeverityKind.error : SeverityKind.warning,
          message: i['message'] as String,
        ),
    ];

/// The engine's construction result for [p], rebuilt from its oracle: every ledger line, and every
/// ledger problem placed by section and step id (problems that are about a chart row's drawn
/// repeats come from validation alone and start "row N:", so they are not ledger problems).
KnitConstructionDto oracleConstruction(KnitPatternDto p, Map<String, dynamic> oracle) {
  final titles = [for (var i = 0; i < p.sections.length; i++) knitSectionTitle(p, i)];
  final pieceTitles = [for (var i = 0; i < p.pieces.length; i++) knitPieceTitle(p, i)];
  // The construction's tables, as the engine fills them: the hold steps (by the oracle's group
  // names, each the first hold step with that name) and the needle group names.
  final holds = <KnitHoldNameDto>[];
  final groupNames = <String>[];
  int holdIndex(String name) {
    final i = holds.indexWhere((h) => h.name == name);
    if (i >= 0) return i;
    for (var si = 0; si < p.sections.length; si++) {
      for (var ti = 0; ti < p.sections[si].steps.length; ti++) {
        if (p.sections[si].steps[ti].action case KnitStepActionDto_Hold(name: final n)
            when n == name) {
          holds.add(KnitHoldNameDto(
              holdStepId: p.sections[si].steps[ti].id,
              sectionIndex: si,
              stepIndex: ti,
              name: name));
          return holds.length - 1;
        }
      }
    }
    holds.add(KnitHoldNameDto(holdStepId: '', sectionIndex: 0, stepIndex: 0, name: name));
    return holds.length - 1;
  }

  int groupIndex(String name) {
    final i = groupNames.indexOf(name);
    if (i >= 0) return i;
    groupNames.add(name);
    return groupNames.length - 1;
  }

  final lines = <KnitLedgerLineDto>[];
  for (final s in oracle['steps'] as List) {
    final si = titles.indexOf(s['section'] as String);
    final ti = (s['step'] as int) - 1;
    final count = s['count'];
    final written = s['line'] as String;
    final open = written.lastIndexOf(' (');
    final labelled = _label.firstMatch(written.substring(0, open));
    lines.add(KnitLedgerLineDto(
      sectionIndex: si,
      stepIndex: ti,
      chartRow: s['chart_row'] as int?,
      label: labelled?.group(1),
      text: labelled?.group(2) ?? written.substring(0, open),
      opaque: written.startsWith('Not checked by Ply: '),
      countKind: switch (count) {
        'unknown' => KnitLineCountKind.unknown,
        'not counted' => KnitLineCountKind.notCounted,
        _ => KnitLineCountKind.counted,
      },
      count: count is Map
          ? KnitNeedleCountDto(
              onNeedle: count['on_needle'] as int,
              toWork: count['to_work'] as int,
              midRow: count['mid_row'] as bool,
              pastTurns: count['past_turns'] as int,
              pendingTurns: count['pending_turns'] as int,
              held: [
                for (final h in count['held'] as List)
                  KnitHeldCountDto(holdIndex: holdIndex(h[0] as String), count: h[1] as int),
              ],
              boundOff: count['bound_off'] as int,
              side: switch (count['side']) {
                'RS' => SideKind.rs,
                'WS' => SideKind.ws,
                _ => null,
              },
              // Added for work in the round; the first slice's oracles leave them out.
              inRound: count['in_round'] as bool? ?? false,
              groups: [
                for (final g in count['groups'] as List? ?? const [])
                  KnitGroupCountDto(nameIndex: groupIndex(g[0] as String), count: g[1] as int),
              ],
              flat: count['flat'] as int?,
              grafted: count['grafted'] as int? ?? 0,
              // Added for several pieces; older oracles leave it out.
              setAside: [
                for (final a in count['set_aside'] as List? ?? const [])
                  KnitPieceCountDto(
                    pieceIndex: pieceTitles.indexOf(a[0] as String),
                    count: a[1] as int?,
                  ),
              ],
              boundOffTotal: count['bound_off_total'] as int? ?? count['bound_off'] as int,
              graftedTotal: count['grafted_total'] as int? ?? count['grafted'] as int? ?? 0,
            )
          : null,
      countText: written.substring(open + 2, written.length - 1),
      written: written,
      pieceIndex: s['piece'] == null ? null : pieceTitles.indexOf(s['piece'] as String),
    ));
  }
  final place = RegExp(r'^(.+?)(?:, step (\d+))?(?:, chart row (\d+))?: (.*)$');
  final issues = <KnitSectionIssueDto>[];
  for (final i in oracleIssues(oracle)) {
    if (RegExp(r'^row \d+').hasMatch(i.message)) continue; // validation of the drawn chart only
    final m = place.firstMatch(i.message);
    final si = m == null ? -1 : titles.indexOf(m.group(1)!);
    if (si < 0) {
      issues.add(KnitSectionIssueDto(severity: i.severity, text: i.message, message: i.message));
      continue;
    }
    final step = m!.group(2);
    final ti = step == null ? null : int.parse(step) - 1;
    issues.add(KnitSectionIssueDto(
      severity: i.severity,
      sectionIndex: si,
      stepIndex: ti,
      chartRow: m.group(3) == null ? null : int.parse(m.group(3)!),
      text: m.group(4)!,
      message: i.message,
    ));
  }
  // How each piece ends: the oracle's words (`joined to the body at ...` names where).
  final pieces = <KnitPieceSummaryDto>[];
  final summaries = oracle['pieces'] as List? ?? const [];
  for (var i = 0; i < summaries.length; i++) {
    final text = summaries[i][1] as String;
    final sections = [
      for (var si = 0; si < p.sections.length; si++)
        if (knitSectionPieceIndex(p, si) == i) si,
    ];
    pieces.add(KnitPieceSummaryDto(
      id: p.pieces[i].id,
      name: p.pieces[i].name,
      index: i,
      sectionIndices: Uint32List.fromList(sections),
      live: RegExp(r'^(\d+) sts? left').firstMatch(text) == null
          ? (text.startsWith('no stitches') || text.startsWith('joined') ? 0 : null)
          : int.parse(RegExp(r'^(\d+)').firstMatch(text)!.group(1)!),
      text: text,
    ));
  }
  return KnitConstructionDto(
      lines: lines, issues: issues, pieces: pieces, holds: holds, groupNames: groupNames);
}
