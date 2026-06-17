import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/double_weave_layers.dart';
import '../models/draft_doc.dart';
import '../state/editor_providers.dart';
import '../widgets/drawdown_view.dart';

/// A read-only inspector for a double weave's two layers, shown as TWO drawdowns at once — the top
/// layer's cloth above the bottom layer's. A shaft picker lets the weaver assign which shafts belong
/// to the top layer (the rest are the bottom); the picks that weave each layer are derived from the
/// structure (see [doubleWeaveLayerDraft]). Each layer is rendered by narrowing the draft to that
/// layer's ends + picks and feeding it through the SAME renderer — no engine changes.
class LayerInspectorScreen extends ConsumerStatefulWidget {
  const LayerInspectorScreen({required this.draft, super.key});

  /// A snapshot of the draft to inspect (taken when the inspector opens).
  final DraftDoc draft;

  @override
  ConsumerState<LayerInspectorScreen> createState() => _LayerInspectorScreenState();
}

class _LayerInspectorScreenState extends ConsumerState<LayerInspectorScreen> {
  /// Shafts assigned to the TOP layer (the rest are bottom). Seeded to the odd shafts.
  late Set<int> _topShafts;

  ui.Image? _topImage;
  ui.Image? _bottomImage;
  bool _topEmpty = false;
  bool _bottomEmpty = false;
  bool _loading = true;
  String? _error;

  /// Monotonic guard so a slow render for a previous shaft assignment can't paint over a newer one.
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _topShafts = defaultTopShafts(widget.draft);
    _render();
  }

  @override
  void dispose() {
    _topImage?.dispose();
    _bottomImage?.dispose();
    super.dispose();
  }

  Future<void> _render() async {
    final repo = ref.read(repositoryProvider);
    final topDraft = doubleWeaveLayerDraft(widget.draft, topShafts: _topShafts, top: true);
    final botDraft = doubleWeaveLayerDraft(widget.draft, topShafts: _topShafts, top: false);
    // A 0x0 layer can't be rendered (its image would NaN the AspectRatio), so flag it instead.
    final topEmpty = topDraft.ends == 0 || topDraft.picks == 0;
    final botEmpty = botDraft.ends == 0 || botDraft.picks == 0;
    final mySeq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Kick off BOTH layer renders concurrently (don't serialize on the first decode), then await.
      final topFut = topEmpty ? null : repo.renderDto(topDraft, cellPx: 18, gridlines: true);
      final botFut = botEmpty ? null : repo.renderDto(botDraft, cellPx: 18, gridlines: true);
      final topImg = topFut == null ? null : await topFut;
      final botImg = botFut == null ? null : await botFut;
      if (!mounted || mySeq != _seq) {
        topImg?.dispose();
        botImg?.dispose();
        return;
      }
      setState(() {
        _topImage?.dispose();
        _bottomImage?.dispose();
        _topImage = topImg;
        _bottomImage = botImg;
        _topEmpty = topEmpty;
        _bottomEmpty = botEmpty;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || mySeq != _seq) return;
      setState(() {
        _error = 'Could not render the layers: $e';
        _loading = false;
      });
    }
  }

  void _toggleShaft(int shaft) {
    setState(() {
      if (!_topShafts.remove(shaft)) _topShafts.add(shaft);
    });
    _render();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final shaftCount = maxLayerShaft(widget.draft);
    return Scaffold(
      appBar: AppBar(title: const Text('Double-weave layers')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Top-layer shafts', style: text.titleSmall),
                const SizedBox(height: 2),
                Text('Tap a shaft to move it between the top and bottom layer.',
                    style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (var s = 1; s <= shaftCount; s++)
                      FilterChip(
                        label: Text('$s'),
                        selected: _topShafts.contains(s),
                        onSelected: (_) => _toggleShaft(s),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 12),
          if (_error != null)
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(_error!, textAlign: TextAlign.center),
                ),
              ),
            )
          else ...[
            Expanded(child: _layerPanel(context, 'Top', _topImage, _topEmpty)),
            const Divider(height: 1),
            Expanded(child: _layerPanel(context, 'Bottom', _bottomImage, _bottomEmpty)),
          ],
        ],
      ),
    );
  }

  Widget _layerPanel(BuildContext context, String label, ui.Image? image, bool empty) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Text('$label layer',
                style: text.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : empty
                      ? Text('No threads on this layer.',
                          style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant))
                      : image != null
                          ? DrawdownView(image)
                          : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );
  }
}
