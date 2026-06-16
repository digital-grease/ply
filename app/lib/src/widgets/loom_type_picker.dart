import 'package:flutter/material.dart';

import '../models/loom_type.dart';

/// Show the loom-type chooser. Returns the picked [LoomType], or null if dismissed. Shared by the
/// new-draft flow (pick the loom before building) and the editor's loom-type setting.
Future<LoomType?> showLoomTypePicker(BuildContext context, {LoomType? current}) {
  return showDialog<LoomType>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('Loom type'),
      children: [
        for (final loom in LoomType.values)
          ListTile(
            title: Text(loom.label),
            subtitle: Text(loom.description),
            trailing: loom == current ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, loom),
          ),
      ],
    ),
  );
}
