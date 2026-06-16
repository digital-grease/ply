import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/double_weave_layers.dart';
import '../models/draft_doc.dart';
import '../state/editor_providers.dart';
import '../widgets/drawdown_view.dart';

/// Which cloth the [LayerInspectorScreen] is showing.
enum _LayerChoice { combined, front, back }

/// A read-only inspector for a double weave's two layers: a Combined / Front / Back switch over a
/// single cloth view. Combined is the whole drawdown; Front/Back render the layer's own face by
/// narrowing the draft to that layer's ends + picks (see [doubleWeaveLayerDraft]) and feeding it
/// through the SAME renderer — no engine changes. Decoupled from the editing grids on purpose (a
/// layer's cloth is a different size than the full draft, so it can't align with the threading grid).
class LayerInspectorScreen extends ConsumerStatefulWidget {
  const LayerInspectorScreen({required this.draft, super.key});

  /// A snapshot of the draft to inspect (taken when the inspector opens).
  final DraftDoc draft;

  @override
  ConsumerState<LayerInspectorScreen> createState() => _LayerInspectorScreenState();
}

class _LayerInspectorScreenState extends ConsumerState<LayerInspectorScreen> {
  _LayerChoice _choice = _LayerChoice.combined;
  ui.Image? _image;
  String? _error;
  bool _loading = true;

  /// True when the selected layer has no threads at all (e.g. a single-pick draft has no back layer,
  /// or a non-double-weave whose ends all sit on one shaft parity). A 0x0 cloth can't be rendered, so
  /// we show a message instead of feeding an empty image to [DrawdownView] (its AspectRatio would be
  /// 0/0 = NaN).
  bool _empty = false;

  /// Monotonic guard so a slow render for a previous choice can't paint over a newer one (the renders
  /// are async FFI hops with no ordering guarantee), mirroring the editor's preview provider.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _render();
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  DraftDoc _draftFor(_LayerChoice choice) => switch (choice) {
        _LayerChoice.combined => widget.draft,
        _LayerChoice.front => doubleWeaveLayerDraft(widget.draft, DoubleWeaveLayer.front),
        _LayerChoice.back => doubleWeaveLayerDraft(widget.draft, DoubleWeaveLayer.back),
      };

  Future<void> _render() async {
    final repo = ref.read(repositoryProvider);
    final draft = _draftFor(_choice);
    final mySeq = ++_seq;
    if (draft.ends == 0 || draft.picks == 0) {
      setState(() {
        _loading = false;
        _error = null;
        _empty = true;
        _image?.dispose();
        _image = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _empty = false;
    });
    try {
      final img = await repo.renderDto(draft, cellPx: 18, gridlines: true);
      if (!mounted || mySeq != _seq) {
        img.dispose(); // superseded by a newer choice / torn down: free it, never show it
        return;
      }
      setState(() {
        _image?.dispose(); // the previous frame is no longer shown
        _image = img;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _error = 'Could not render this layer: $e';
        _loading = false;
      });
    }
  }

  void _select(_LayerChoice choice) {
    if (choice == _choice) return;
    setState(() => _choice = choice);
    _render();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Layers')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: SegmentedButton<_LayerChoice>(
                segments: const [
                  ButtonSegment(value: _LayerChoice.combined, label: Text('Combined')),
                  ButtonSegment(value: _LayerChoice.front, label: Text('Front')),
                  ButtonSegment(value: _LayerChoice.back, label: Text('Back')),
                ],
                selected: {_choice},
                onSelectionChanged: (s) => _select(s.first),
              ),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: Center(
                child: _loading
                    ? const CircularProgressIndicator()
                    : _empty
                        ? const Text('This layer has no threads.', textAlign: TextAlign.center)
                        : _error != null
                            ? Text(_error!, textAlign: TextAlign.center)
                            : _image != null
                                ? DrawdownView(_image!)
                                : const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _choice == _LayerChoice.combined
                  ? 'The whole cloth, both layers interlaced as woven.'
                  : "The ${_choice == _LayerChoice.front ? 'front (top)' : 'back (bottom)'} layer's "
                      'cloth on its own.',
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(
              'Layers are split by the double-weave convention: front = odd shafts, back = even '
              'shafts. Exact for generated double weave; a best guess for other cloth.',
              style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
