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

/// Open the planning calculator. Call from a context inside the editor's ProviderScope (the
/// DimensionsBar chip) so the sheet's `ref` resolves the draft.
Future<void> showPlanningSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const PlanningSheet(),
  );
}

class PlanningSheet extends ConsumerStatefulWidget {
  const PlanningSheet({super.key});

  @override
  ConsumerState<PlanningSheet> createState() => _PlanningSheetState();
}

class _PlanningSheetState extends ConsumerState<PlanningSheet> {
  final _settForm = GlobalKey<FormState>();
  final _warpForm = GlobalKey<FormState>();

  final _wpi = TextEditingController();
  String _structure = 'plain';
  double? _sett;

  final _finished = TextEditingController();
  final _items = TextEditingController(text: '1');
  final _ends = TextEditingController();
  final _loomWaste = TextEditingController(text: '0');
  final _takeup = TextEditingController(text: '10');
  (double, double)? _warp;

  @override
  void initState() {
    super.initState();
    // Seed the warp "ends" from the open draft (overridable).
    final ends = ref.read(draftEditorProvider).draft.ends;
    if (ends > 0) _ends.text = '$ends';
  }

  @override
  void dispose() {
    for (final c in [_wpi, _finished, _items, _ends, _loomWaste, _takeup]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _unit =>
      ref.read(draftEditorProvider).draft.unit == MeasureUnit.centimeters ? 'cm' : 'in';

  Future<void> _suggestSett() async {
    if (!_settForm.currentState!.validate()) return;
    final wpi = double.parse(_wpi.text.trim());
    final sett = await ref.read(repositoryProvider).suggestSettCalc(wpi, _structure);
    if (mounted) setState(() => _sett = sett);
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
            Text('Suggest a sett', style: text.titleSmall),
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
              children: [
                FilledButton.tonal(onPressed: _suggestSett, child: const Text('Suggest sett')),
                const SizedBox(width: 16),
                if (_sett != null)
                  Expanded(
                    child: Semantics(
                      liveRegion: true,
                      // A small WPI rounds to a 0 sett; say so rather than show a useless "0 ends/in".
                      child: Text(
                        _sett! < 1 ? 'WPI too low to suggest a sett' : '${_fmt(_sett!)} ends/in',
                        style: text.titleMedium,
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
                      Text('Warp length: ${_fmt(_warp!.$1)} $_unit', style: text.bodyLarge),
                      Text('Total warp yarn: ${_fmt(_warp!.$2)} $_unit', style: text.bodyLarge),
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
