// M7-05 device proof: READY TO MAKE OR SHARE (ADR 0021) against the REAL engine. The three
// readiness acceptance fixtures (one per craft, with a deliberate mix of problems) go through the
// engine's readiness calls and must give exactly their oracles' checks, codes, severities and
// places; then each craft's print flow runs on the device's own editor or project screen with a
// recording output (no system dialog): the pattern is not ready, the default goes back and makes
// nothing, a draft copy is made only when chosen and is named and marked as one on every page.
//
// The fixtures and the oracles' items are embedded (a device test cannot read the repo's files);
// they are the tracked files fixtures/weaving/readiness/mixed-problems.*,
// fixtures/knitting/readiness/ mixed-problems.* and fixtures/nalbinding/readiness/mixed-problems.*,
// copied verbatim (the WIF with its CRLF line ends restored below).
//
//   flutter test integration_test/m7_ready_to_make_test.dart -d emulator-5554

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdf/pdf.dart' show PdfPageFormat;

import 'package:ply/src/data/draft_repository.dart';
import 'package:ply/src/data/knit_repository.dart';
import 'package:ply/src/data/readiness_repository.dart';
import 'package:ply/src/models/draft_doc.dart' show MeasureUnit;
import 'package:ply/src/models/loom_profile.dart';
import 'package:ply/src/models/loom_type.dart';
import 'package:ply/src/models/nalbind_project.dart';
import 'package:ply/src/models/readiness.dart';
import 'package:ply/src/print/pdf_builder.dart';
import 'package:ply/src/print/pdf_fonts.dart';
import 'package:ply/src/print/print_document.dart';
import 'package:ply/src/print/print_export.dart';
import 'package:ply/src/print/print_layout.dart';
import 'package:ply/src/rust/frb_generated.dart';
import 'package:ply/src/screens/knit_editor_screen.dart';

import '../test/print/print_test_support.dart' show PdfReadBack;

/// fixtures/weaving/readiness/mixed-problems.wif (written with CRLF line ends).
final String kWeaveWif = r'''[WIF]
Version=1.1
Developers=ply
Source Program=Ply

[TEXT]
Title=Twill sampler with slips

[NOTES]
1=Readiness fixture: a sampler with the slips a weaver makes.

[CONTENTS]
TEXT=true
NOTES=true
COLOR PALETTE=true
COLOR TABLE=true
WEAVING=true
WARP=true
WEFT=true
THREADING=true
TIEUP=true
TREADLING=true
WARP COLORS=true
WEFT COLORS=true
PRIVATE PLY PICKS=true

[WEAVING]
Shafts=8
Treadles=8
Rising Shed=true

[WARP]
Threads=16
Units=Inches

[WEFT]
Threads=16
Units=Inches

[COLOR PALETTE]
Entries=2
Form=RGB
Range=255

[COLOR TABLE]
1=255,255,255
2=0,0,0

[THREADING]
1=1
2=2
3=3
4=4
5=5
6=6
7=7
8=8
9=1
10=2
11=3
12=4
13=5
14=6
15=7
16=8

[TIEUP]
1=1,2,3,4
2=2,3,4,5
3=3,4,5,6
4=4,5,6,7
5=5,6,7,8
6=6,7,8,1
7=7,8,1,2
8=8,1,2,3

[TREADLING]
1=1
2=2
3=3
4=4
5=9
6=6
7=7
8=8
9=1
10=2
11=3
12=4
13=5
14=6
15=7
16=7

[WARP COLORS]
1=1
2=1
3=1
4=1
5=1
6=1
7=1
8=1
9=1
10=1
11=1
12=1
13=1
14=1
15=1
16=1

[WEFT COLORS]
1=2
2=2
3=2
4=2
5=2
6=2
7=2
8=2
9=2
10=2
11=2
12=2
13=2
14=2
15=2
16=2

[PRIVATE PLY PICKS]
Version=1
Picks=16
Sheds=d8ab0691bf3fbf43
Shot 15=2
1=role pattern
2=role tabby
3=role pattern
4=role pattern
5=role pattern
6=role pattern
7=role pattern
8=role pattern
9=role pattern
10=role pattern
11=role pattern
12=role pattern
13=role pattern
14=role pattern
15=role pattern
16=role pattern
'''
    .replaceAll('\n', '\r\n');

