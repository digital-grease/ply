import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/knit_stitches.dart';
import '../rust/knit_dto.dart';
import '../state/knit_editor_providers.dart';
import '../state/knit_editor_state.dart';

/// A starting stitch-pattern fill for a fresh chart.
enum KnitStarter { stockinette, garter, ribbing, seed }

/// The stitch id at chart (row, col) for a starting pattern. Pure + host-testable.
int starterStitchAt(KnitStarter s, int r, int c) {
  switch (s) {
    case KnitStarter.stockinette:
      return KnitStitch.knit;
    case KnitStarter.garter:
      return r.isOdd ? KnitStitch.purl : KnitStitch.knit; // alternating ridges
    case KnitStarter.ribbing:
      return c.isOdd ? KnitStitch.purl : KnitStitch.knit; // 1x1 vertical ribs
    case KnitStarter.seed:
      return (r + c).isOdd ? KnitStitch.purl : KnitStitch.knit; // checkerboard
  }
}

/// Re-paint [base]'s cells for [starter] in ONE pass, preserving each row's repeat info + cell colors.
/// Pure; the setup screen runs this on the engine's resized all-knit chart.
ChartDto starterChart(ChartDto base, KnitStarter starter) => ChartDto(
      width: base.width,
      rows: [
        for (var r = 0; r < base.rows.length; r++)
          RowDto(
            cells: [
              for (var c = 0; c < base.rows[r].cells.length; c++)
                CellDto(stitch: starterStitchAt(starter, r, c), color: base.rows[r].cells[c].color),
            ],
            repeats: base.rows[r].repeats,
          ),
      ],
    );

/// Setup for a NEW knitting pattern: size, gauge (seeded from a yarn weight), construction, first-row
/// side, and a starting stitch pattern. Builds a ready-to-edit [KnitPatternDto] and pops it back to
/// the library, which opens the editor on it. Reuses the existing model fields (KnitEditorState
/// reducers + the engine gauge seed) — nothing new on the engine side.
class NewKnitSetupScreen extends ConsumerStatefulWidget {
  const NewKnitSetupScreen({super.key});

  @override
  ConsumerState<NewKnitSetupScreen> createState() => _NewKnitSetupScreenState();
}

class _NewKnitSetupScreenState extends ConsumerState<NewKnitSetupScreen> {
  final _sts = TextEditingController(text: '20');
  final _rows = TextEditingController(text: '24');
  YarnWeightKind _yarn = YarnWeightKind.medium;
  ConstructionKind _construction = ConstructionKind.flat;
  SideKind _side = SideKind.rs;
  KnitStarter _starter = KnitStarter.stockinette;
  bool _creating = false;

  static const int _maxSts = 200;
  static const int _maxRows = 400;

  @override
  void dispose() {
    _sts.dispose();
    _rows.dispose();
    super.dispose();
  }

  int get _w => (int.tryParse(_sts.text.trim()) ?? 20).clamp(1, _maxSts);
  int get _h => (int.tryParse(_rows.text.trim()) ?? 24).clamp(1, _maxRows);

  Future<void> _create() async {
    if (_creating) return;
    setState(() => _creating = true);
    final navigator = Navigator.of(context);
    try {
      final repo = ref.read(knitRepositoryProvider);
      final blank = await repo.blank();
      final gauge = await repo.seedGauge(_yarn);
      // Reuse the existing reducers for gauge/construction/side/size; an all-knit chart comes back.
      final base = KnitEditorState(pattern: blank)
          .setGauge(gauge)
          .setConstruction(_construction)
          .setFirstRowSide(_side)
          .resizeChart(_w, _h)
          .pattern;
      final pattern = KnitPatternDto(
        name: base.name,
        construction: base.construction,
        firstRowSide: base.firstRowSide,
        gauge: base.gauge,
        palette: base.palette,
        legend: base.legend,
        chart: starterChart(base.chart, _starter), // re-paint for the starting pattern in one pass
        notes: base.notes,
      );
      if (!mounted) return;
      navigator.pop(pattern);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not create: $e')));
        setState(() => _creating = false);
      }
    }
  }

  static String _yarnLabel(YarnWeightKind y) => switch (y) {
        YarnWeightKind.lace => 'Lace',
        YarnWeightKind.superFine => 'Super fine (sock/fingering)',
        YarnWeightKind.fine => 'Fine (sport)',
        YarnWeightKind.light => 'Light (DK)',
        YarnWeightKind.medium => 'Medium (worsted)',
        YarnWeightKind.bulky => 'Bulky',
        YarnWeightKind.superBulky => 'Super bulky',
        YarnWeightKind.jumbo => 'Jumbo',
      };

  static String _starterLabel(KnitStarter s) => switch (s) {
        KnitStarter.stockinette => 'Stockinette',
        KnitStarter.garter => 'Garter',
        KnitStarter.ribbing => '1×1 ribbing',
        KnitStarter.seed => 'Seed',
      };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('New pattern')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          Text('Size', style: text.titleSmall),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _numField(_sts, 'Stitches')),
              const SizedBox(width: 12),
              Expanded(child: _numField(_rows, 'Rows')),
            ],
          ),
          const SizedBox(height: 20),
          Text('Yarn weight (seeds the gauge)', style: text.titleSmall),
          const SizedBox(height: 8),
          DropdownButtonFormField<YarnWeightKind>(
            initialValue: _yarn,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onChanged: (v) => setState(() => _yarn = v ?? YarnWeightKind.medium),
            items: [
              for (final y in YarnWeightKind.values)
                DropdownMenuItem(value: y, child: Text(_yarnLabel(y))),
            ],
          ),
          const SizedBox(height: 20),
          Text('Construction', style: text.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ConstructionKind>(
            segments: const [
              ButtonSegment(value: ConstructionKind.flat, label: Text('Flat')),
              ButtonSegment(value: ConstructionKind.inTheRound, label: Text('In the round')),
            ],
            selected: {_construction},
            onSelectionChanged: (s) => setState(() => _construction = s.first),
          ),
          const SizedBox(height: 20),
          Text('First row', style: text.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<SideKind>(
            segments: const [
              ButtonSegment(value: SideKind.rs, label: Text('Right side')),
              ButtonSegment(value: SideKind.ws, label: Text('Wrong side')),
            ],
            selected: {_side},
            onSelectionChanged: (s) => setState(() => _side = s.first),
          ),
          const SizedBox(height: 20),
          Text('Starting stitch', style: text.titleSmall),
          const SizedBox(height: 8),
          DropdownButtonFormField<KnitStarter>(
            initialValue: _starter,
            decoration: const InputDecoration(border: OutlineInputBorder()),
            onChanged: (v) => setState(() => _starter = v ?? KnitStarter.stockinette),
            items: [
              for (final s in KnitStarter.values)
                DropdownMenuItem(value: s, child: Text(_starterLabel(s))),
            ],
          ),
          const SizedBox(height: 28),
          FilledButton(
            onPressed: _creating ? null : _create,
            child: const Text('Create pattern'),
          ),
        ],
      ),
    );
  }

  Widget _numField(TextEditingController c, String label) => TextFormField(
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      );
}
