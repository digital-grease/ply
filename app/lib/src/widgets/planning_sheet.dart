// The planning calculator: a modal bottom sheet with two independent, button-computed sections —
// a SETT suggestion (WPI + structure -> ends/in) and a WARP-yarn estimate (a 5-field plan -> length
// + total). Pure planning aid: it reads the open draft (to seed the warp's "ends" and to label
// lengths in the draft's unit) but NEVER mutates it (no reducer, no undo entry). The FFI lives in the
// repository; the sett section works on a blank draft (a weaver sizes the sett before threading),
// only the warp section needs ends.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/draft_doc.dart';
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import '../state/theme_providers.dart';
import 'adaptive_sheet.dart';

/// Craft Yarn Council weights with their approximate wraps-per-inch midpoint (mirrors
/// `ply_common::YarnWeight::typical_wpi`), used to SEED the WPI field so a weaver who hasn't measured
/// their own can start from a rule of thumb.
const List<(String, double)> _yarnWeightWpi = [
  ('Lace (0)', 18),
  ('Super fine (1) · fingering', 14),
  ('Fine (2) · sport', 12),
  ('Light (3) · DK', 11),
  ('Medium (4) · worsted/aran', 9),
  ('Bulky (5)', 7),
  ('Super bulky (6)', 5),
  ('Jumbo (7)', 3),
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

  @override
  void initState() {
    super.initState();
    // Seed the warp "ends" from the open draft (overridable).
    final ends = ref.read(draftEditorProvider).draft.ends;
    if (ends > 0) _ends.text = '$ends';
  }

  @override
  void dispose() {
    for (final c in [
      _wpi, _sett, _finished, _items, _ends, _loomWaste, _takeup, //
      _ppi, _width, _wovenLength, _weftItems, _weftTakeup,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The GLOBAL unit preference (Settings), not the draft's stored unit: the calculator is a planning
  /// aid the weaver enters numbers into, so it follows their chosen units.
  bool get _metric => ref.watch(appSettingsProvider).unit == MeasureUnit.centimeters;
  String get _unit => _metric ? 'cm' : 'in';

  /// Long-length display for the warp/weft totals, which run to many yards: metric -> meters (÷100),
  /// imperial -> yards (÷36). Inputs stay in [_unit]; only these long outputs convert.
  String get _longUnit => _metric ? 'm' : 'yd';
  double _toLong(double v) => v / (_metric ? 100 : 36);

  Future<void> _suggestSett() async {
    if (!_settForm.currentState!.validate()) return;
    final wpi = double.parse(_wpi.text.trim());
    final sett = await ref.read(repositoryProvider).suggestSettCalc(wpi, _structure);
    // Fill the editable sett field; a WPI too low to suggest a usable sett leaves it blank.
    if (mounted) setState(() => _sett.text = sett >= 1 ? _fmt(sett) : '');
  }

  Future<void> _estimateWarp() async {
    if (!_warpForm.currentState!.validate()) return;
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
    final weft = await ref.read(repositoryProvider).estimateWeftPlan(
          picksPerUnit: double.parse(_ppi.text.trim()),
          width: double.parse(_width.text.trim()),
          wovenLength: double.parse(_wovenLength.text.trim()),
          items: int.parse(_weftItems.text.trim()),
          takeupPercent: double.parse(_weftTakeup.text.trim()),
        );
    if (mounted) setState(() => _weft = weft);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
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

            // --- Sett (ends/in) — independent of the draft, usable on a blank draft. ---
            Text('Sett (ends per inch)', style: text.titleSmall),
            const SizedBox(height: 4),
            // Optional shortcut: seed the WPI field from a yarn weight when you haven't measured your
            // own. Momentary (value stays null), so it acts like a button per option.
            DropdownButton<int>(
              isExpanded: true,
              value: null,
              hint: const Text('Seed WPI from yarn weight (optional)'),
              items: [
                for (var i = 0; i < _yarnWeightWpi.length; i++)
                  DropdownMenuItem(value: i, child: Text(_yarnWeightWpi[i].$1)),
              ],
              onChanged: (i) {
                if (i != null) setState(() => _wpi.text = _fmt(_yarnWeightWpi[i].$2));
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
            // The sett rules of thumb are imperial; WPI is per-inch regardless of the draft's unit.
            Text('Ends per inch (imperial rule of thumb).',
                style: text.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),

            const Divider(height: 32),

            // --- Warp yarn estimate — seeds ends from the draft. ---
            Text('Estimate warp yarn', style: text.titleSmall),
            Form(
              key: _warpForm,
              child: Column(
                children: [
                  _numField(_finished, 'Finished length ($_unit)', _positive),
                  _numField(_items, 'Items', _positiveInt, decimal: false),
                  _numField(_ends, 'Warp ends', _positiveInt, decimal: false),
                  _numField(_loomWaste, 'Loom waste ($_unit)', _nonNegative),
                  _numField(_takeup, 'Take-up + shrinkage (%)', _nonNegative),
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
                      Text('Warp length: ${_fmt(_toLong(_warp!.$1))} $_longUnit', style: text.bodyLarge),
                      Text('Total warp yarn: ${_fmt(_toLong(_warp!.$2))} $_longUnit',
                          style: text.bodyLarge),
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
                  _numField(_wovenLength, 'Woven length ($_unit)', _positive),
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
                    ],
                  ),
                ),
              ),
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
        keyboardType: TextInputType.numberWithOptions(decimal: decimal),
        inputFormatters: [
          FilteringTextInputFormatter.allow(decimal ? RegExp(r'[0-9.]') : RegExp(r'[0-9]')),
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
