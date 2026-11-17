// The planning calculator: a modal bottom sheet with two independent, button-computed sections —
// a SETT suggestion (WPI + structure -> ends/in) and a WARP-yarn estimate (a 5-field plan -> length
// + total). Pure planning aid: it reads the open draft (to seed the warp's "ends" and to label
// lengths in the draft's unit) but NEVER mutates it (no reducer, no undo entry). The FFI lives in the
// repository; the sett section works on a blank draft (a weaver sizes the sett before threading),
// only the warp section needs ends.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/materials_repository.dart' show PlanException;
import '../models/draft_doc.dart';
import '../models/material_record.dart';
import '../models/weft_work.dart' show meanStrands;
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import '../state/material_providers.dart';
import '../state/theme_providers.dart';
import 'adaptive_sheet.dart';
import 'record_report_panel.dart' show EstimateTrace;
import 'swatch_choice.dart';

/// Common WEAVING yarns (count / ply notation) with their approximate wraps-per-inch, used to SEED the
/// WPI field so a weaver who hasn't measured can start from a rule of thumb. Weaving yarns use count
/// systems (8/2 = size 8, 2-ply), NOT the knitting CYC weights — and the SAME count is a different
/// size in different fibers (cotton, linen, and wool use different count bases), so each fiber is
/// listed separately. WPI is approximate (sources: the Handwoven Master Yarn Chart, Schacht's sett
/// chart, Gist Yarn); adjust to your actual yarn. Also offered by the warp and weft plan (ADR 0019)
/// as typical values to start from, never as a measurement.
const List<(String, double)> kYarnCountWpi = [
  // Cotton (cotton count; the most common weaving yarn).
  ('3/2 cotton', 21),
  ('5/2 cotton', 26),
  ('8/2 cotton', 32),
  ('10/2 cotton', 37),
  ('16/2 cotton', 46),
  ('20/2 cotton', 52),
  ('8/4 cotton (carpet warp)', 21),
  // Tencel / bamboo (cotton-count base; slick, so sett a touch closer).
  ('8/2 Tencel', 32),
  ('10/2 Tencel', 37),
  // Linen (lea count — "8/2 linen" is much thicker than 8/2 cotton).
  ('8/2 linen', 21),
  ('16/2 linen', 30),
  // Wool (ply/count; worsted-count base).
  ('2/8 wool (worsted)', 22),
  ('2/18 wool (worsted)', 38),
  // Silk (spun, 2-ply).
  ('2/20 silk', 40),
  ('2/30 silk', 52),
];

/// Open the planning calculator. Call from a context inside the editor's ProviderScope (the
/// DimensionsBar chip) so the sheet's `ref` resolves the draft. Adaptive: a bottom sheet on phones,
/// a centered dialog on tablet/wide screens.
Future<void> showPlanningSheet(BuildContext context) {
  return showAdaptiveSheet<void>(context, child: const PlanningSheet());
}

class PlanningSheet extends ConsumerStatefulWidget {
  const PlanningSheet({super.key});

  @override
  ConsumerState<PlanningSheet> createState() => _PlanningSheetState();
}

class _PlanningSheetState extends ConsumerState<PlanningSheet> {
  final _settForm = GlobalKey<FormState>();
  final _warpForm = GlobalKey<FormState>();
  final _weftForm = GlobalKey<FormState>();

  final _wpi = TextEditingController();
  String _structure = 'plain';
  final _sett = TextEditingController(); // editable: "Suggest" fills it, the weaver can override
  final _settWidth = TextEditingController(); // a width to turn the sett into a warp-end count

  final _finished = TextEditingController();
  final _items = TextEditingController(text: '1');
  final _ends = TextEditingController();
  final _loomWaste = TextEditingController(text: '0');
  final _takeup = TextEditingController(text: '10');
  (double, double)? _warp;

  final _ppi = TextEditingController();
  final _width = TextEditingController();
  final _wovenLength = TextEditingController();
  final _weftItems = TextEditingController(text: '1');
  final _weftTakeup = TextEditingController(text: '10');
  (int, double)? _weft;

