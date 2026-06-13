// The "Generate structure" sheet (M3 Phase 3): a modal that lays down a complete weave structure —
// a plain / twill / satin tie-up plus a straight or point threading, sized to the entered ends x
// picks — and COMMITS it into the editor as one undo entry. The engine builds the tie-up/threading
// (the repo wrapper `generateStructureDoc`); this widget only collects parameters and commits.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../rust/dto.dart' show StructureFamily, ThreadingKind;
import '../state/draft_editor_notifier.dart';
import '../state/editor_providers.dart';
import 'adaptive_sheet.dart';

/// Open the structure generator. Call from a context inside the editor's ProviderScope. Adaptive: a
/// modal bottom sheet on phones, a centered dialog on tablet/wide screens.
Future<void> showStructureSheet(BuildContext context) {
  return showAdaptiveSheet<void>(context, child: const StructureSheet());
}

class StructureSheet extends ConsumerStatefulWidget {
  const StructureSheet({super.key});

  @override
  ConsumerState<StructureSheet> createState() => _StructureSheetState();
}

class _StructureSheetState extends ConsumerState<StructureSheet> {
  final _form = GlobalKey<FormState>();

  StructureFamily _family = StructureFamily.twill;
  ThreadingKind _threading = ThreadingKind.straight;

  final _over = TextEditingController(text: '2');
  final _under = TextEditingController(text: '2');
  final _shafts = TextEditingController(text: '4');
  final _counter = TextEditingController(text: '2');
  final _ends = TextEditingController(text: '16');
  final _picks = TextEditingController(text: '16');

  bool _generating = false;

  @override
  void initState() {
    super.initState();
    // Seed ends/picks from the current draft when it already has a cloth (overridable).
    final draft = ref.read(draftEditorProvider).draft;
    if (draft.ends > 0) _ends.text = '${draft.ends}';
    if (draft.picks > 0) _picks.text = '${draft.picks}';
  }

  @override
  void dispose() {
    for (final c in [_over, _under, _shafts, _counter, _ends, _picks]) {
      c.dispose();
    }
    super.dispose();
  }

  static const int _maxShafts = 200; // a generous loom ceiling, far below the u16 wire limit
  static const int _maxThreads = 100000;

  static int _gcd(int a, int b) => b == 0 ? a : _gcd(b, a % b);

  /// A counter is a valid SATIN move iff `1 < counter < shafts` and it shares no factor with
  /// `shafts` — otherwise the satin steps over a subset of shafts, leaving the rest never raised
  /// (full-length floats). Returns true when [shafts] is unknown (the shafts field validates that).
  static bool _validSatinCounter(int? counter, int? shafts) {
    if (counter == null) return false;
    if (shafts == null) return true;
    return counter > 1 && counter < shafts && _gcd(counter, shafts) == 1;
  }

