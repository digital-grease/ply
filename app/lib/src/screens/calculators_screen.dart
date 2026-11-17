import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/materials_repository.dart' show PlanException;
import '../models/draft_doc.dart' show MeasureUnit;
import '../models/knit_calculators.dart';
import '../models/material_record.dart';
import '../state/material_providers.dart';
import '../state/theme_providers.dart';
import '../widgets/record_report_panel.dart' show EstimateTrace;
import '../widgets/swatch_choice.dart';

/// The Calculators tab: standalone knitting maths usable WITHOUT an open pattern. A shared gauge feeds
/// the cast-on, yardage, and resize calculators; everything computes live. The maths live in
/// `knit_calculators.dart` (pure, host-tested). References: worldknits.com + knitterskitchen.com.
///
/// Units follow the GLOBAL Imperial/Metric preference (Settings), shared with the weaving calculator;
/// the in/cm toggle here just sets that same preference.
class CalculatorsScreen extends ConsumerStatefulWidget {
  const CalculatorsScreen({super.key});

  @override
  ConsumerState<CalculatorsScreen> createState() => _CalculatorsScreenState();
}

class _CalculatorsScreenState extends ConsumerState<CalculatorsScreen> {
  final _gaugeSts = TextEditingController(text: '20');
  // Wraps-per-inch -> a yarn-weight guess that can seed the stitch gauge above.
  final _wpi = TextEditingController();
  // Cast-on.
  final _coWidth = TextEditingController(text: '20');
  final _coEase = TextEditingController(text: '2');
  final _coRepeat = TextEditingController(text: '1');
  // Yardage.
  final _yWidth = TextEditingController(text: '20');
  final _yLength = TextEditingController(text: '24');
  // Resize.
  final _rzPatternGauge = TextEditingController(text: '22');
  final _rzPatternSts = TextEditingController(text: '120');
  // Increase / decrease evenly.
  final _ddCurrent = TextEditingController(text: '60');
  final _ddChange = TextEditingController(text: '6');
  bool _ddIncrease = true;

  // A recorded swatch the gauge comes from (ADR 0016), by id: the record is looked up in the library
  // each time, so an edited swatch is used as it is now and a deleted one clears the choice (this tab
  // stays mounted under the Materials screen). While the gauge field still shows what the swatch
  // filled in, the cast-on and the yarn estimate are worked out by the engine from the swatch itself
  // and list where every input came from.
  String? _swatchId;
  SwatchRecord? _swatchSeen;
  String? _filledSts;
  TracedEstimate<int>? _castOnTrace;
  TracedEstimate<YarnAmount>? _yarnTrace;
  String? _castOnError;
  String? _yarnError;
  int _traceSeq = 0;

