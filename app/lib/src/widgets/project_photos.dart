import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../data/photo_store.dart';

/// A horizontal strip of a pattern's project photos plus an Add tile (Take a photo / Choose from
/// gallery). Photos are stored on-device via [PhotoStore] and never leave the device. The image
/// picker is INJECTABLE ([pickImagePath]) so the widget is host-testable without the real plugin.
class ProjectPhotos extends StatefulWidget {
  const ProjectPhotos({
    required this.subdir,
    required this.id,
    this.pickImagePath,
    this.docsOverride,
    super.key,
  });

  /// The craft's documents subdir (e.g. 'knits', 'nalbinds').
  final String subdir;

  /// The saved pattern's id (the photo dir is `<subdir>/<id>.photos/`).
  final String id;

  /// Returns the picked file path (null = cancelled). Defaults to image_picker (camera / gallery).
  final Future<String?> Function(ImageSource source)? pickImagePath;

  /// Tests point this at a temp dir to stand in for the app documents directory.
  final Directory? docsOverride;

  @override
  State<ProjectPhotos> createState() => _ProjectPhotosState();
}

class _ProjectPhotosState extends State<ProjectPhotos> {
  late PhotoStore _store;
  late Future<List<File>> _photos;

  @override
  void initState() {
    super.initState();
    _store = PhotoStore(subdir: widget.subdir, id: widget.id, docsOverride: widget.docsOverride);
    _photos = _store.list();
  }

  void _refresh() => setState(() => _photos = _store.list());

  Future<String?> _pick(ImageSource source) async {
    final fn = widget.pickImagePath;
    if (fn != null) return fn(source);
    final x = await ImagePicker().pickImage(source: source, imageQuality: 85, maxWidth: 2400);
    return x?.path;
  }

  Future<void> _add() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final path = await _pick(source);
      if (path == null) return;
      await _store.add(File(path));
      _refresh();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add the photo: $e')));
      }
    }
  }

  Future<void> _view(File photo) async {
    final deleted = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => _PhotoViewer(photo: photo, store: _store)),
    );
    if (deleted == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<File>>(
      future: _photos,
      builder: (context, snap) {
        final photos = snap.data ?? const <File>[];
        return SizedBox(
          height: 100,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              for (final f in photos)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => _view(f),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(f,
                          width: 100, height: 100, fit: BoxFit.cover, gaplessPlayback: true),
                    ),
                  ),
                ),
              _AddTile(onTap: _add),
            ],
          ),
        );
      },
    );
  }
}

class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 100,
        height: 100,
        decoration: BoxDecoration(
          border: Border.all(color: cs.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_a_photo_outlined, color: cs.onSurfaceVariant),
            const SizedBox(height: 4),
            Text('Add', style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}

/// Full-screen photo view with pinch-zoom and a delete action (pops `true` if deleted).
class _PhotoViewer extends StatelessWidget {
  const _PhotoViewer({required this.photo, required this.store});
  final File photo;
  final PhotoStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            tooltip: 'Delete photo',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Delete photo?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Delete'),
                    ),
                  ],
                ),
              );
              if (ok != true || !context.mounted) return;
              await store.delete(photo);
              if (context.mounted) Navigator.pop(context, true);
            },
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(child: Image.file(photo)),
      ),
    );
  }
}
