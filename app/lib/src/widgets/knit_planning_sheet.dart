// The knit planning calculator: a modal bottom sheet with three sections — a GAUGE editor (seed from
// a yarn weight or type it; "Apply" writes it back onto the pattern), a CAST-ON calculator (target
// width + ease -> stitches, rounded to a stitch-repeat multiple), and a YARDAGE estimate (a width x
// length stockinette rectangle -> yards, plus a 10% buffer). The gauge edit is the only one that
// mutates the pattern; the two calculators are pure planning aids reading the in-sheet gauge fields.
//
// All FFI lives in the repository. Dimensions are in the pattern gauge's unit (per 4 in or per 10 cm).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/dto.dart' show UnitKind;
import '../rust/knit_dto.dart';
import '../state/knit_editor_providers.dart';
import 'adaptive_sheet.dart';

/// Open the knit planning calculator. Call from a context inside the editor's ProviderScope so the
/// sheet's `ref` resolves the open pattern. Adaptive: a bottom sheet on phones, a dialog on tablets.
Future<void> showKnitPlanningSheet(BuildContext context) {
  return showAdaptiveSheet<void>(context, child: const KnitPlanningSheet());
}

class KnitPlanningSheet extends ConsumerStatefulWidget {
  const KnitPlanningSheet({super.key});

  @override
  ConsumerState<KnitPlanningSheet> createState() => _KnitPlanningSheetState();
}

class _KnitPlanningSheetState extends ConsumerState<KnitPlanningSheet> {
  final _gaugeForm = GlobalKey<FormState>();
  final _castForm = GlobalKey<FormState>();
  final _yardForm = GlobalKey<FormState>();

  // Gauge fields (per the window: 4 in or 10 cm). Seeded from the open pattern.
  final _sts = TextEditingController();
  final _rows = TextEditingController();
  late UnitKind _unit;
  YarnWeightKind? _weight;
  bool _applied = false;

  // Cast-on calculator.
  final _castWidth = TextEditingController();
  final _ease = TextEditingController(text: '0');
  final _repeat = TextEditingController(text: '1');
  int? _castOn;

  // Yardage estimate.
  final _yardWidth = TextEditingController();
  final _yardLength = TextEditingController();
  double? _yards;

  @override
  void initState() {
    super.initState();
    final g = ref.read(knitEditorProvider).pattern.gauge;
    _unit = g.unit;
    _sts.text = _fmt(g.sts);
    _rows.text = _fmt(g.rows);
  }