  @override
  void dispose() {
    for (final c in [
      _gaugeSts, _wpi, _coWidth, _coEase, _coRepeat, _yWidth, _yLength,
      _rzPatternGauge, _rzPatternSts, _ddCurrent, _ddChange,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The unit preference read outside build (callbacks and the async re-trace).
  bool get _metricNow => ref.read(appSettingsProvider).unit == MeasureUnit.centimeters;

  Length get _windowLength =>
      _metricNow ? const Length(10, LengthUnit.centimeter) : const Length(4, LengthUnit.inch);

  /// The chosen swatch as the library holds it now, or null.
  SwatchRecord? _currentSwatch() {
    final id = _swatchId;
    return id == null ? null : ref.read(materialLibraryProvider).valueOrNull?.swatch(id);
  }

  /// Fill the gauge field from [s] at the window of the app's units.
  void _fillFrom(SwatchRecord? s) {
    _filledSts = null;
    final across = s?.planningAcross;
    if (across != null) {
      _gaugeSts.text = filledNumber(across.$1.value.per(_windowLength));
      _filledSts = _gaugeSts.text;
    }
  }

  void _useSwatch(SwatchRecord? s) {
    setState(() {
      _swatchId = s?.id;
      _swatchSeen = s;
      _castOnTrace = _yarnTrace = null;
      _castOnError = _yarnError = null;
      _fillFrom(s);
    });
    _retrace();
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

  /// The units changed: a gauge the swatch filled in is filled in again for the new window.
  void _onUnits() {
    if (!mounted) return;
    final s = _currentSwatch();
    if (s != null && _filledSts != null && _gaugeSts.text == _filledSts) {
      setState(() => _fillFrom(s));
    }
    _retrace();
  }

  /// Set the gauge field from code (the WPI seed), and work the estimates out again.
  void _setGauge(String text) {
    setState(() => _gaugeSts.text = text);
    _retrace();
  }

  /// Work the cast-on and the yarn estimate out again with the engine, latest wins, while a swatch
  /// is in use. Each has its own error, so one that cannot be worked out never hides the other.
  Future<void> _retrace() async {
    final swatch = _currentSwatch();
    final seq = ++_traceSeq;
    if (swatch == null) return;
    final unit = _metricNow ? LengthUnit.centimeter : LengthUnit.inch;
    final gauge = _filledSts != null && _gaugeSts.text == _filledSts
        ? const PlanInput<CountOver>.swatch()
        : PlanInput(InputOrigin.entered, CountOver(_d(_gaugeSts), _windowLength));
    final repo = ref.read(materialsRepositoryProvider);
    TracedEstimate<int>? castOn;
    String? castOnError;
    try {
      castOn = await repo.castOnTraced(
        swatch: swatch,
        gauge: gauge,
        width: Length(_d(_coWidth), unit),
        ease: Length(_d(_coEase), unit),
        repeat: _i(_coRepeat, 1),
      );
    } on PlanException catch (e) {
      castOnError = e.message;
    } catch (_) {
      castOnError = 'The cast-on could not be worked out.';
    }
    TracedEstimate<YarnAmount>? yarn;
    String? yarnError;
    try {
      yarn = await repo.yardageTraced(
        swatch: swatch,
        yarn: singleYarnOf(ref, swatch),
        gauge: gauge,
        width: Length(_d(_yWidth), unit),
        length: Length(_d(_yLength), unit),
        buffer: const PlanInput(InputOrigin.plyDefault, 0.1),
      );
    } on PlanException catch (e) {
      yarnError = e.message;
    } catch (_) {
      yarnError = 'The yarn estimate could not be worked out.';
    }
    if (!mounted || seq != _traceSeq || _swatchId != swatch.id) return;
    setState(() {
      _castOnTrace = castOn;
      _castOnError = castOnError;
      _yarnTrace = yarn;
      _yarnError = yarnError;
    });
  }

  double _d(TextEditingController c) => double.tryParse(c.text.trim()) ?? 0;
  int _i(TextEditingController c, [int fallback = 0]) => int.tryParse(c.text.trim()) ?? fallback;

  /// The GLOBAL unit preference (Settings), shared with the weaving calculator.
  bool get _metric => ref.watch(appSettingsProvider).unit == MeasureUnit.centimeters;
  String get _unit => _metric ? 'cm' : 'in';
  String get _window => _metric ? '10 cm' : '4 in';

  @override
  Widget build(BuildContext context) {
    final gaugeSts = _d(_gaugeSts);

    final castOn = castOnForWidth(
      gaugeStitches: gaugeSts,
      metric: _metric,
      width: _d(_coWidth),
      ease: _d(_coEase),
      repeat: _i(_coRepeat, 1),
    );
    final yards = yardageStockinette(
      gaugeStitches: gaugeSts,
      metric: _metric,
      width: _d(_yWidth),
      length: _d(_yLength),
    );
    final resized = resizeToGauge(
      patternStitches: _i(_rzPatternSts),
      patternGauge: _d(_rzPatternGauge),
      yourGauge: gaugeSts,
    );
    final spread = distributeEvenly(total: _i(_ddCurrent), count: _i(_ddChange));
    final swatches = swatchesForCraft(ref, SwatchCraft.knitting);
    // The swatch may be edited or deleted elsewhere while this tab stays mounted, and the units may
    // change: follow both.
    ref.listen(materialLibraryProvider, (_, next) => _onLibrary(next.valueOrNull));
    ref.listen(appSettingsProvider.select((a) => a.unit), (_, __) => _onUnits());
    final swatch = _swatchId == null ? null : swatches.where((x) => x.id == _swatchId).firstOrNull;

    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          // Shared gauge.
          _card(
            'Your gauge',
            [
              Row(
                children: [
                  Expanded(child: _num(_gaugeSts, 'Stitches per $_window')),
                  const SizedBox(width: 12),
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('in')),
                      ButtonSegment(value: true, label: Text('cm')),
                    ],
                    selected: {_metric},
                    // Writes the GLOBAL preference, so the whole app's calculators stay in one unit.
                    onSelectionChanged: (s) => ref.read(appSettingsProvider.notifier).setUnit(
                        s.first ? MeasureUnit.centimeters : MeasureUnit.inches),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Don't know your gauge? Measure WPI (wrap the yarn around a ruler for an inch) to
              // estimate the yarn weight and seed the stitch gauge above.
              Row(
                children: [
                  Expanded(child: _num(_wpi, 'Wraps per inch (WPI)')),
                  const SizedBox(width: 12),
                  Expanded(child: _wpiSeed()),
                ],
              ),
              // A recorded knitting swatch, when there is one: fills the gauge from what it measured.
              if (swatches.isNotEmpty) ...[
                const SizedBox(height: 10),
                SwatchChooser(swatches: swatches, selected: swatch, onChanged: _useSwatch),
              ],
            ],
          ),

          _card(
            'Cast on for a width',
            [
              Row(
                children: [
                  Expanded(child: _num(_coWidth, 'Width ($_unit)')),
                  const SizedBox(width: 12),
                  Expanded(child: _num(_coEase, 'Ease ($_unit)')),
                  const SizedBox(width: 12),
                  Expanded(child: _num(_coRepeat, 'St repeat')),
                ],
              ),
              if (_swatchId != null && _castOnError != null)
                _error('cast-on-error', _castOnError!)
              else
                _result('Cast on ${_castOnTrace?.value ?? castOn} stitches'),
              if (_castOnTrace != null && _castOnError == null)
                EstimateTrace(estimate: _castOnTrace!),
            ],
          ),

          _card(
            'Resize a pattern to your gauge',
            [
              Row(
                children: [
                  Expanded(child: _num(_rzPatternSts, 'Pattern stitches')),
                  const SizedBox(width: 12),
                  Expanded(child: _num(_rzPatternGauge, 'Pattern sts/$_window')),
                ],
              ),
              _result('Work $resized stitches'),
              _note('Stitch-count only — re-check row counts and shaping yourself.'),
            ],
          ),

          _card(
            'Increase / decrease evenly',
            [
              Row(
                children: [
                  Expanded(child: _num(_ddCurrent, 'Current stitches')),
                  const SizedBox(width: 12),
                  Expanded(child: _num(_ddChange, _ddIncrease ? 'Increases' : 'Decreases')),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Increase')),
                  ButtonSegment(value: false, label: Text('Decrease')),
                ],
                selected: {_ddIncrease},
                onSelectionChanged: (s) => setState(() => _ddIncrease = s.first),
              ),
              _result(_spreadText(spread, _ddIncrease)),
            ],
          ),

          _card(
            'Yarn estimate',
            [
              Row(
                children: [
                  Expanded(child: _num(_yWidth, 'Width ($_unit)')),
                  const SizedBox(width: 12),
                  Expanded(child: _num(_yLength, 'Length ($_unit)')),
                ],
              ),
              if (_swatchId != null && _yarnError != null)
                _error('yarn-error', _yarnError!)
              else
                _result('~${(_yarnTrace?.value.bufferedYards ?? yards).round()} yards'),
              if (_yarnTrace != null && _yarnError == null)
                EstimateTrace(estimate: _yarnTrace!)
              else if (_swatchId == null)
                _note('Rough stockinette estimate (+10% buffer); swatch-and-weigh for accuracy.'),
            ],
          ),
        ],
      ),
    );
  }

  String _spreadText(EvenSpread s, bool increase) {
    final verb = increase ? 'increase' : 'decrease';
    if (s.count <= 0) return 'Enter how many to $verb.';
    if (s.longGapCount == 0) {
      return 'Work $verb every ${s.shortGap} sts, ${s.count} times.';
    }
    return '$verb after ${s.shortGap} sts ${s.shortGapCount}×, and after ${s.longGap} sts '
        '${s.longGapCount}× (${s.count} total) — spread the longer gaps out.';
  }

  Widget _card(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 10),
              ...children,
            ],
          ),
        ),
      );

  Widget _num(TextEditingController c, String label) => TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
        onChanged: (_) {
          setState(() {});
          _retrace();
        },
        decoration: InputDecoration(labelText: label, isDense: true),
      );

  /// The WPI -> yarn-weight seed beside the WPI field: once a usable WPI is typed, a tappable button
  /// naming the inferred weight and filling the stitch-gauge field above; a muted hint otherwise.
  Widget _wpiSeed() {
    final weight = yarnWeightFromWpi(_d(_wpi));
    if (weight.stitchesPerWindow <= 0) {
      return Text(
        'Estimates yarn weight',
        style: Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
    final sts = weight.stitchesPerWindow.round();
    return OutlinedButton(
      onPressed: () => _setGauge('$sts'),
      child: Text('Use $sts sts (${weight.name})',
          maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _error(String key, String text) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(text,
            key: ValueKey(key), style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );

  Widget _result(String text) => Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
        ),
      );

  Widget _note(String text) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Text(text,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
}
