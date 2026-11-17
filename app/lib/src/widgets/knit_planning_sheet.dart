// The knit planning calculator: a modal bottom sheet with three sections — a GAUGE editor (seed from
// a yarn weight or type it; "Apply" writes it back onto the pattern), a CAST-ON calculator (target
// width + ease -> stitches, rounded to a stitch-repeat multiple; "Set as pattern cast-on" writes the
// result onto the pattern), and a YARDAGE estimate (a width x length stockinette rectangle -> yards,
// plus a 10% buffer). Only those two explicit taps mutate the pattern; the calculators themselves are
// planning aids reading the in-sheet gauge fields.
//
// All FFI lives in the repository. Dimensions are in the pattern gauge's unit (per 4 in or per 10 cm).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/materials_repository.dart' show PlanException;
import '../models/knit_calculators.dart' show YarnWeight, yarnWeightFromWpi;
import '../models/material_record.dart';
import '../rust/dto.dart' show UnitKind;
import '../rust/knit_dto.dart';
import '../state/knit_editor_providers.dart';
import '../state/knit_editor_state.dart';
import '../state/material_providers.dart';
import 'adaptive_sheet.dart';
import 'record_report_panel.dart' show EstimateTrace;
import 'swatch_choice.dart';

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
  // A measured wraps-per-inch to seed the gauge from (replaces the old yarn-weight picker).
  final _wpi = TextEditingController();
  late UnitKind _unit;
  bool _applied = false;

  // Cast-on calculator.
  final _castWidth = TextEditingController();
  final _ease = TextEditingController(text: '0');
  final _repeat = TextEditingController(text: '1');
  int? _castOn;
  bool _castOnApplied = false;

  // Yardage estimate.
  final _yardWidth = TextEditingController();
  final _yardLength = TextEditingController();
  double? _yards;
  double? _yardsBuffered;

  // A swatch the gauge comes from (ADR 0016): while the gauge fields still hold what it filled in,
  // the estimates take the gauge from the swatch itself and list where every input came from.
  // Kept by id and looked up in the library each time, so an edited swatch is used as it is now and a
  // deleted one clears the choice.
  String? _swatchId;
  SwatchRecord? _swatchSeen;
  String? _swatchSts;
  TracedEstimate<int>? _castOnTrace;
  TracedEstimate<YarnAmount>? _yardTrace;
  String? _planError;

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
    for (final c in [_sts, _rows, _wpi, _castWidth, _ease, _repeat, _yardWidth, _yardLength]) {
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

  /// Fill the gauge fields from [s] (its count after finishing, else before), or forget the swatch.
  void _useSwatch(SwatchRecord? s) {
    setState(() {
      _swatchId = s?.id;
      _swatchSeen = s;
      _castOnTrace = null;
      _yardTrace = null;
      _planError = null;
      _swatchSts = null;
      final across = s?.planningAcross;
      if (s == null || across == null) return;
      final c = across.$1.value;
      final metric = c.over.unit.isMetric;
      final window = metric ? const Length(10, LengthUnit.centimeter) : const Length(4, LengthUnit.inch);
      _unit = metric ? UnitKind.centimeters : UnitKind.inches;
      _sts.text = filledNumber(c.per(window));
      _swatchSts = _sts.text;
      final along = s.stage(across.$2).along?.value;
      if (along != null) _rows.text = filledNumber(along.per(window));
      _applied = false;
    });
  }

  /// The chosen swatch as the library holds it now, or null.
  SwatchRecord? get _swatch {
    final id = _swatchId;
    return id == null ? null : ref.read(materialLibraryProvider).valueOrNull?.swatch(id);
  }

  /// The library changed: a deleted swatch clears the choice; an edited one fills the gauge again.
  void _onLibrary(MaterialLibraryState? lib) {
    final id = _swatchId;
    if (id == null || lib == null || !mounted) return;
    final s = lib.swatch(id);
    if (s == null) {
      _useSwatch(null);
    } else if (s != _swatchSeen) {
      _useSwatch(s);
    }
  }

  /// The stitch gauge as a planning input: the swatch's own count while the field still shows what
  /// it filled in, otherwise what is typed.
  PlanInput<CountOver> get _gaugeInput {
    final sts = double.tryParse(_sts.text.trim()) ?? 0;
    if (_swatch != null && _swatchSts != null && _sts.text == _swatchSts) {
      return const PlanInput.swatch();
    }
    final window = _unit == UnitKind.centimeters
        ? const Length(10, LengthUnit.centimeter)
        : const Length(4, LengthUnit.inch);
    return PlanInput(InputOrigin.entered, CountOver(sts, window));
  }

  LengthUnit get _lengthUnit => _unit == UnitKind.centimeters ? LengthUnit.centimeter : LengthUnit.inch;

  /// Seed the gauge from a measured wraps-per-inch: classify it into a Craft Yarn Council weight band
  /// ([yarnWeightFromWpi]) and fill the stitch field with that band's typical stockinette gauge, plus
  /// a row estimate at the stockinette ~4:3 row:stitch ratio. An editable starting point the knitter
  /// overrides with their own swatch. Pure (no FFI); the WPI field replaces the old yarn-weight picker.
  void _seedFromWpi(YarnWeight w) {
    final sts = w.stitchesPerWindow;
    setState(() {
      _unit = UnitKind.inches; // CYC gauges are per 4 in
      _sts.text = _fmt(sts);
      _rows.text = _fmt(sts * 4 / 3);
      _applied = false;
      // A result worked out from the swatch's gauge no longer matches the fields: clear it.
      if (_castOnTrace != null) _castOn = null;
      if (_yardTrace != null) _yards = _yardsBuffered = null;
      _castOnTrace = null;
      _yardTrace = null;
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
    final swatch = _swatch;
    if (swatch != null) {
      // With a swatch, the engine works it out and says where each input came from.
      try {
        final t = await ref.read(materialsRepositoryProvider).castOnTraced(
              swatch: swatch,
              gauge: _gaugeInput,
              width: Length(double.parse(_castWidth.text.trim()), _lengthUnit),
              ease: Length(double.parse(_ease.text.trim()), _lengthUnit),
              repeat: int.parse(_repeat.text.trim()),
            );
        if (mounted) {
          setState(() {
            _castOn = t.value;
            _castOnTrace = t;
            _castOnApplied = false;
            _planError = null;
          });
        }
      } on PlanException catch (e) {
        if (mounted) setState(() => _planError = e.message);
      }
      return;
    }
    final n = await ref.read(knitRepositoryProvider).castOn(
          double.parse(_castWidth.text.trim()),
          double.parse(_ease.text.trim()),
          g,
          int.parse(_repeat.text.trim()),
        );
    if (mounted) {
      setState(() {
        _castOn = n;
        _castOnApplied = false;
      });
    }
  }

  /// Whether the calculated count can become the pattern's cast-on (the editor's accepted range).
  bool get _castOnApplicable {
    final n = _castOn;
    return n != null && n >= 1 && n <= KnitEditorState.maxCastOn;
  }

  /// Write the calculated count onto the pattern as its cast-on (one undo entry). Only on this tap:
  /// calculating alone never changes the pattern.
  void _applyCastOn() {
    if (!_castOnApplicable) return;
    ref.read(knitEditorProvider.notifier).setCastOn(_castOn);
    setState(() => _castOnApplied = true);
  }

  Future<void> _calcYards() async {
    if (!_yardForm.currentState!.validate()) return;
    final g = _fieldGauge;
    if (g == null) return;
    final swatch = _swatch;
    if (swatch != null) {
      try {
        final t = await ref.read(materialsRepositoryProvider).yardageTraced(
              swatch: swatch,
              yarn: singleYarnOf(ref, swatch),
              gauge: _gaugeInput,
              width: Length(double.parse(_yardWidth.text.trim()), _lengthUnit),
              length: Length(double.parse(_yardLength.text.trim()), _lengthUnit),
              buffer: const PlanInput(InputOrigin.plyDefault, 0.1),
            );
        if (mounted) {
          setState(() {
            _yards = t.value.yards;
            _yardsBuffered = t.value.bufferedYards;
            _yardTrace = t;
            _planError = null;
          });
        }
      } on PlanException catch (e) {
        if (mounted) setState(() => _planError = e.message);
      }
      return;
    }
    final y = await ref.read(knitRepositoryProvider).estimateYards(
          double.parse(_yardWidth.text.trim()),
          double.parse(_yardLength.text.trim()),
          g,
        );
    if (mounted) {
      setState(() {
        _yards = y;
        _yardsBuffered = y * 1.1;
        _yardTrace = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    final patternCastOn = ref.watch(knitEditorProvider.select((s) => s.pattern.castOn));
    final swatches = swatchesForCraft(ref, SwatchCraft.knitting);
    ref.listen(materialLibraryProvider, (_, next) => _onLibrary(next.valueOrNull));
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
            // A recorded swatch (only when there is one): fills the gauge from what it measured.
            if (swatches.isNotEmpty) ...[
              SwatchChooser(swatches: swatches, selected: _swatch, onChanged: _useSwatch),
              if (_swatch != null && _swatch!.planningAcross == null)
                Text('This swatch has no stitch count, so it cannot give a gauge.', style: muted),
              const SizedBox(height: 8),
            ],
            // Seed from a measured wraps-per-inch (replaces the yarn-weight picker): wrap the yarn
            // snugly around a ruler for an inch, count the wraps, and seed the gauge from the inferred
            // weight band.
            Row(
              children: [
                SizedBox(
                  width: 150,
                  child: TextField(
                    controller: _wpi,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(labelText: 'Wraps per inch', isDense: true),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: _wpiSeed()),
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
            Text('Seed from a measured WPI, or enter your swatch. Stitches/rows per $_windowLabel.',
                style: muted),

            const Divider(height: 32),

            // --- Cast-on: target width + ease -> stitches. ---
            Text('Cast-on stitches', style: text.titleSmall),
            Text(
              switch (patternCastOn) {
                null => 'Pattern cast-on: not set',
                1 => 'Pattern cast-on: 1 stitch',
                final n => 'Pattern cast-on: $n stitches',
              },
              style: muted,
            ),
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
            if (_castOnTrace != null) EstimateTrace(estimate: _castOnTrace!),
            if (_castOnApplicable)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    OutlinedButton(
                      onPressed: _applyCastOn,
                      child: const Text('Set as pattern cast-on'),
                    ),
                    const SizedBox(width: 16),
                    if (_castOnApplied)
                      Expanded(
                        child: Semantics(
                          liveRegion: true,
                          child: Text('Saved to the pattern', style: text.bodyMedium),
                        ),
                      ),
                  ],
                ),
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
                      Text('With 10% buffer: ${_fmt(_yardsBuffered ?? _yards! * 1.1)} yards',
                          style: text.bodyLarge),
                      if (_yardTrace != null) EstimateTrace(estimate: _yardTrace!),
                    ],
                  ),
                ),
              ),
            if (_planError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_planError!,
                    key: const ValueKey('plan-error'),
                    style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
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

  /// The WPI -> yarn-weight seed beside the WPI field: once a usable WPI is typed, a tappable button
  /// naming the inferred weight band and filling the stitch/row gauge fields; a muted hint otherwise.
  Widget _wpiSeed() {
    final weight = yarnWeightFromWpi(double.tryParse(_wpi.text.trim()) ?? 0);
    final muted = Theme.of(context)
        .textTheme
        .bodySmall
        ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant);
    if (weight.stitchesPerWindow <= 0) {
      return Text('Type a WPI to estimate the yarn weight', style: muted);
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: OutlinedButton(
        onPressed: () => _seedFromWpi(weight),
        child: Text('Use ${weight.stitchesPerWindow.round()} sts (${weight.name})',
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    );
  }

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
