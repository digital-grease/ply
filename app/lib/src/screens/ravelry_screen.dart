import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/ravelry_service.dart';
import '../state/ravelry_providers.dart';

/// The OPTIONAL Ravelry connector (read-only). Reached from Settings; off by default. Not connected →
/// a key-entry form with a clear "online, uses your own account" notice. Connected → search Ravelry's
/// pattern database (browsing/importing happens on ravelry.com). The rest of Ply stays fully offline.
class RavelryScreen extends ConsumerStatefulWidget {
  const RavelryScreen({super.key});

  @override
  ConsumerState<RavelryScreen> createState() => _RavelryScreenState();
}

class _RavelryScreenState extends ConsumerState<RavelryScreen> {
  final _accessKey = TextEditingController();
  final _key = TextEditingController();
  final _query = TextEditingController();
  Future<List<RavelrySearchResult>>? _results;

  @override
  void dispose() {
    _accessKey.dispose();
    _key.dispose();
    _query.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    await ref
        .read(ravelryControllerProvider.notifier)
        .connect(accessKey: _accessKey.text.trim(), key: _key.text.trim());
  }

  void _search(RavelryService service) {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() => _results = service.searchPatterns(q));
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(ravelryControllerProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Ravelry')),
      body: session.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _connectForm(error: e.toString()),
        data: (s) => s == null ? _connectForm() : _connected(s),
      ),
    );
  }

  Widget _connectForm({String? error}) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          color: cs.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Icon(Icons.cloud_outlined, color: cs.primary),
                  const SizedBox(width: 8),
                  Text('Optional & online', style: text.titleSmall),
                ]),
                const SizedBox(height: 8),
                Text(
                  'This connects to ravelry.com using YOUR own Ravelry account, so it needs the '
                  'internet. Everything else in Ply stays fully offline with no account. Create a '
                  'read-only API key at ravelry.com/pro/developer, then paste it below.',
                  style: text.bodyMedium,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _accessKey,
          autocorrect: false,
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Access key (username)'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          autocorrect: false,
          obscureText: true,
          decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Read-only key (password)'),
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(error, style: TextStyle(color: cs.error)),
          ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _connect, child: const Text('Connect')),
      ],
    );
  }

  Widget _connected(RavelrySession s) {
    final text = Theme.of(context).textTheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
          child: Row(
            children: [
              const Icon(Icons.check_circle_outline),
              const SizedBox(width: 8),
              Expanded(child: Text('Connected as ${s.username}', style: text.titleSmall)),
              TextButton(
                onPressed: () => ref.read(ravelryControllerProvider.notifier).disconnect(),
                child: const Text('Disconnect'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(s.service),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: 'Search Ravelry patterns',
              suffixIcon: IconButton(icon: const Icon(Icons.search), onPressed: () => _search(s.service)),
            ),
          ),
        ),
        Expanded(child: _resultsList()),
      ],
    );
  }

  Widget _resultsList() {
    final future = _results;
    if (future == null) {
      return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Search Ravelry to browse patterns.')));
    }
    return FutureBuilder<List<RavelrySearchResult>>(
      future: future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
            child: Padding(padding: const EdgeInsets.all(24), child: Text('${snap.error}', textAlign: TextAlign.center)),
          );
        }
        final results = snap.data ?? const <RavelrySearchResult>[];
        if (results.isEmpty) {
          return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No patterns found.')));
        }
        return ListView.builder(
          itemCount: results.length,
          itemBuilder: (_, i) => _resultTile(results[i]),
        );
      },
    );
  }

  Widget _resultTile(RavelrySearchResult r) {
    return ListTile(
      leading: r.thumbUrl != null
          ? ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Image.network(r.thumbUrl!, width: 44, height: 44, fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(Icons.image_not_supported_outlined)),
            )
          : const Icon(Icons.grid_on),
      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(r.caption ?? r.typeName, maxLines: 2, overflow: TextOverflow.ellipsis),
      onTap: () => _showDetail(r),
    );
  }

  Future<void> _showDetail(RavelrySearchResult r) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(r.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (r.imageUrl != null)
              Image.network(r.imageUrl!, errorBuilder: (_, __, ___) => const SizedBox.shrink()),
            if (r.caption != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(r.caption!)),
            if (r.ravelryUrl != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SelectableText(r.ravelryUrl!,
                    style: TextStyle(color: Theme.of(ctx).colorScheme.primary)),
              ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }
}