  @override
  void dispose() {
    for (final c in [_sts, _rows, _castWidth, _ease, _repeat, _yardWidth, _yardLength]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _unitLabel => _unit == UnitKind.centimeters ? 'cm' : 'in';
  String get _windowLabel => _unit == UnitKind.centimeters ? '10 cm' : '4 in';

  /// The gauge currently typed into the fields (the basis for both calculators), or null if either
  /// field is not a positive number yet.
  GaugeDto? get _fieldGauge {
    final s = double.tryParse(_sts.text.trim());
    final r = double.tryParse(_rows.text.trim());
    if (s == null || r == null || !s.isFinite || !r.isFinite || s <= 0 || r <= 0) return null;
    return GaugeDto(sts: s, rows: r, unit: _unit);
  }

  Future<void> _seedFromWeight(YarnWeightKind w) async {
    final g = await ref.read(knitRepositoryProvider).seedGauge(w);
    if (!mounted) return;
    setState(() {
      _weight = w;
      _unit = g.unit;
      _sts.text = _fmt(g.sts);
      _rows.text = _fmt(g.rows);
      _applied = false;
    });
  }

  void _applyGauge() {
    if (!_gaugeForm.currentState!.validate()) return;
    final g = _fieldGauge;
    if (g == null) return;
    ref.read(knitEditorProvider.notifier).setGauge(g);
    setState(() => _applied = true);
  }

  Future<void> _calcCastOn() async {
    if (!_castForm.currentState!.validate()) return;
    final g = _fieldGauge;
    if (g == null) return;
    final n = await ref.read(knitRepositoryProvider).castOn(
          double.parse(_castWidth.text.trim()),
          double.parse(_ease.text.trim()),
          g,
          int.parse(_repeat.text.trim()),
        );
    if (mounted) setState(() => _castOn = n);
  }

  Future<void> _calcYards() async {
    if (!_yardForm.currentState!.validate()) return;
    final g = _fieldGauge;
    if (g == null) return;
    final y = await ref.read(knitRepositoryProvider).estimateYards(
          double.parse(_yardWidth.text.trim()),
          double.parse(_yardLength.text.trim()),
          g,
        );
    if (mounted) setState(() => _yards = y);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Gauge & yardage', style: text.titleMedium),
            const SizedBox(height: 16),

            // --- Gauge: seed or type, then apply onto the pattern. ---
            Text('Gauge (per $_windowLabel)', style: text.titleSmall),
            const SizedBox(height: 8),
            DropdownButton<YarnWeightKind>(
              value: _weight,
              isExpanded: true,
              hint: const Text('Seed from a yarn weight'),
              onChanged: (w) => w == null ? null : _seedFromWeight(w),
              items: [
                for (final w in YarnWeightKind.values)
                  DropdownMenuItem(value: w, child: Text(_weightLabel(w))),
              ],
            ),
            Form(
              key: _gaugeForm,
              child: Row(
                children: [
                  Expanded(child: _numField(_sts, 'Stitches', _positive)),
                  const SizedBox(width: 12),
                  Expanded(child: _numField(_rows, 'Rows', _positive)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                FilledButton.tonal(onPressed: _applyGauge, child: const Text('Apply gauge')),
                const SizedBox(width: 16),
                if (_applied)
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text('Saved to the pattern', style: text.bodyMedium),
                    ),
                  ),
              ],
            ),
            Text('Seed from a yarn weight, or enter your swatch. Stitches/rows per $_windowLabel.',
                style: muted),

            const Divider(height: 32),

            // --- Cast-on: target width + ease -> stitches. ---
            Text('Cast-on stitches', style: text.titleSmall),
            Form(
              key: _castForm,
              child: Column(
                children: [
                  _numField(_castWidth, 'Finished width ($_unitLabel)', _positive),
                  _numField(_ease, 'Ease (+/- $_unitLabel)', _finite),
                  _numField(_repeat, 'Stitch repeat (multiple of)', _positiveInt, decimal: false),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonal(onPressed: _calcCastOn, child: const Text('Calculate cast-on')),
                const SizedBox(width: 16),
                if (_castOn != null)
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        _castOn! < 1 ? 'Width too small for this gauge' : 'Cast on $_castOn stitches',
                        style: text.titleMedium,
                      ),
                    ),
                  ),
              ],
            ),

            const Divider(height: 32),

            // --- Yardage: width x length stockinette rectangle. ---
            Text('Yardage estimate', style: text.titleSmall),
            Form(
              key: _yardForm,
              child: Column(
                children: [
                  _numField(_yardWidth, 'Width ($_unitLabel)', _positive),
                  _numField(_yardLength, 'Length ($_unitLabel)', _positive),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonal(onPressed: _calcYards, child: const Text('Estimate yardage')),
              ],
            ),
            if (_yards != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  container: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Estimate: ${_fmt(_yards!)} yards', style: text.bodyLarge),
                      Text('With 10% buffer: ${_fmt(_yards! * 1.1)} yards', style: text.bodyLarge),
                    ],
                  ),
                ),
              ),
            Text('Rough stockinette estimate. Always buy a little extra, ideally one dye lot.',
                style: muted),
          ],
        ),
      ),
    );
  }

  Widget _numField(TextEditingController c, String label, FormFieldValidator<String> v,
      {bool decimal = true}) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextFormField(
        controller: c,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal, signed: !decimal ? false : true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(decimal ? RegExp(r'[0-9.\-]') : RegExp(r'[0-9]')),
        ],
        decoration: InputDecoration(labelText: label),
        validator: v,
      ),
    );
  }

  static String _weightLabel(YarnWeightKind w) => switch (w) {
        YarnWeightKind.lace => 'Lace (0)',
        YarnWeightKind.superFine => 'Super fine (1)',
        YarnWeightKind.fine => 'Fine (2)',
        YarnWeightKind.light => 'Light (3)',
        YarnWeightKind.medium => 'Medium / worsted (4)',
        YarnWeightKind.bulky => 'Bulky (5)',
        YarnWeightKind.superBulky => 'Super bulky (6)',
        YarnWeightKind.jumbo => 'Jumbo (7)',
      };

  // Ceilings keep the f32 estimate finite and the u32 wire fields from truncating; the engine guards
  // again as a backstop.
  static const double _maxLen = 1000000;
  static const int _maxCount = 100000;

  static String? _positive(String? s) {
    final v = double.tryParse((s ?? '').trim());
    if (v == null || !v.isFinite || v <= 0) return 'Enter a number greater than 0';
    return v > _maxLen ? 'Too large' : null;
  }

  static String? _finite(String? s) {
    final v = double.tryParse((s ?? '').trim());
    if (v == null || !v.isFinite) return 'Enter a number';
    return v.abs() > _maxLen ? 'Too large' : null;
  }

  static String? _positiveInt(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null || v < 1) return 'Enter a whole number, at least 1';
    return v > _maxCount ? 'Too large' : null;
  }

  /// Trim a trailing ".0"; otherwise up to 2 decimals. A non-finite result reads "too large".
  static String _fmt(double v) {
    if (!v.isFinite) return 'too large';
    if (v > 0 && v < 0.01) return '<0.01';
    final r = (v * 100).roundToDouble() / 100;
    return r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toStringAsFixed(2);
  }
}
