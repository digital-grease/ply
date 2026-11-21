// A project's saved place on its library tile (ADR 0023, amendment of 2026-11-19): the place as its
// progress record states it ("Pick 49 of 96, time 2", "Chart row 5 of 24", "Line 14 of 120, row 3",
// "Step 3 of 12"), or in the tracker's own words when the record keeps them for that place
// ("Section 1: Cuff, step 2, row 5", follow-up 6), and when it last changed, as a button that
// opens the project straight into its tracker. A record that cannot be read says so in a short
// line, which opens the tracker too: the tracker explains and offers what to do.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/library_backup.dart' show BackupCraft;
import '../data/library_places.dart';
import '../models/progress.dart';
import '../state/library_place_providers.dart';
import '../state/progress_controller.dart' show progressClockProvider, progressRepositoryProvider;

/// Said on a tile whose record a newer Ply wrote.
const String kLibraryPlaceNewer = 'Place saved by a newer Ply';

/// Said on a tile whose record cannot be read.
const String kLibraryPlaceUnreadable = 'Place not readable';

/// The place in a tile's words, from the record alone: the pick, chart row, line or step (from 1),
/// "of" the units the pattern had when the place was saved, and the time through the pattern past
/// the first. A knitting place inside sections (one with a section or step id, a chart row of a
/// chart-rows step, or a row past the first inside its step) names its line of the written
/// instructions (the record keeps the step's ids, not its words or number), the chart row it is on,
/// and the row inside the step past the first.
String libraryPlaceWords(WorkPlace place, int? units) {
  String of(int n) => units != null && n <= units ? ' of $units' : '';
  String time(int repeat) => repeat > 1 ? ', time $repeat' : '';
  return switch (place) {
    PickPlace(:final pick, :final repeat) => 'Pick $pick${of(pick)}${time(repeat)}',
    KnitPlace(:final unit, :final row, :final repeat)
        when !place.hasIds && place.sectionId == null && place.chartRow == null && row == 1 =>
      'Chart row ${unit + 1}${of(unit + 1)}${time(repeat)}',
    KnitPlace(:final unit, :final row, :final chartRow) => 'Line ${unit + 1}${of(unit + 1)}'
        '${chartRow != null ? ', chart row $chartRow' : ''}${row > 1 ? ', row $row' : ''}',
    NalbindPlace(:final unit) => 'Step ${unit + 1}${of(unit + 1)}',
  };
}

/// The tile's line for [place]: the tracker's words when the record keeps them for its place, else
/// the tile's own words, or why there are none.
String libraryPlaceText(LibraryPlace place) => switch (place.kind) {
      LibraryPlaceKind.read => place.label ?? libraryPlaceWords(place.place!, place.units),
      LibraryPlaceKind.newer => kLibraryPlaceNewer,
      LibraryPlaceKind.unreadable => kLibraryPlaceUnreadable,
    };

/// "Updated today", "Updated yesterday", or "Updated" and the date, in the device's time zone.
String libraryUpdatedText(MaterialLocalizations l, DateTime updated, DateTime now) {
  final a = updated.toLocal(), b = now.toLocal();
  // Whole calendar days between the two (an hour either way where clocks change).
  final days =
      (DateTime(b.year, b.month, b.day).difference(DateTime(a.year, a.month, a.day)).inHours / 24)
          .round();
  return switch (days) {
    0 => 'Updated today',
    1 => 'Updated yesterday',
    _ => 'Updated ${l.formatShortDate(a)}',
  };
}

/// A tile's saved place, as a button that opens the project in its tracker ([trackerTitle] names
/// it, as the editor's menu does).
class LibraryPlaceLine extends ConsumerWidget {
  const LibraryPlaceLine({
    required this.place,
    required this.trackerTitle,
    required this.onOpen,
    this.padding = const EdgeInsets.fromLTRB(10, 0, 8, 6),
    super.key,
  });

  final LibraryPlace place;
  final String trackerTitle;
  final VoidCallback onOpen;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final read = place.kind == LibraryPlaceKind.read;
    final text = libraryPlaceText(place);
    final updated = place.updated == null
        ? null
        : libraryUpdatedText(
            MaterialLocalizations.of(context), place.updated!, ref.read(progressClockProvider)());
    // The tracker's words are said as written: they start with a section's heading ("Continue at
    // Section 1: Cuff, step 2, row 5") or a row's ("Continue at Round 5 of 24"), never lowered into
    // the knitter's own text. The tile's own words read on from "at" ("Continue at pick 49 of 96").
    final spoken = read
        ? 'Continue at ${place.label ?? '${text[0].toLowerCase()}${text.substring(1)}'}'
            '${updated == null ? '' : '. $updated'}'
        : text;
    // At a large text size a small tile keeps to one line (the day stays in what is spoken), so the
    // place never pushes the tile past its height.
    final large = MediaQuery.textScalerOf(context).scale(10) > 15;
    return Semantics(
      button: true,
      label: spoken,
      onTapHint: 'open $trackerTitle',
      // The node's own tap: excludeSemantics drops the InkWell's, and switch and voice access act
      // through this one.
      onTap: onOpen,
      excludeSemantics: true,
      child: InkWell(
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Padding(
            padding: padding,
            child: Row(
              children: [
                Icon(read ? Icons.playlist_play : Icons.info_outline,
                    size: 18, color: read ? cs.primary : cs.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(text,
                          maxLines: large ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: read ? cs.primary : cs.onSurfaceVariant)),
                      if (updated != null && !large)
                        Text(updated,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:
                                theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A library screen's saved places, by project id. A screen built again (a tab switched back to,
/// a library restored) starts from the places last read, so nothing pops in; after each listing
/// (which never waits for them) every place is read again, each shown as soon as it is known, and
/// the read's whole result then replaces the last. A later read always wins: an earlier one still
/// under way stops reading and shows nothing more.
mixin LibraryPlaces<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  /// The craft whose records the screen lists.
  BackupCraft get placesCraft;

  Map<String, LibraryPlace> _places = {};
  int _placesRead = 0;

  @override
  void initState() {
    super.initState();
    _places = ref.read(libraryPlaceCacheProvider).lastFor(placesCraft);
  }

  /// The saved place of project [id], when its record has one (or cannot be read).
  LibraryPlace? placeOf(String id) => _places[id];

  /// Read the places of [ids], the projects just listed.
  Future<void> readPlaces(Iterable<String> ids) async {
    if (!mounted) return;
    final n = ++_placesRead;
    bool wanted() => mounted && n == _placesRead;
    final Map<String, LibraryPlace> read;
    try {
      read = await readLibraryPlaces(
        ref.read(progressRepositoryProvider),
        placesCraft,
        ids.toList(),
        cache: ref.read(libraryPlaceCacheProvider),
        stillWanted: wanted,
        onRead: (id, place) {
          if (!wanted() || placeOf(id) == place) return;
          setState(() {
            if (place == null) {
              _places.remove(id);
            } else {
              _places[id] = place;
            }
          });
        },
      );
    } catch (_) {
      return; // the reader never throws; a tile never fails because of a record
    }
    if (!wanted()) return;
    setState(() {
      _places = Map.of(read);
    });
  }
}
