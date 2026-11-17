// "Materials and swatches" for one project, the same sheet in every craft's editor (ADR 0016): what
// the project links, and links and unlinks records. A link is saved at once in the project's
// sidecar (it never makes the project unsaved) and keeps the record's name, so a link whose record
// is gone shows as "not in your materials" instead of vanishing.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/project_links_repository.dart';
import '../models/material_record.dart';
import '../models/project_materials.dart';
import '../screens/materials_screen.dart';
import '../state/material_providers.dart';
import '../theme/spacing.dart';
import 'adaptive_sheet.dart';

/// The menu entry and sheet title.
const String kProjectMaterialsTitle = 'Materials and swatches';

/// A project's links, read from its sidecar (none for an unsaved project or an unreadable sidecar).
final projectMaterialsProvider = FutureProvider.autoDispose
    .family<ProjectMaterials, ({BackupCraft craft, String? id})>((ref, p) async {
  if (p.id == null) return ProjectMaterials.none;
  try {
    return await ref.read(projectLinksRepositoryProvider).read(p.craft, p.id!);
  } catch (_) {
    return ProjectMaterials.none;
  }
});

/// Whether an editor offers "Materials and swatches...": when the crafter has any record, or the
/// project already links one. With neither, the editor's menu looks as it always did.
final offerProjectMaterialsProvider =
    Provider.autoDispose.family<bool, ({BackupCraft craft, String? id})>((ref, p) {
  if (ref.watch(hasMaterialRecordsProvider)) return true;
  final links = ref.watch(projectMaterialsProvider(p)).valueOrNull;
  return links != null && (links.yarns.isNotEmpty || links.swatches.isNotEmpty);
});

/// Open the sheet for the project [id] of [craft] (null = not saved yet).
Future<void> showProjectMaterials(BuildContext context,
    {required BackupCraft craft, required String? id}) {
  return showAdaptiveSheet<void>(context, child: ProjectMaterialsSheet(craft: craft, id: id));
}

class ProjectMaterialsSheet extends ConsumerStatefulWidget {
  const ProjectMaterialsSheet({required this.craft, required this.id, super.key});

  final BackupCraft craft;
  final String? id;

  @override
  ConsumerState<ProjectMaterialsSheet> createState() => _ProjectMaterialsSheetState();
}