  String? _shaftCount(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null || v < 1) return 'At least 1';
    return v > _maxShafts ? 'Too many' : null;
  }

  /// Shafts validator that depends on the family: plain needs >= 2 (one odd, one even); satin needs
  /// >= 5 (no true satin exists below 5 shafts).
  String? _structureShafts(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null) return 'At least 1';
    if (v > _maxShafts) return 'Too many';
    if (_family == StructureFamily.satin) return v < 5 ? 'Satin needs at least 5 shafts' : null;
    return v < 2 ? 'Plain needs at least 2 shafts' : null;
  }

  /// Satin counter validator (cross-field on the shafts value).
  String? _satinCounter(String? s) {
    final c = int.tryParse((s ?? '').trim());
    if (c == null || c < 1) return 'At least 1';
    final n = int.tryParse(_shafts.text.trim());
    if (n != null && n >= 2 && !_validSatinCounter(c, n)) {
      return 'Use a move between 2 and ${n - 1} sharing no factor with $n';
    }
    return null;
  }

  String? _threadCount(String? s) {
    final v = int.tryParse((s ?? '').trim());
    if (v == null || v < 1) return 'At least 1';
    return v > _maxThreads ? 'Too many' : null;
  }

  /// Switch families, seeding VALID defaults so a generate on the defaults always yields good cloth
  /// (the satin defaults must be coprime; the prior shafts default of 4 has no valid satin).
  void _onFamily(StructureFamily f) {
    setState(() {
      _family = f;
      if (f == StructureFamily.satin) {
        if ((int.tryParse(_shafts.text.trim()) ?? 0) < 5) _shafts.text = '5';
        if (!_validSatinCounter(int.tryParse(_counter.text.trim()), int.tryParse(_shafts.text.trim()))) {
          _counter.text = '2';
        }
      } else if (f == StructureFamily.plain) {
        if ((int.tryParse(_shafts.text.trim()) ?? 0) < 2) _shafts.text = '4';
      }
    });
  }

  Future<void> _generate() async {
    if (_generating || !_form.currentState!.validate()) return;
    // Read fields tolerantly: a field hidden for the current family (e.g. Shafts under Twill) is not
    // in the tree and so not validated, and may hold a stale/empty value — fall back rather than
    // throw a FormatException on int.parse.
    final shafts = int.tryParse(_shafts.text.trim()) ?? 4;
    final over = int.tryParse(_over.text.trim()) ?? 2;
    final under = int.tryParse(_under.text.trim()) ?? 2;
    final effShafts = _family == StructureFamily.twill ? over + under : shafts;
    if (effShafts > _maxShafts) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('That many shafts exceeds the loom (max 200).')));
      return;
    }
    setState(() => _generating = true);
    final navigator = Navigator.of(context);
    try {
      final repo = ref.read(repositoryProvider);
      final notifier = ref.read(draftEditorProvider.notifier);
      final base = ref.read(draftEditorProvider).draft;
      final doc = await repo.generateStructureDoc(
        base,
        family: _family,
        threading: _threading,
        shafts: shafts,
        over: over,
        under: under,
        counter: int.tryParse(_counter.text.trim()) ?? 2,
        ends: int.tryParse(_ends.text.trim()) ?? 16,
        picks: int.tryParse(_picks.text.trim()) ?? 16,
      );
      if (!mounted) return;
      notifier.commitEdit(doc); // one undo entry; replaces the cloth with the generated structure
      navigator.pop();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not generate: $e')));
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final isTwill = _family == StructureFamily.twill;
    final isSatin = _family == StructureFamily.satin;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.viewInsetsOf(context).bottom),
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Generate structure', style: text.titleMedium),
              const SizedBox(height: 4),
              Text('Replaces the threading, tie-up, and treadling with a generated weave.',
                  style: text.bodySmall
                      ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              const SizedBox(height: 16),

              DropdownButtonFormField<StructureFamily>(
                initialValue: _family,
                decoration: const InputDecoration(labelText: 'Structure'),
                onChanged: (v) => _onFamily(v ?? StructureFamily.twill),
                items: const [
                  DropdownMenuItem(value: StructureFamily.plain, child: Text('Plain weave')),
                  DropdownMenuItem(value: StructureFamily.twill, child: Text('Twill')),
                  DropdownMenuItem(value: StructureFamily.satin, child: Text('Satin')),
                ],
              ),

              // Family-specific parameters.
              if (isTwill)
                Row(
                  children: [
                    Expanded(child: _numField(_over, 'Over')),
                    const SizedBox(width: 12),
                    Expanded(child: _numField(_under, 'Under')),
                  ],
                ),
              if (!isTwill)
                _numField(_shafts, 'Shafts', _structureShafts),
              if (isSatin)
                _numField(_counter, 'Counter (satin move)', _satinCounter),

              const SizedBox(height: 4),
              DropdownButtonFormField<ThreadingKind>(
                initialValue: _threading,
                decoration: const InputDecoration(labelText: 'Threading'),
                onChanged: (v) => setState(() => _threading = v ?? ThreadingKind.straight),
                items: const [
                  DropdownMenuItem(value: ThreadingKind.straight, child: Text('Straight draw')),
                  DropdownMenuItem(value: ThreadingKind.point, child: Text('Point draw')),
                ],
              ),

              Row(
                children: [
                  Expanded(child: _numField(_ends, 'Warp ends', _threadCount)),
                  const SizedBox(width: 12),
                  Expanded(child: _numField(_picks, 'Picks', _threadCount)),
                ],
              ),
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: _generating ? null : _generate,
                  child: const Text('Generate'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _numField(TextEditingController c, String label, [FormFieldValidator<String>? validator]) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: TextFormField(
        controller: c,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
        decoration: InputDecoration(labelText: label),
        validator: validator ?? _shaftCount,
      ),
    );
  }
}