  // A swatch the sett, the take-up and the picks may come from (ADR 0016). While a field still holds
  // what the swatch filled in, the estimate takes that input from the swatch itself and the result
  // lists where every input came from.
  // Kept by id and looked up in the library each time, so an edited swatch is used as it is now and a
  // deleted one clears the choice.
  String? _swatchId;
  SwatchRecord? _swatchSeen;
  String? _filledSett;
  String? _filledTakeup;
  String? _filledPpi;
  String? _draftEnds;
  ({String text, Length width})? _endsFromSwatchSett;
  TracedEstimate<WarpAmount>? _warpTrace;
  TracedEstimate<WeftAmount>? _weftTrace;
  String? _planError;
  String? _swatchNote;

  /// The starting values the warp and weft sections show, which count as Ply's defaults until the
  /// weaver changes them.
  static const String _defaultTakeup = '10';
  static const String _defaultWaste = '0';

  @override
  void initState() {
    super.initState();
    // Seed the warp "ends" from the open draft (overridable).
    final ends = ref.read(draftEditorProvider).draft.ends;
    if (ends > 0) _ends.text = '$ends';
    if (ends > 0) _draftEnds = '$ends';
    // Recompute the sett -> ends helper as either input changes.
    _sett.addListener(_onSettInputs);
    _settWidth.addListener(_onSettInputs);
  }