class _ProjectMaterialsSheetState extends ConsumerState<ProjectMaterialsSheet> {
  ProjectMaterials? _links;
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.id;
    if (id == null) {
      setState(() => _problem = 'Save the project first to link materials and swatches.');
      return;
    }
    try {
      final links = await ref.read(projectLinksRepositoryProvider).read(widget.craft, id);
      if (mounted) setState(() => _links = links);
    } on ProjectLinksException catch (e) {
      if (mounted) setState(() => _problem = e.message);
    } catch (_) {
      if (mounted) setState(() => _problem = 'This project\'s links could not be read.');
    }
  }

  Future<void> _write(ProjectMaterials next) async {
    final before = _links;
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _links = next;
      _busy = true;
    });
    try {
      await ref.read(projectLinksRepositoryProvider).write(widget.craft, widget.id!, next);
      ref.invalidate(linkUsageProvider);
      ref.invalidate(projectMaterialsProvider((craft: widget.craft, id: widget.id)));
    } catch (e) {
      if (mounted) setState(() => _links = before);
      messenger.showSnackBar(SnackBar(
          content: Text(e is ProjectLinksException ? e.message : 'Could not save the link.')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The links with every snapshot name brought up to date from the library (a renamed record).
  ProjectMaterials _refreshed(ProjectMaterials l, MaterialLibraryState? lib) {
    if (lib == null) return l;
    return l.copyWith(
      yarns: [
        for (final y in l.yarns)
          switch (lib.material(y.materialId)) {
            null => y,
            final m => y.copyWith(materialName: m.displayName),
          },
      ],
      swatches: [
        for (final s in l.swatches)
          switch (lib.swatch(s.swatchId)) {
            null => s,
            final r => s.copyWith(swatchName: r.displayName),
          },
      ],
    );
  }

  Future<void> _linkMaterial(MaterialLibraryState lib) async {
    final links = _links!;
    final choice = await showDialog<(MaterialRecord, YarnRole?)>(
      context: context,
      builder: (_) => _LinkMaterialDialog(
        materials: [
          for (final m in lib.materials)
            if (!links.linksMaterial(m.id)) m
        ],
        weaving: widget.craft == BackupCraft.weaving,
      ),
    );
    if (choice == null || !mounted) return;
    final (m, role) = choice;
    final next = _refreshed(links, lib);
    await _write(next.copyWith(yarns: [
      ...next.yarns,
      MaterialLink(materialId: m.id, materialName: m.displayName, role: role),
    ]));
  }

  Future<void> _linkSwatch(MaterialLibraryState lib) async {
    final links = _links!;
    final choices = [
      for (final s in lib.swatches)
        if (!links.linksSwatch(s.id)) s
    ];
    final s = await showDialog<SwatchRecord>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Link a swatch'),
        children: [
          if (choices.isEmpty)
            const Padding(
              padding: EdgeInsets.all(PlySpacing.md),
              child: Text('Every swatch is linked already.'),
            ),
          for (final s in choices)
            SimpleDialogOption(
              key: ValueKey('link-swatch-${s.id}'),
              onPressed: () => Navigator.pop(ctx, s),
              child: ListTile(title: Text(s.displayName), subtitle: Text(s.summary)),
            ),
        ],
      ),
    );
    if (s == null || !mounted) return;
    final next = _refreshed(links, lib);
    await _write(next.copyWith(
        swatches: [...next.swatches, SwatchLink(swatchId: s.id, swatchName: s.displayName)]));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final lib = ref.watch(materialLibraryProvider).valueOrNull;
    final links = _links;
    final canLink = links != null && lib != null && !lib.readOnly && !_busy;
    // A link is "not in your materials" only when the library could be read and lacks it.
    bool missing(bool found) => lib != null && !lib.readOnly && !found;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(PlySpacing.md, 0, PlySpacing.md, PlySpacing.lg),
        child: Column(
          key: const ValueKey('project-materials-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(kProjectMaterialsTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: PlySpacing.xs),
            Text(
                'The yarns and swatches this project uses. Linking never changes the pattern; it '
                'is saved at once.',
                style: muted),
            if (_problem != null)
              Padding(
                padding: const EdgeInsets.only(top: PlySpacing.md),
                child: Text(_problem!, key: const ValueKey('project-materials-problem')),
              ),
            if (lib != null && lib.readOnlyReason != null)
              Padding(
                padding: const EdgeInsets.only(top: PlySpacing.sm),
                child: Text(lib.readOnlyReason!, style: muted),
              ),
            if (links != null) ...[
              const SizedBox(height: PlySpacing.md),
              Text('Yarns', style: theme.textTheme.titleSmall),
              if (links.yarns.isEmpty) Text('None linked.', style: muted),
              for (final y in links.yarns)
                _linkTile(
                  key: 'linked-material-${y.materialId}',
                  name: lib?.material(y.materialId)?.displayName ??
                      (y.materialName.trim().isEmpty ? 'Unnamed material' : y.materialName),
                  details: [
                    if (y.role != null) y.role!.label,
                    if (missing(lib?.material(y.materialId) != null)) 'not in your materials',
                  ],
                  onRemove: _busy
                      ? null
                      : () => _write(links.copyWith(
                          yarns: [...links.yarns]
                            ..removeWhere((l) => l.materialId == y.materialId))),
                ),
              if (canLink && lib.materials.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('link-material'),
                  onPressed: () => _linkMaterial(lib),
                  icon: const Icon(Icons.add_link),
                  label: const Text('Link a material'),
                ),
              const SizedBox(height: PlySpacing.md),
              Text('Swatches', style: theme.textTheme.titleSmall),
              if (links.swatches.isEmpty) Text('None linked.', style: muted),
              for (final s in links.swatches)
                _linkTile(
                  key: 'linked-swatch-${s.swatchId}',
                  name: lib?.swatch(s.swatchId)?.displayName ??
                      (s.swatchName.trim().isEmpty ? 'Unnamed swatch' : s.swatchName),
                  details: [
                    if (lib?.swatch(s.swatchId) != null) lib!.swatch(s.swatchId)!.summary,
                    if (missing(lib?.swatch(s.swatchId) != null)) 'not in your materials',
                  ],
                  onRemove: _busy
                      ? null
                      : () => _write(links.copyWith(
                          swatches: [...links.swatches]
                            ..removeWhere((l) => l.swatchId == s.swatchId))),
                ),
              if (canLink && lib.swatches.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('link-swatch'),
                  onPressed: () => _linkSwatch(lib),
                  icon: const Icon(Icons.add_link),
                  label: const Text('Link a swatch'),
                ),
            ],
            const Divider(height: PlySpacing.lg),
            TextButton.icon(
              key: const ValueKey('manage-materials'),
              onPressed: () => Navigator.of(context)
                  .push(MaterialPageRoute<void>(builder: (_) => const MaterialsScreen())),
              icon: const Icon(Icons.inventory_2_outlined),
              label: const Text('Open Materials and swatches'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _linkTile({
    required String key,
    required String name,
    required List<String> details,
    required VoidCallback? onRemove,
  }) =>
      ListTile(
        key: ValueKey(key),
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(name),
        subtitle: details.isEmpty ? null : Text(details.join(', ')),
        trailing: IconButton(
          tooltip: 'Unlink',
          icon: const Icon(Icons.link_off),
          onPressed: onRemove,
        ),
      );
}

/// Choose a material to link, and what the project uses it for.
class _LinkMaterialDialog extends StatefulWidget {
  const _LinkMaterialDialog({required this.materials, required this.weaving});

  final List<MaterialRecord> materials;
  final bool weaving;

  @override
  State<_LinkMaterialDialog> createState() => _LinkMaterialDialogState();
}

class _LinkMaterialDialogState extends State<_LinkMaterialDialog> {
  late MaterialRecord? _material = widget.materials.isEmpty ? null : widget.materials.first;
  YarnRole? _role;

  @override
  Widget build(BuildContext context) {
    final roles = widget.weaving
        ? const [YarnRole.warp, YarnRole.weft]
        : const [YarnRole.main, YarnRole.contrast];
    return AlertDialog(
      title: const Text('Link a material'),
      content: widget.materials.isEmpty
          ? const Text('Every material is linked already.')
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<MaterialRecord>(
                  key: const ValueKey('link-material-choice'),
                  initialValue: _material,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Material'),
                  items: [
                    for (final m in widget.materials)
                      DropdownMenuItem(value: m, child: Text(m.displayName)),
                  ],
                  onChanged: (m) => setState(() => _material = m),
                ),
                DropdownButtonFormField<YarnRole?>(
                  key: const ValueKey('link-material-role'),
                  initialValue: _role,
                  decoration: const InputDecoration(labelText: 'Used as (optional)'),
                  items: [
                    const DropdownMenuItem<YarnRole?>(value: null, child: Text('Not recorded')),
                    for (final r in roles)
                      DropdownMenuItem<YarnRole?>(value: r, child: Text(r.label)),
                  ],
                  onChanged: (r) => setState(() => _role = r),
                ),
              ],
            ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        if (_material != null)
          FilledButton(
            key: const ValueKey('link-material-confirm'),
            onPressed: () => Navigator.pop(context, (_material!, _role)),
            child: const Text('Link'),
          ),
      ],
    );
  }
}

/// The editor action that opens the sheet, for an app bar with no overflow menu (the nalbinding
/// project screen). It shows only when [offerProjectMaterialsProvider] offers the sheet, so with no
/// records the app bar looks as it always did.
class ProjectMaterialsAction extends ConsumerWidget {
  const ProjectMaterialsAction({required this.craft, required this.id, super.key});

  final BackupCraft craft;

  /// The project's id, or null before its first save.
  final String? id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(offerProjectMaterialsProvider((craft: craft, id: id)))) {
      return const SizedBox.shrink();
    }
    return IconButton(
      key: const ValueKey('project-materials-action'),
      tooltip: '$kProjectMaterialsTitle…',
      icon: const Icon(Icons.inventory_2_outlined),
      onPressed: () => showProjectMaterials(context, craft: craft, id: id),
    );
  }
}