/// fixtures/knitting/readiness/mixed-problems.plyknit.
const String kKnitJson = r'''{
  "format": "ply.knit",
  "schema_version": 6,
  "document": {
    "name": "Ribbed brim with slips",
    "construction": "Flat",
    "first_row_side": "Rs",
    "cast_on": 22,
    "gauge": {
      "sts": 22.0,
      "rows": 30.0,
      "unit": "Inches"
    },
    "palette": [
      {
        "r": 255,
        "g": 255,
        "b": 255
      }
    ],
    "legend": {
      "stitches": [
        {
          "symbol": "ns",
          "consumes": 0,
          "produces": 0,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "k",
          "consumes": 1,
          "produces": 1,
          "ws_variant": 2,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "p",
          "consumes": 1,
          "produces": 1,
          "ws_variant": 1,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "yo",
          "consumes": 0,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "k2tog",
          "consumes": 2,
          "produces": 1,
          "ws_variant": 6,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "ssk",
          "consumes": 2,
          "produces": 1,
          "ws_variant": 6,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "p2tog",
          "consumes": 2,
          "produces": 1,
          "ws_variant": 4,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "cdd",
          "consumes": 3,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "m1l",
          "consumes": 0,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "m1r",
          "consumes": 0,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "kfb",
          "consumes": 1,
          "produces": 2,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "sl",
          "consumes": 1,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "k3tog",
          "consumes": 3,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "sk2po",
          "consumes": 3,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "ssp",
          "consumes": 2,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "kbf",
          "consumes": 1,
          "produces": 2,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "pfb",
          "consumes": 1,
          "produces": 2,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "m1p",
          "consumes": 0,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "m1lp",
          "consumes": 0,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "m1rp",
          "consumes": 0,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        },
        {
          "symbol": "ktbl",
          "consumes": 1,
          "produces": 1,
          "ws_variant": null,
          "cable": null,
          "macro_rows": 1
        }
      ]
    },
    "chart": {
      "width": 4,
      "rows": [
        {
          "cells": [
            {
              "stitch": 1,
              "color": null
            },
            {
              "stitch": 1,
              "color": null
            },
            {
              "stitch": 2,
              "color": null
            },
            {
              "stitch": 2,
              "color": null
            }
          ],
          "repeats": [
            {
              "start": 0,
              "end": 4,
              "count": "ToEnd"
            }
          ]
        }
      ]
    },
    "notes": "Readiness fixture: a brim with the slips a knitter makes.",
    "sections": [
      {
        "id": "section-1",
        "name": "Brim",
        "notes": "",
        "construction": null,
        "piece": null,
        "steps": [
          {
            "id": "step-1",
            "action": {
              "ChartRows": {
                "first": 1,
                "last": 1
              }
            }
          },
          {
            "id": "step-2",
            "action": {
              "Opaque": {
                "text": "Work 6 more rows of rib as set.",
                "stitch_change": 0
              }
            }
          },
          {
            "id": "step-3",
            "action": {
              "BindOff": {
                "count": 30,
                "resolve_turns": false
              }
            }
          },
          {
            "id": "step-4",
            "action": {
              "Opaque": {
                "text": "Change to the larger needles.",
                "stitch_change": null
              }
            }
          }
        ]
      }
    ],
    "pieces": []
  }
}''';

