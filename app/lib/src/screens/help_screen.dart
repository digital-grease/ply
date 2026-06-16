import 'package:flutter/material.dart';

import 'glossary_screen.dart';

/// The Help hub, reached from the "?" action in the home AppBar: a searchable-ish FAQ (grouped,
/// tap-to-expand) plus an entry into the in-app [GlossaryScreen]. Content lives in [kFaq] below.
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Help & FAQ')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.menu_book_outlined),
            title: const Text('Glossary'),
            subtitle: const Text('Definitions for weaving, knitting & nalbinding terms'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const GlossaryScreen()),
            ),
          ),
          const Divider(height: 1),
          for (final section in kFaq) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                section.title,
                style: text.titleSmall?.copyWith(color: cs.primary),
              ),
            ),
            for (final entry in section.entries)
              ExpansionTile(
                title: Text(entry.question, style: text.bodyLarge),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedAlignment: Alignment.topLeft,
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [Text(entry.answer, style: text.bodyMedium)],
              ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// One FAQ question + answer.
class FaqEntry {
  const FaqEntry(this.question, this.answer);
  final String question;
  final String answer;
}

/// A titled group of FAQ entries.
class FaqSection {
  const FaqSection(this.title, this.entries);
  final String title;
  final List<FaqEntry> entries;
}

/// The FAQ content, grouped by topic. Authored from the actual app behavior.
const List<FaqSection> kFaq = [
  FaqSection('About Ply & privacy', [
    FaqEntry(
      "What is Ply?",
      "Ply is a local-first pattern tool for fiber crafts. You can create, modify, store, and preview patterns right on your phone, with a Flutter app sitting over a fast Rust engine that does the pattern math.",
    ),
    FaqEntry(
      "Which crafts does Ply support?",
      "Three: weaving, knitting, and nalbinding, each on its own tab in the app. Weaving and knitting have full editors with live previews, and nalbinding currently offers a stitch reference dictionary plus a notation playground (its project and recipe model is planned but not yet built).",
    ),
    FaqEntry(
      "Do I need an account or an internet connection to use Ply?",
      "No — not for anything Ply does on its own. Ply is local-first with no backend, so creating, editing, and storing patterns runs entirely on your device and works fully offline, with nothing to sign up for. The one exception is the OPTIONAL Ravelry connector (Settings → Ravelry), which is off by default and uses your own Ravelry account to search patterns online.",
    ),
    FaqEntry(
      "Where are my patterns stored?",
      "Your patterns are plain files saved on your device, not in any cloud or proprietary container. Weaving drafts save as standard .wif files (with a small JSON sidecar for app notes), and knitting patterns save as .plyknit JSON alongside a preview image.",
    ),
    FaqEntry(
      "What platforms does Ply run on?",
      "Ply runs on Android and iOS today. A desktop companion that reuses the same engine is a possible future direction, but it is not built yet.",
    ),
    FaqEntry(
      "Does Ply collect any data or telemetry about me?",
      "No. Because there is no backend and no accounts, Ply has nothing to send anywhere and includes no tracking or telemetry. Your patterns and notes stay private on your device. (The name Ply nods to plied yarn, twisting strands together, and to plying a craft.)",
    ),
    FaqEntry(
      "Does Ply ask for any permissions?",
      "Only one, and only when you use it: the camera, for attaching photos to a project. Choosing an existing picture uses the system photo picker, which needs no permission. Either way the photos are saved on your device and never leave it.",
    ),
    FaqEntry(
      "Can Ply connect to Ravelry?",
      "Optionally, yes. In Settings → Ravelry you can connect with your OWN read-only Ravelry API key (from ravelry.com/pro/developer) to search Ravelry's pattern database. This is the one feature that goes online and uses a Ravelry account; it is off by default and walled off from the rest of the app. Everything else — creating, editing, and storing your patterns — stays fully offline with no account. Your key is stored in your device's keystore and your searches go only to ravelry.com.",
    ),
  ]),
  FaqSection('Weaving', [
    FaqEntry(
      "Can I import my existing WIF files?",
      "Yes. WIF (Weaving Information File) is Ply's native weaving format, so importing is built in: tap Import in the library, pick a .wif file, and the Rust engine parses it and renders a live drawdown. The parser is lenient, it fills in missing sections sensibly and only refuses a file when there is no recognizable draft data at all.",
    ),
    FaqEntry(
      "How do I export or share a draft as a WIF file?",
      "Right now there is no dedicated export or share button to send a .wif out to another app or folder. Your drafts are saved on-device in the library as real .wif files (with a JSON sidecar and a PNG thumbnail), so the WIF lives on your device, but a one-tap export/share flow is not built yet.",
    ),
    FaqEntry(
      "What does the draft editor screen actually look like?",
      "It is an integrated draft: threading runs across the top, the tie-up sits top-right, the woven-cloth drawdown fills the center, and the treadling (or liftplan) runs down the right side, with warp and weft color bands alongside. Everything shares one cell grid so it stays aligned, and the drawdown recomputes live as you paint edits, with zoom and pan.",
    ),
    FaqEntry(
      "What is the difference between a treadled draft and a liftplan, and can I switch?",
      "A treadled draft uses a tie-up plus a treadling sequence (how a foot loom works), while a liftplan lists the raised shafts directly for each pick (common for table looms and dobby). Ply can convert a treadled draft to a liftplan with one menu action, but that is one-way and lossy: the tie-up and treadling are dropped and cannot be rebuilt, though you can undo right after.",
    ),
    FaqEntry(
      "Can Ply help me figure out my sett and how much yarn to buy?",
      "Yes, the planning calculator has three independent tools: suggest a sett from your wraps-per-inch and structure (plain, twill, or satin), estimate warp yarn from finished length, ends, loom waste and take-up, and estimate weft yarn from picks, woven width and length. These are pure planning aids that read your draft but never change it.",
    ),
    FaqEntry(
      "Can the app generate a weave structure for me?",
      "Yes. The Generate structure sheet lays down a complete plain, twill, or satin tie-up paired with a straight or point threading, sized to the warp ends and picks you enter, and commits it as a single undoable edit. It validates your inputs, for example warning that satin needs at least 5 shafts and a valid counter, so the generated cloth is always sound.",
    ),
    FaqEntry(
      "Will the app tell me if my draft has problems?",
      "Yes. A validation band runs the engine's structural checks live on every edit and appears next to the draft (below the cloth on a phone, in the side panel on a tablet) only when there are real issues, with errors in red and warnings in amber. It stays out of the way on a clean draft, and you can tap it to expand a scrollable list with the errors sorted first.",
    ),
  ]),
  FaqSection('Knitting & nalbinding', [
    FaqEntry(
      "How do I make a knitting chart? Can I paint stitches, undo mistakes, and zoom in?",
      "Open the Knitting tab and start a new pattern to get a blank chart. You pick a stitch from the brush row at the bottom, then tap cells to paint them; the toolbar has steppers to add or remove stitches and rows. Undo and redo buttons sit in the top bar, and the More menu has zoom in and zoom out (the chart also scrolls if it is bigger than the screen).",
    ),
    FaqEntry(
      "Can I do colorwork in the knitting chart?",
      "Yes. Below the stitch brushes there is a color palette row where you pick the active color (or choose \"symbol only\" for an uncolored cell), and painting then applies both the stitch and that color. You can add colors with the + swatch and long-press any swatch to edit its RGB, the same palette approach used in the weaving editor.",
    ),
    FaqEntry(
      "How does the cable builder work?",
      "Tap the \"Cable\" chip in the brush row to open the cable builder, where you set the front and back stitch counts (1 to 4 each), pick a right or left cross, and optionally purl the front and/or back strand. On confirm it becomes a new brush (labeled like \"2/2 RC\"), and tapping the chart places the cable anchor and auto-fills the no-stitch cells it spans.",
    ),
    FaqEntry(
      "Where do my knitting patterns get saved, and is there written instructions I can copy?",
      "The Save button stores the pattern on your device in your knit library (no account or cloud), and it shows up as a thumbnail tile you can open, rename, or delete. From the More menu, \"Written instructions\" turns the chart into row-by-row text, listed cast-on edge first and aware of right-side/wrong-side rows; each line is selectable so you can copy the pattern out.",
    ),
    FaqEntry(
      "Is there a gauge and yardage calculator for knitting?",
      "Yes, under More > \"Gauge & yardage\". You can seed a gauge from a yarn weight or type your swatch numbers and apply it to the pattern, calculate cast-on stitches from a finished width plus ease (rounded to a stitch-repeat multiple), and get a rough stockinette yardage estimate that also shows a 10% buffer. The yardage figure is an estimate, so plan to buy a little extra.",
    ),
    FaqEntry(
      "Can I set a pattern to be knit flat versus in the round?",
      "Yes, in More > \"Pattern settings\" you switch between Flat and In the round, and for flat work you set whether row 1 is worked from the right or wrong side. That choice drives the written instructions (Row N with RS/WS alternation when flat, versus Round N when in the round), and there is also a free-text notes field for yarn, needles, and finishing.",
    ),
    FaqEntry(
      "What can the nalbinding section actually do right now?",
      "Nalbinding is a stitch reference for now, not a project editor. You get a curated dictionary of about 12 stitches (each showing its Hansen notation, the a+b thumb-loop alias, alternate names, a generated loop diagram, and a short description) plus a notation playground where you type a Hansen string like \"UO/UOO F1\" and see a live loop diagram and validation. There is no project or recipe model and no saving of nalbinding work yet; the worked-piece and shaping-segment model is deferred.",
    ),
  ]),
  FaqSection('Tips & troubleshooting', [
    FaqEntry(
      "Where do all my patterns live, and how do I find the right craft?",
      "The home screen is one library with a tab per craft: Weaving, Knitting, and Nalbinding. Your saved weaves and knits each show up as thumbnails under their tab, and everything is stored as files on your device, so there is no account or cloud sync to worry about.",
    ),
    FaqEntry(
      "What is that colored band in the editor telling me?",
      "That is the inline validation band, and it only appears when there is a real structural issue, so a clean pattern shows nothing. Red means an Error (something that breaks the pattern, like a treadle tying a shaft that does not exist) and amber means a Warning (advisory). Tap the summary to expand the full list, with Errors sorted first.",
    ),
    FaqEntry(
      "Will Ply stop me from saving if my pattern has problems?",
      "Errors will prompt you with a confirmation before saving, but you can choose to save anyway, so nothing is ever locked behind a fix. Warnings never block saving since they are only advisory. The one hard stop is an empty cloth: you need at least one end and one pick before a weave can be saved.",
    ),
    FaqEntry(
      "How do undo, redo, and zoom work?",
      "Both the weaving and knitting editors have Undo and Redo buttons in the top bar that walk back and forth through your edit history. Both also zoom from the editor's overflow menu (Zoom in / Zoom out), with weaving snapping through preset zoom steps and knitting nudging a few pixels each tap; in the weaving editor you can also drag to pan the draft. Note the Nalbinding tab is a reference, not an editor, so it has no undo or zoom.",
    ),
    FaqEntry(
      "Can I change the app's colors or make it easier to read?",
      "Yes, open Settings from the gear icon in the home screen's top bar. You can pick System, Light, or Dark mode, turn on Material You to pull colors from your device wallpaper, or choose an accent color. Changes apply instantly and survive a relaunch, and the app respects your system text size and works with screen readers.",
    ),
    FaqEntry(
      "Where is the glossary, and why can't I do machine knitting export or nalbinding projects?",
      "The glossary lives right here in Help: tap the Glossary entry at the top of this screen (Help is the question-mark icon in the home screen's top bar). It is a searchable reference covering weaving, knitting, and nalbinding terms. Knitout export for machine knitters is planned but not built yet, so for now knitting is charts plus written instructions only. Nalbinding is currently a stitch reference and notation playground; the project and recipe model (worked pieces with shaping) is also still deferred.",
    ),
  ]),
];