  void _onSettInputs() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [
      _wpi, _sett, _settWidth, _finished, _items, _ends, _loomWaste, _takeup, //
      _ppi, _width, _wovenLength, _weftItems, _weftTakeup,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Warp ends for the entered sett over the entered width: `sett (ends/in) × width`. The width is
  /// taken in the display unit and converted to inches (the sett is an imperial ends-per-inch value).
  /// Null until both a positive sett and width are entered.
  int? get _settEnds {
    final sett = double.tryParse(_sett.text.trim());
    final width = double.tryParse(_settWidth.text.trim());
    if (sett == null || sett <= 0 || width == null || width <= 0) return null;
    // While the sett field still holds the swatch's sett, count from the swatch's exact sett (the
    // field shows it rounded), the way the engine does, so the ends here and in the estimate agree.
    final exact = _fromSwatch(_sett, _filledSett) ? _swatch?.sett?.value : null;
    if (exact != null) return exact.per(Length(width, _shortUnit)).round();
    final widthInches = _metric ? width / 2.54 : width;
    return (sett * widthInches).round();
  }

  /// The GLOBAL unit preference (Settings), not the draft's stored unit: the calculator is a planning
  /// aid the weaver enters numbers into, so it follows their chosen units.
  bool get _metric => ref.watch(appSettingsProvider).unit == MeasureUnit.centimeters;
  String get _unit => _metric ? 'cm' : 'in';

  /// Long-length display for the warp/weft totals, which run to many yards: metric -> meters (÷100),
  /// imperial -> yards (÷36). Inputs stay in [_unit]; only these long outputs convert.
  String get _longUnit => _metric ? 'm' : 'yd';
  double _toLong(double v) => v / (_metric ? 100 : 36);

  /// Inverse of [_toLong]: a long-unit length (yd/m) back to the short unit (in/cm). Used where a
  /// long-unit INPUT must feed an engine term expressed per short unit (e.g. picks-per-inch ×
  /// woven-length must share one unit, so a woven length entered in yards converts to inches first).
  double _fromLong(double v) => v * (_metric ? 100 : 36);

  LengthUnit get _shortUnit => _metric ? LengthUnit.centimeter : LengthUnit.inch;
  LengthUnit get _longLengthUnit => _metric ? LengthUnit.meter : LengthUnit.yard;

  /// Fill the sett, the take-up and the picks from [s], where it measured them, or forget the swatch.
  void _useSwatch(SwatchRecord? s) {
    setState(() {
      _swatchId = s?.id;
      _swatchSeen = s;
      _filledSett = _filledTakeup = _filledPpi = null;
      _endsFromSwatchSett = null;
      _warpTrace = _weftTrace = null;
      _planError = null;
      _swatchNote = null;
      if (s == null) return;
      final missing = <String>[];
      final sett = s.sett?.value;
      if (sett != null) {
        _sett.text = filledNumber(sett.per(const Length(1, LengthUnit.inch)));
        _filledSett = _sett.text;
      } else {
        missing.add('sett in the reed');
      }
      final onLoom = s.onLoom.length?.value;
      final after = s.after.length?.value;
      if (onLoom != null && after != null) {
        final fraction =
            onLoom.inUnit(LengthUnit.centimeter) / after.inUnit(LengthUnit.centimeter) - 1;
        _takeup.text = filledNumber(fraction * 100);
        _filledTakeup = _takeup.text;
      } else {
        missing.add('lengths on the loom and after wet finishing');
      }
      final picks = s.onLoom.along?.value;
      if (picks != null) {
        _ppi.text = filledNumber(picks.per(Length(1, _shortUnit)));
        _filledPpi = _ppi.text;
      } else {
        missing.add('picks counted on the loom');
      }
      if (missing.isNotEmpty) {
        _swatchNote =
            'This swatch records no ${missing.join(', no ')}, so those fields stay as they are.';
      }
    });
  }

  /// The chosen swatch as the library holds it now, or null.
  SwatchRecord? get _swatch {
    final id = _swatchId;
    return id == null ? null : ref.read(materialLibraryProvider).valueOrNull?.swatch(id);
  }

  /// The library changed: a deleted swatch clears the choice; an edited one fills the fields again.
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

  bool _fromSwatch(TextEditingController c, String? filled) =>
      _swatch != null && filled != null && c.text == filled;

  /// The warp ends as a planning input: from the swatch's sett across the cloth width, from this
  /// draft, or as typed.
  PlanInput<int> get _endsInput {
    final n = int.tryParse(_ends.text.trim()) ?? 0;
    final fromSett = _endsFromSwatchSett;
    if (_swatch != null && fromSett != null && _ends.text == fromSett.text) {
      return const PlanInput.swatch();
    }
    if (_draftEnds != null && _ends.text == _draftEnds) {
      return PlanInput(InputOrigin.pattern, n, note: "this draft's ends");
    }
    return PlanInput(InputOrigin.entered, n);
  }

  PlanInput<double> _percentInput(TextEditingController c, String? filled, String detail) {
    if (_fromSwatch(c, filled)) return const PlanInput.swatch();
    final v = (double.tryParse(c.text.trim()) ?? 0) / 100;
    return c.text.trim() == _defaultTakeup
        ? PlanInput(InputOrigin.plyDefault, v, note: detail)
        : PlanInput(InputOrigin.entered, v);
  }

  Future<void> _suggestSett() async {
    if (!_settForm.currentState!.validate()) return;
    final wpi = double.parse(_wpi.text.trim());
    final sett = await ref.read(repositoryProvider).suggestSettCalc(wpi, _structure);
    // Fill the editable sett field; a WPI too low to suggest a usable sett leaves it blank.
    if (mounted) setState(() => _sett.text = sett >= 1 ? _fmt(sett) : '');
  }

  Future<void> _estimateWarp() async {
    if (!_warpForm.currentState!.validate()) return;
    if (_swatch != null) {
      final waste = double.parse(_loomWaste.text.trim());
      try {
        final t = await ref.read(materialsRepositoryProvider).warpTraced(
              swatch: _swatch,
              finishedLength: Length(double.parse(_finished.text.trim()), _longLengthUnit),
              items: int.parse(_items.text.trim()),
              ends: _endsInput,
              settWidth: _endsFromSwatchSett?.width,
              loomWaste: _loomWaste.text.trim() == _defaultWaste
                  ? PlanInput(InputOrigin.plyDefault, Length(waste, _longLengthUnit),
                      note: 'starting value: enter your own loom waste')
                  : PlanInput(InputOrigin.entered, Length(waste, _longLengthUnit)),
              allowance: _percentInput(_takeup, _filledTakeup,
                  'starting value: a sample of your own gives a better one'),
            );
        if (mounted) {
          setState(() {
            _warp = (t.value.warpLength.value, t.value.total.value);
            _warpTrace = t;
            _planError = null;
          });
        }
      } on PlanException catch (e) {
        if (mounted) setState(() => _planError = e.message);
      }
      return;
    }
    final warp = await ref.read(repositoryProvider).estimateWarpPlan(
          finishedLength: double.parse(_finished.text.trim()),
          items: int.parse(_items.text.trim()),
          ends: int.parse(_ends.text.trim()),
          loomWaste: double.parse(_loomWaste.text.trim()),
          takeupPercent: double.parse(_takeup.text.trim()),
        );
    if (mounted) setState(() => _warp = warp);
  }

  Future<void> _estimateWeft() async {
    if (!_weftForm.currentState!.validate()) return;
    if (_swatch != null) {
      final ppi = double.parse(_ppi.text.trim());
      try {
        final t = await ref.read(materialsRepositoryProvider).weftTraced(
              swatch: _swatch,
              ppi: _fromSwatch(_ppi, _filledPpi)
                  ? const PlanInput.swatch()
                  : PlanInput(InputOrigin.entered, CountOver(ppi, Length(1, _shortUnit))),
              width: Length(double.parse(_width.text.trim()), _shortUnit),
              wovenLength: Length(double.parse(_wovenLength.text.trim()), _longLengthUnit),
              items: int.parse(_weftItems.text.trim()),
              takeup: _percentInput(_weftTakeup, null, 'starting value for take-up and selvedges'),
              draft: ref.read(draftEditorProvider).draft,
            );
        if (mounted) {
          setState(() {
            _weft = (t.value.picks, t.value.total.inUnit(_shortUnit));
            _weftTrace = t;
            _planError = null;
          });
        }
      } on PlanException catch (e) {
        if (mounted) setState(() => _planError = e.message);
      }
      return;
    }
    final weft = await ref.read(repositoryProvider).estimateWeftPlan(
          picksPerUnit: double.parse(_ppi.text.trim()),
          width: double.parse(_width.text.trim()),
          // Woven length is entered in the long unit (yd/m) but picks-per-unit is per short unit, so
          // bring it back to the short unit (in/cm) before the engine multiplies the two into a pick
          // count.
          wovenLength: _fromLong(double.parse(_wovenLength.text.trim())),
          items: int.parse(_weftItems.text.trim()),
          takeupPercent: double.parse(_weftTakeup.text.trim()),
          // The draft's strands per pick (two yarns in one pass use twice the weft) are counted.
          draft: ref.read(draftEditorProvider).draft,
        );
    if (mounted) setState(() => _weft = weft);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // The chosen swatch may change or go while the sheet is open: follow the library.
    ref.listen(materialLibraryProvider, (_, next) => _onLibrary(next.valueOrNull));
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        // Lift the content above the on-screen keyboard so the numeric fields stay reachable.
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Planning calculator', style: text.titleMedium),
            const SizedBox(height: 16),
            // A recorded weaving swatch (only when there is one) fills the sett, the take-up and the
            // picks from what it measured.
            if (swatchesForCraft(ref, SwatchCraft.weaving).isNotEmpty) ...[
              SwatchChooser(
                  swatches: swatchesForCraft(ref, SwatchCraft.weaving),
                  selected: _swatch,
                  onChanged: _useSwatch),
              if (_swatchNote != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(_swatchNote!,
                      style: text.bodySmall
                          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              const SizedBox(height: 16),
            ],

            // --- Sett (ends/in) — independent of the draft, usable on a blank draft. ---
            Text('Sett (ends per inch)', style: text.titleSmall),
            const SizedBox(height: 4),
            // Optional shortcut: seed the WPI field from a yarn weight when you haven't measured your
            // own. Momentary (value stays null), so it acts like a button per option.
            DropdownButton<int>(
              isExpanded: true,
              value: null,
              hint: const Text('Seed WPI from yarn size (optional)'),
              items: [
                for (var i = 0; i < kYarnCountWpi.length; i++)
                  DropdownMenuItem(value: i, child: Text(kYarnCountWpi[i].$1)),
              ],
              onChanged: (i) {
                if (i != null) setState(() => _wpi.text = _fmt(kYarnCountWpi[i].$2));
              },
            ),
            const SizedBox(height: 4),
            Form(
              key: _settForm,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _wpi,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(
                        labelText: 'Wraps per inch',
                        hintText: 'e.g. 20',
                      ),
                      validator: _positive,
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButton<String>(
                    value: _structure,
                    onChanged: (v) => setState(() => _structure = v ?? 'plain'),
                    items: const [
                      DropdownMenuItem(value: 'plain', child: Text('Plain')),
                      DropdownMenuItem(value: 'twill', child: Text('Twill')),
                      DropdownMenuItem(value: 'satin', child: Text('Satin')),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.tonal(
                      onPressed: _suggestSett, child: const Text('Suggest sett')),
                ),
                const SizedBox(width: 16),
                // The sett is EDITABLE: "Suggest" fills it from WPI + structure, but the weaver can
                // type their own preferred sett over it.
                Expanded(
                  child: TextField(
                    controller: _sett,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                    decoration: const InputDecoration(
                      labelText: 'Sett (ends/in)',
                      hintText: 'or enter your own',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // Turn the sett into a warp-end count for a planned cloth width, then push it into the warp
            // estimate's "Warp ends" below.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _numField(_settWidth, 'Cloth width ($_unit)', _positive)),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: FilledButton.tonal(
                    onPressed: _settEnds == null
                        ? null
                        : () => setState(() {
                              _ends.text = '$_settEnds';
                              // Ends worked out from the swatch's own sett come from the swatch.
                              _endsFromSwatchSett = _fromSwatch(_sett, _filledSett)
                                  ? (
                                      text: _ends.text,
                                      width: Length(double.parse(_settWidth.text.trim()), _shortUnit)
                                    )
                                  : null;
                            }),
                    child: Text(_settEnds == null ? 'Warp ends' : 'Use $_settEnds warp ends'),
                  ),
                ),
              ],
            ),
            // The sett rules of thumb are imperial; WPI is per-inch regardless of the draft's unit.
            Text('Ends per inch (imperial rule of thumb). Width × sett gives the warp-end count.',
                style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),

            const Divider(height: 32),

            // --- Warp yarn estimate — seeds ends from the draft. ---
            Text('Estimate warp yarn', style: text.titleSmall),
            Form(
              key: _warpForm,
              child: Column(
                children: [
                  // Warp planning runs LONG, so its lengths are in the long unit (yd/m) — the same
                  // unit the warp-length + total outputs report, so the whole section is consistent
                  // (no inch inputs feeding a yardage result).
                  _numField(_finished, 'Finished length ($_longUnit)', _positive),
                  _numField(_items, 'Items', _positiveInt, decimal: false),
                  _numField(_ends, 'Warp ends', _positiveInt, decimal: false),
                  _numField(_loomWaste, 'Loom waste ($_longUnit)', _nonNegative),
                  // A sample can grow in finishing (more length after than on the loom), so this
                  // may be below 0, within the engine's range.
                  _numField(_takeup, 'Take-up + shrinkage (%)', _allowancePercent, signed: true),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonal(onPressed: _estimateWarp, child: const Text('Estimate warp')),
              ],
            ),
            if (_warp != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  container: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Inputs are already in the long unit, so the engine's result is too — show it
                      // directly (no _toLong, which is for sections whose inputs are in the short unit).
                      Text('Warp length: ${_fmt(_warp!.$1)} $_longUnit', style: text.bodyLarge),
                      Text('Total warp yarn: ${_fmt(_warp!.$2)} $_longUnit', style: text.bodyLarge),
                      if (_warpTrace != null) EstimateTrace(estimate: _warpTrace!),
                    ],
                  ),
                ),
              ),

            const Divider(height: 32),

            // --- Weft yarn estimate — picks/unit + woven width + woven length. ---
            Text('Estimate weft yarn', style: text.titleSmall),
            Form(
              key: _weftForm,
              child: Column(
                children: [
                  // picks_per_unit is per the DRAFT'S unit (the engine multiplies it by woven_length
                  // in that same unit), so label it per-unit, not a hardcoded "per inch".
                  _numField(_ppi, 'Picks per $_unit', _positive),
                  _numField(_width, 'Woven width ($_unit)', _positive),
                  // Woven length runs long, so it is entered in the long unit (yd/m) to match the
                  // warp section and the total-yarn output (no inch input feeding a yardage result).
                  _numField(_wovenLength, 'Woven length ($_longUnit)', _positive),
                  _numField(_weftItems, 'Items', _positiveInt, decimal: false),
                  _numField(_weftTakeup, 'Take-up + selvedge (%)', _nonNegative),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.tonal(onPressed: _estimateWeft, child: const Text('Estimate weft')),
              ],
            ),
            if (_weft != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Semantics(
                  liveRegion: true,
                  container: true,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total picks: ${_weft!.$1}', style: text.bodyLarge),
                      Text('Total weft yarn: ${_fmt(_toLong(_weft!.$2))} $_longUnit',
                          style: text.bodyLarge),
                      if (ref.read(draftEditorProvider).draft.pickStrands.isNotEmpty)
                        Text(
                            'Counts the strands carried in each pick of this draft: '
                            '${_fmt(meanStrands(ref.read(draftEditorProvider).draft))} per pick on '
                            'average, repeated over the woven length.',
                            key: const ValueKey('weft-strands-note'),
                            style: text.bodySmall),
                      if (_weftTrace != null) EstimateTrace(estimate: _weftTrace!),
                    ],
                  ),
                ),
              ),
            if (_planError != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_planError!,
                    key: const ValueKey('plan-error'),
                    style: text.bodyMedium?.copyWith(color: Theme.of(context).colorScheme.error)),
              ),
          ],
        ),
      ),
    );
  }

  Widget _numField(TextEditingController c, String label, FormFieldValidator<String> v,
      {bool decimal = true, bool signed = false}) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextFormField(
        controller: c,
        keyboardType: TextInputType.numberWithOptions(decimal: decimal, signed: signed),
        inputFormatters: [
          FilteringTextInputFormatter.allow(signed
              ? RegExp(r'[0-9.\-]')
              : decimal
                  ? RegExp(r'[0-9.]')
                  : RegExp(r'[0-9]')),
        ],
        decoration: InputDecoration(labelText: label),
        validator: v,
      ),
    );
  }

  // Sane ceilings, FAR above any real weaving plan, that keep the f32 estimate finite (no Infinity)
  // and the u32 wire fields from silently truncating mod 2^32. The repo wrapper also guards as a
  // backstop (mirroring the toDto wire-range guards).
  static const double _maxLen = 1000000;
  static const int _maxCount = 100000;

  static String? _positive(String? s) {
    final v = double.tryParse((s ?? '').trim());
    if (v == null || !v.isFinite || v <= 0) return 'Enter a number greater than 0';
    return v > _maxLen ? 'Too large' : null;
  }

  /// Take-up and shrinkage as a percentage, in the engine's range: from -90% (a sample that grew a
  /// lot in finishing) to 1000%.
  static String? _allowancePercent(String? s) {
    final v = double.tryParse((s ?? '').trim());
    if (v == null || !v.isFinite) return 'Enter a percentage';
    return v < -90 || v > 1000 ? 'Enter a percentage from -90 to 1000' : null;
  }

  static String? _nonNegative(String? s) {
    final v = double.tryParse((s ?? '').trim());
    if (v == null || !v.isFinite || v < 0) return 'Enter 0 or more';
    return v > _maxLen ? 'Too large' : null;
  }

  static String? _positiveInt(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null || v < 1) return 'Enter a whole number, at least 1';
    return v > _maxCount ? 'Too large' : null;
  }

  /// Trim a trailing ".0" so whole numbers read cleanly; otherwise 2 decimals. Guards the f32 edges:
  /// a non-finite result (overflow) reads "too large", and a tiny-but-nonzero result reads "<0.01"
  /// rather than a misleading "0".
  static String _fmt(double v) {
    if (!v.isFinite) return 'too large';
    if (v > 0 && v < 0.01) return '<0.01';
    final r = (v * 100).roundToDouble() / 100;
    return r == r.roundToDouble() ? r.toStringAsFixed(0) : r.toStringAsFixed(2);
  }
}
