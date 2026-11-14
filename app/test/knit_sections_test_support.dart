import 'dart:convert';
import 'dart:io';

import 'package:ply/src/models/knit_sections.dart';
import 'package:ply/src/rust/dto.dart' show ColorDto, SeverityKind, UnitKind;
import 'package:ply/src/rust/knit_dto.dart';

// Host-side helpers for the knitting section tests. Host tests cannot load the engine, so this reads
// a `.plyknit` file's document (the engine's serde shape, schema version 4) straight into the bridge
// DTOs, and rebuilds the engine's construction result from a fixture's hand-derived oracle. Reading
// every field of the shared fixtures this way also proves the Dart DTOs can carry each of them.

/// The section acceptance fixtures (repo-root `fixtures/knitting/sections/`, shared with Rust).
const List<String> kSectionFixtures = [
  'shoulder-short-rows-flat',
  'neckline-hold-flat',
  'ledger-problems-flat',
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
          steps: [
            for (final st in s['steps'] as List)
              KnitStepDto(id: st['id'] as String, action: _action(st['action'])),
          ],
        ),
    ],
  );
}

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
      return KnitStepActionDto.shortRow(
        stitch: _stitch(v['stitch'] as String),
        to: to.containsKey('Last')
            ? TurnAtDto.last(count: to['Last'] as int)
            : TurnAtDto.count(count: to['Count'] as int),
        method: switch (v['method']) {
          'WrapAndTurn' => TurnMethodKind.wrapAndTurn,
          'German' => TurnMethodKind.german,
          _ => TurnMethodKind.unspecified,
        },
        resolveTurns: v['resolve_turns'] as bool,
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
  }
  throw FormatException('a step kind this build does not know: $kind');
}

/// A written line's row label, as the engine writes them.
final _label = RegExp(r'^(Row \d+ \((?:RS|WS)\)|Round \d+|Short row \d+(?: \((?:RS|WS)\))?'
    r'|Next row(?: \((?:RS|WS)\))?|Not checked by Ply): (.*)$');

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
  final lines = <KnitLedgerLineDto>[];
  for (final s in oracle['steps'] as List) {
    final si = titles.indexOf(s['section'] as String);
    final ti = (s['step'] as int) - 1;
    final count = s['count'];
    final written = s['line'] as String;
    final open = written.lastIndexOf(' (');
    final labelled = _label.firstMatch(written.substring(0, open));
    lines.add(KnitLedgerLineDto(
      sectionId: p.sections[si].id,
      stepId: p.sections[si].steps[ti].id,
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
                  KnitHeldCountDto(hold: '', name: h[0] as String, count: h[1] as int),
              ],
              boundOff: count['bound_off'] as int,
              side: switch (count['side']) {
                'RS' => SideKind.rs,
                'WS' => SideKind.ws,
                _ => null,
              },
            )
          : null,
      countText: written.substring(open + 2, written.length - 1),
      written: written,
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
      sectionId: p.sections[si].id,
      stepId: ti == null ? null : p.sections[si].steps[ti].id,
      sectionIndex: si,
      stepIndex: ti,
      chartRow: m.group(3) == null ? null : int.parse(m.group(3)!),
      text: m.group(4)!,
      message: i.message,
    ));
  }
  return KnitConstructionDto(lines: lines, issues: issues);
}
