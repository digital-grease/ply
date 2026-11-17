// Materials and swatches (roadmap M8-01, ADR 0016): the library's reusable records, listed, added,
// edited, duplicated and deleted. A reference, not an inventory: every field is optional, and a
// project never needs a record to open.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/materials_repository.dart';
import '../data/project_links_repository.dart';
import '../models/material_record.dart';
import '../state/material_providers.dart';
import '../theme/spacing.dart';
import 'material_edit_screen.dart';
import 'swatch_edit_screen.dart';

/// The list of materials and swatches, one tab each.
class MaterialsScreen extends ConsumerStatefulWidget {
  const MaterialsScreen({this.initialTab = 0, super.key});

  static const String title = 'Materials and swatches';

  /// 0 = materials, 1 = swatches.
  final int initialTab;

  @override
  ConsumerState<MaterialsScreen> createState() => _MaterialsScreenState();
}

class _MaterialsScreenState extends ConsumerState<MaterialsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 2, vsync: this, initialIndex: widget.initialTab.clamp(0, 1))
        ..addListener(() {
          if (!_tabs.indexIsChanging) setState(() {});
        });

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = ref.watch(materialLibraryProvider);
    final ready = library.valueOrNull;
    final canEdit = ready != null && !ready.readOnly;
    final swatches = _tabs.index == 1;
    return Scaffold(
      appBar: AppBar(
        title: const Text(MaterialsScreen.title),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Materials'), Tab(text: 'Swatches')],
        ),
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              key: ValueKey(swatches ? 'add-swatch' : 'add-material'),
              onPressed: () => swatches ? editSwatch(context, null) : editMaterial(context, null),
              icon: const Icon(Icons.add),
              label: Text(swatches ? 'Add swatch' : 'Add material'),
            )
          : null,
      body: library.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const _Note('Your materials could not be opened.'),
        data: (lib) => TabBarView(
          controller: _tabs,
          children: [
            _MaterialList(state: lib),
            _SwatchList(state: lib),
          ],
        ),
      ),
    );
  }
}

Future<void> editMaterial(BuildContext context, MaterialRecord? m) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => MaterialEditScreen(material: m)));

Future<void> editSwatch(BuildContext context, SwatchRecord? s) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => SwatchEditScreen(swatch: s)));

String? _notice(MaterialLibraryState s) => switch (s.status) {
      MaterialsFileStatus.ok => null,
      MaterialsFileStatus.newer =>
        'Your materials were saved by a newer version of Ply. Update the app to see and change them.',
      MaterialsFileStatus.unreachable =>
        'Your materials could not be reached on this device, so they cannot be changed right now.',
      MaterialsFileStatus.tooLarge => 'Your materials file is too large to open (over 2 MB). It '
          'was left as it is, and your materials cannot be changed.',
      MaterialsFileStatus.setAside => 'Your saved materials could not be read. The file was kept '
          'as ${MaterialsRepository.fileName}${MaterialsRepository.corruptSuffix}, and Materials '
          'starts empty.',
    };

String _usedBy(List<ProjectRef> refs) =>
    refs.isEmpty ? '' : 'Used by ${refs.length} ${refs.length == 1 ? 'project' : 'projects'}';

class _MaterialList extends ConsumerWidget {
  const _MaterialList({required this.state});

  final MaterialLibraryState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(linkUsageProvider).valueOrNull ?? LinkUsage.none;
    final notice = _notice(state);
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (notice != null) _Note(notice),
        if (state.materials.isEmpty && !state.readOnly)
          const _Note('No materials yet. Add the yarns you use with as much or as little as you '
              'know: a name is enough. Link them to your projects from each editor.'),
        for (final m in state.materials)
          ListTile(
            key: ValueKey('material-${m.id}'),
            title: Text(m.displayName),
            subtitle: Text(
                [m.summary, _usedBy(usage.ofMaterial(m.id))].where((s) => s.isNotEmpty).join('\n')),
            isThreeLine: usage.ofMaterial(m.id).isNotEmpty,
            onTap: state.readOnly ? null : () => editMaterial(context, m),
            trailing: state.readOnly
                ? null
                : _Actions(
                    tooltip: 'Material actions',
                    onEdit: () => editMaterial(context, m),
                    onDuplicate: () => _run(context,
                        () => ref.read(materialLibraryProvider.notifier).duplicateMaterial(m.id)),
                    onDelete: () => _confirmDelete(
                      context,
                      name: m.displayName,
                      users: _usersOf(ref, (u) => u.ofMaterial(m.id)),
                      namingSwatches: [
                        for (final s in state.swatches)
                          if (s.yarns.any((y) => y.materialId == m.id)) s.displayName
                      ],
                      kind: 'material',
                      delete: () => ref.read(materialLibraryProvider.notifier).deleteMaterial(m.id),
                    ),
                  ),
          ),
      ],
    );
  }
}

class _SwatchList extends ConsumerWidget {
  const _SwatchList({required this.state});