/// fixtures/nalbinding/readiness/mixed-problems.plynal.
const String kNalbindJson =
    r'''{"format":"ply.nalbind","schemaVersion":3,"name":"Mitten with slips","notation":"uo/uoo f1","stitchName":"Oslo","notes":"Readiness fixture: a mitten with the slips a nalbinder makes.","recipe":{"fit":[{"label":"Hand around","value":20.0,"unit":"cm"}],"segments":[{"id":"segment-1","title":"Cuff chain","work":{"kind":"foundationChain","stitches":36,"join":"ring"},"stitch":null,"target":null,"notes":"","caution":""},{"id":"segment-2","title":"Cuff","work":{"kind":"rounds","worked":"spiral","extent":{"type":"rounds","count":12}},"stitch":null,"target":null,"notes":"","caution":""},{"id":"segment-3","title":"Thumb gap","work":{"kind":"opening","skip":6,"stitches":6},"stitch":null,"target":null,"notes":"","caution":""},{"id":"segment-4","title":"Hand","work":{"kind":"rounds","worked":"spiral","extent":{"type":"rounds","count":20}},"stitch":null,"target":null,"notes":"","caution":""},{"id":"segment-5","title":"Tip","work":{"kind":"decrease","perRound":10,"method":"skipALoop","extent":{"type":"rounds","count":4}},"stitch":null,"target":null,"notes":"","caution":""},{"id":"segment-6","title":"Close the tip","work":{"kind":"finish","method":null},"stitch":null,"target":null,"notes":"","caution":""},{"id":"segment-7","title":"Fulling","work":{"kind":"freeform","role":"other","text":"Full lightly in warm water and dry flat."},"stitch":null,"target":null,"notes":"","caution":""}],"done":[],"lastSegmentNumber":7}}''';

/// The oracles' items in order: (check, code, severity, place).
const kWeaveItems = [
  ('draft', 'weave.treadle_untied', 'error', 'Pick 5, treadle 9'),
  ('draft', 'weave.tabby_off_shed', 'warning', 'Pick 2'),
  ('loom', 'loom.shafts_exceeded', 'warning', 'Shafts 5 to 8'),
  ('loom', 'loom.treadles_exceeded', 'warning', 'Treadles 7 to 9'),
  ('loom', 'loom.width_unknown_sett', 'unsupported', null),
  ('loom', 'loom.reed_no_sett', 'unsupported', null),
  ('draft', 'weave.shot_group_catch', 'info', 'Picks 15 and 16'),
];
const kKnitItems = [
  ('sections', 'section-step', 'error', 'Brim, step 1, chart row 1'),
  ('sections', 'section-step', 'error', 'Brim, step 3'),
  ('sections', 'section-step', 'warning', 'Brim, step 4'),
  ('sections', 'unchecked-step', 'unsupported', 'Brim, step 2'),
  ('sections', 'unchecked-step', 'unsupported', 'Brim, step 4'),
];
const kNalbindItems = [
  ('recipe', 'decrease-too-many', 'error', 'Step 5 (Tip)'),
  ('recipe', 'opening-not-used', 'warning', 'Step 3 (Thumb gap)'),
  ('recipe', 'free-text-step', 'unsupported', 'Step 7 (Fulling)'),
  ('notation', 'case-normalized', 'info', 'Notation, at "uo"'),
  ('notation', 'case-normalized', 'info', 'Notation, at "uoo"'),
  ('notation', 'case-normalized', 'info', 'Notation, at "f"'),
];

/// The four-shaft jack loom of fixtures/weaving/looms/looms.json, as My looms holds it.
const kJackLoom = LoomProfile(
  id: 'fixture-four-shaft-jack',
  name: 'Four-shaft jack loom',
  type: LoomType.jack,
  shafts: 4,
  treadles: 6,
  weavingWidth: LoomLength(24, MeasureUnit.inches),
  reeds: [Reed(12, DentUnit.perInch), Reed(10, DentUnit.perInch)],
  treadlesAtOnce: 2,
  notes: 'Fixture: a small jack floor loom.',
);

List<(String, String, String, String?)> _items(ReadinessReport r) => [
      for (final i in r.items) (i.check.name, i.code, i.level.name, i.place),
    ];

/// Records what reached the print and share dialogs.
class _Recording implements PdfOutput {
  final printed = <(String, Uint8List)>[];

  @override
  Future<bool> print({
    required String name,
    required PdfPageFormat format,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  }) async {
    printed.add((name, await build(format)));
    return true;
  }

  @override
  Future<bool> share({required String filename, required Uint8List bytes}) async {
    printed.add((filename, bytes));
    return true;
  }
}

bool _isPdf(Uint8List b) => String.fromCharCodes(b.take(5)) == '%PDF-';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  const readiness = ReadinessRepository();

  test('weaving: the engine reports the oracle, the loom only warns', () async {
    final drafts = DraftRepository();
    final doc = await drafts.parseDoc(kWeaveWif);
    final r = await readiness.weave(drafts.toDto(doc), loom: kJackLoom);
    expect(_items(r), kWeaveItems);
    expect(r.verdict, ReadinessVerdict.notReady);
    expect(r.checked, [ReadinessCheck.draft, ReadinessCheck.loom]);
    // The blocking set is exactly the structural errors (what the PDF's problems box lists).
    final errors = (await drafts.validateDto(doc)).where((i) => i.isError).length;
    expect(r.errors.length, errors);
    // The same draft with no loom chosen has no loom findings.
    final alone = await readiness.weave(drafts.toDto(doc));
    expect(alone.checked, [ReadinessCheck.draft]);
    expect(alone.items.where((i) => i.check == ReadinessCheck.loom), isEmpty);
  });

  test('knitting: the engine reports the oracle, steps in the pattern\'s own words listed',
      () async {
    final knits = KnitRepository();
    final pattern = await knits.parse(kKnitJson);
    final r = await readiness.knit(pattern);
    expect(_items(r), kKnitItems);
    expect(r.verdict, ReadinessVerdict.notReady);
    final errors = (await knits.validate(pattern)).where((i) => i.severity.name == 'error').length;
    expect(r.errors.length, errors);
  });

  test('nalbinding: the engine reports the oracle, free text listed as not checked', () async {
    final project = NalbindProject.decode(kNalbindJson);
    final r = await readiness.nalbind(project.notation, project.recipe);
    expect(_items(r), kNalbindItems);
    expect(r.verdict, ReadinessVerdict.notReady);
    expect(r.unsupported.single.place, 'Step 7 (Fulling)');
  });

  testWidgets('the knitting editor: not ready, Go back makes nothing, a draft copy is marked',
      (tester) async {
    final knits = KnitRepository();
    final pattern = await tester.runAsync(() => knits.parse(kKnitJson));
    final out = _Recording();
    await tester.pumpWidget(ProviderScope(
      overrides: [pdfOutputProvider.overrideWithValue(out)],
      child: MaterialApp(home: KnitEditorScreen(initialPattern: pattern)),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Print or share PDF'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Print'));
    await tester.pumpAndSettle();
    expect(find.text('This pattern is not ready to make or share'), findsOneWidget);
    expect(find.text('Ply found 2 errors in this pattern:'), findsOneWidget);
    expect(find.textContaining('• Brim, step 3: Binds off 30 stitches'), findsOneWidget);
    await tester.tap(find.text('Go back'));
    await tester.pumpAndSettle();
    expect(out.printed, isEmpty, reason: 'the default makes nothing');

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Print or share PDF'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Print'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Print a draft copy'));
    await tester.pumpAndSettle();
    final (name, bytes) = out.printed.single;
    expect(name, endsWith(' (draft copy).pdf'));
    expect(_isPdf(bytes), isTrue);
  });

  test('a draft copy says so on every page with the engine\'s count of errors', () async {
    final project = NalbindProject.decode(kNalbindJson);
    final r = await readiness.nalbind(project.notation, project.recipe);
    final doc = PrintDocument(
      title: project.name,
      kind: 'Nalbinding project',
      sections: [
        PrintSection('Notes', [
          for (var i = 0; i < 150; i++) PrintParagraph('Line $i of a long note.'),
        ]),
      ],
    ).asDraftCopy(r.errors.length);
    final fonts = await PlyPdfFonts.load();
    final bytes = await buildPrintPdf(doc,
        page: PrintPageSetup.forUnit(MeasureUnit.centimeters), fonts: fonts, compress: false);
    final pdf = PdfReadBack(bytes);
    expect(pdf.pageCount, greaterThan(1));
    for (final page in pdf.pages) {
      expect(page, contains('Draft copy, not ready to make or share: 1 error'));
    }
  });
}