  final MaterialLibraryState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usage = ref.watch(linkUsageProvider).valueOrNull ?? LinkUsage.none;
    final notice = _notice(state);
    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (notice != null) _Note(notice),
        if (state.swatches.isEmpty && !state.readOnly)
          const _Note('No swatches yet. Record a swatch you measured, before and after finishing, '
              'and the planning calculators can use it, citing exactly what they took from it.'),
        for (final s in state.swatches)
          ListTile(
            key: ValueKey('swatch-${s.id}'),
            title: Text(s.displayName),
            subtitle: Text(
                [s.summary, _usedBy(usage.ofSwatch(s.id))].where((x) => x.isNotEmpty).join('\n')),
            isThreeLine: usage.ofSwatch(s.id).isNotEmpty,
            onTap: state.readOnly ? null : () => editSwatch(context, s),
            trailing: state.readOnly
                ? null
                : _Actions(
                    tooltip: 'Swatch actions',
                    onEdit: () => editSwatch(context, s),
                    onDuplicate: () => _run(context,
                        () => ref.read(materialLibraryProvider.notifier).duplicateSwatch(s.id)),
                    onDelete: () => _confirmDelete(
                      context,
                      name: s.displayName,
                      users: _usersOf(ref, (u) => u.ofSwatch(s.id)),
                      kind: 'swatch',
                      delete: () => ref.read(materialLibraryProvider.notifier).deleteSwatch(s.id),
                    ),
                  ),
          ),
      ],
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.tooltip,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  final String tooltip;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: tooltip,
        onSelected: (a) => switch (a) {
          'edit' => onEdit(),
          'duplicate' => onDuplicate(),
          _ => onDelete(),
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'edit', child: Text('Edit')),
          PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      );
}

String failureMessage(Object e) =>
    e is MaterialsFileException ? e.message : 'Could not save your materials.';

Future<void> _run(BuildContext context, Future<Object?> Function() action) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await action();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(failureMessage(e))));
  }
}

/// The projects that use a record, from the usage scan; null when the scan failed (a future that
/// never fails, so the dialog can wait on it however late it starts listening).
Future<List<ProjectRef>?> _usersOf(WidgetRef ref, List<ProjectRef> Function(LinkUsage) pick) =>
    ref.read(linkUsageProvider.future).then<List<ProjectRef>?>(pick, onError: (Object _) => null);

/// Ask before deleting a record, saying how many projects use it (once the scan of every project is
/// done: until then Delete waits), which swatches name a material, and that they keep its name.
Future<void> _confirmDelete(
  BuildContext context, {
  required String name,
  required Future<List<ProjectRef>?> users,
  List<String> namingSwatches = const [],
  required String kind,
  required Future<void> Function() delete,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) =>
        _DeleteDialog(name: name, users: users, namingSwatches: namingSwatches, kind: kind),
  );
  if (ok != true || !context.mounted) return;
  await _run(context, delete);
}

class _DeleteDialog extends StatelessWidget {
  const _DeleteDialog({
    required this.name,
    required this.users,
    required this.namingSwatches,
    required this.kind,
  });

  final String name;
  final Future<List<ProjectRef>?> users;
  final List<String> namingSwatches;
  final String kind;

  static String _names(List<String> names) {
    final shown = names.take(5).join(', ');
    return names.length > 5 ? '$shown and ${names.length - 5} more' : shown;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<ProjectRef>?>(
        future: users,
        builder: (ctx, snap) {
          final checking = snap.connectionState != ConnectionState.done;
          final projects = snap.data ?? const <ProjectRef>[];
          final failed = !checking && snap.data == null;
          final photos = kind == 'swatch' ? ' Its photos are deleted too.' : '';
          final String usedBy;
          if (checking) {
            usedBy = 'Checking which projects use this $kind...';
          } else if (failed) {
            usedBy = 'Ply could not check which projects use this $kind. Any that do keep its '
                'name, shown as not in your materials.';
          } else if (projects.isEmpty) {
            usedBy = 'No project uses this $kind.';
          } else {
            usedBy =
                '${projects.length == 1 ? '1 project uses' : '${projects.length} projects use'} '
                'this $kind: ${_names([for (final p in projects) p.name])}. They keep its name, '
                'shown as not in your materials, but can no longer use its details.';
          }
          final swatches = namingSwatches.isEmpty
              ? ''
              : ' ${namingSwatches.length == 1 ? '1 swatch names' : '${namingSwatches.length} '
                      'swatches name'} it: ${_names(namingSwatches)}. They keep its name, but a yarn '
                  'estimate from them can no longer use its length per mass.';
          return AlertDialog(
            title: Text('Delete "$name"?'),
            content: Text('$usedBy$swatches$photos', key: const ValueKey('delete-usage')),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(
                key: const ValueKey('confirm-delete'),
                onPressed: checking ? null : () => Navigator.pop(ctx, true),
                child: const Text('Delete'),
              ),
            ],
          );
        },
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(PlySpacing.md),
      child: Text(text,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}
